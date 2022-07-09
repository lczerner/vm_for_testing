#!/bin/bash

BASE_VMS="fedora36 fedora35 rhel8 rhel9"
BASE_DIR=`dirname "$(realpath $0)"`
SCRIPTS_DIR="$BASE_DIR/scripts"
TEMPLATES_DIR="$BASE_DIR/templates"
RESULTS_DIR="$BASE_DIR/results"
CONFIG_FILE="$BASE_DIR/vm.conf"
TEMPLATE_CONFIG_FILE="$BASE_DIR/vm.conf.template"

TEMPLATE_XML="$TEMPLATES_DIR/template.xml"
TEMPLATE_CLONE_XML="$TEMPLATES_DIR/template_clone.xml"
INIT_SCRIPT="$SCRIPTS_DIR/init.sh"

SUPPORTED_TESTS="xfstests e2fsprogs"

VM_LV_SIZE=100G

declare -A VM_IP
declare -A VM_ONLINE
LV_CREATED=
VM_CLONED=
NEW_VM=
INSTALL_RPMS=
ARGS_SHIFT=0

usage() {
	echo "$(basename $0) help | ls | start VM | stop VM | rm VM | clone VM | ip VM | update VM | test VM TEST [OPTIONS] | testbuild VM [PATH] BRANCH [OPTIONS] | run VM SCRIPT | console VM"
	echo ""
	echo "	help			Print this help"
	echo "	list | ls		List all vms"
	echo "	start VMs		Start all specified VMs"
	echo "	stop VMs		Stop all specified VMs"
	echo "	new VM			Create a new vm named VM"
	echo "				Currently supported OS: $BASE_VMS"
	echo "	delete | rm VMs		Remove all spefied VMs."
	echo "	clone [ -r RPM ] [ -s BREW_ID ] VM [NAME]"
	echo "				Clone a VM. Optionally install RPM packages provided either as a file, link, or identified by BREW_ID."
	echo "				If NAME is given, then the new VM name will be in format VM_clone_NAME"
	echo "	ssh VM			ssh to the VM"
	echo "	ip VM			Get an IP address for the VM"
	echo "	update VMs		Update all specified VMs"
	echo "	test [ -r RPM ] [ -s BREW_ID ] VM TEST [OPTIONS]"
	echo "				Run TEST on VM with optional OPTIONS passed to the test itself. Optionally install RPM packages provided either as a file, link or identified by BREW_ID."
	echo "				Currently supported tests: $SUPPORTED_TESTS"
	echo "	testbuild VM [PATH] BRANCH [OPTIONS]"
	echo "				Push the BRANCH from repository in the current directory, or specified PATH to the VM."
	echo "				Build and install the kernel and run xfstests with specified OPTIONS"
	echo "	run VM SCRIPT		Run SCRIPT in VM"
	echo "	console VM		Run 'virsh console' for the VM"
	echo "	build VM [PATH] BRANCH	Push the BRANCH from repository in the current directory, or speciied PATH to the VM."
	echo "				Build and install the kernel, reboot and connect to the vm"
}

error() {
	echo "Error: ${FUNCNAME[1]}: $@"
	echo
	usage
	if [ -n "$LV_CREATED" ]; then
		for lv in $LV_CREATED; do
			sudo lvremove -y $LVM_VG/$lv
		done
	fi
	LV_CREATED=
	exit 1
}

require_tool() {
	which $1 > /dev/null 2>&1 || error "\"$1\" required but not available."
}

check_requirements() {
	require_tool virsh
	require_tool lvs
	require_tool vgs
	require_tool lvcreate
	require_tool lvremove
	require_tool blkdiscard
	require_tool virt-builder
	require_tool ssh
	require_tool scp
	require_tool wget

	# Does LVM_VG exist?
	sudo vgs --noheadings -o vg_name | grep -w $LVM_VG >/dev/null 2>&1|| \
		error "Lvm pool \"$LVM_VG\" does not exist"

	# Does THIN_POOL exist?
	sudo lvs --noheadings -o lv_name | grep -w $THIN_POOL >/dev/null 2>&1|| \
		error "Lvm thin pool \"$LVM_VG\" does not exist"

	# Is THIN_POOL thin-pool?
	sudo lvs --noheadings -o lv_name,segtype | grep -w $THIN_POOL | \
		grep -w "thin-pool" > /dev/null 2>&1 || \
		error "\"$LVM_VG\" is not lvm thin pool"
}

get_vm_dev() {
	echo "/dev/$LVM_VG/$1"
}

check_vm_exists() {
	sudo virsh list --all --name | grep "^$1$" > /dev/null 2>&1
}

check_vm_inactive() {
	sudo virsh list --inactive --name | grep "^$1$" > /dev/null 2>&1
}

check_vm_active() {
	sudo virsh list --name | grep "^$1$" > /dev/null 2>&1
}

create_new_vm_name() {
	for i in `seq 999`; do
		name="${VM}_clone_${i}"
		dev_name=$(get_vm_dev $name)
		check_vm_exists $name && continue
		[ -b $dev_name ] && continue
		break;
	done
	echo $name
}

get_address() {
	sudo virsh -q domifaddr $1 | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}"
}

get_vm_ip() {
	local ip
	[ -z "$1" ] && error "Provide VM name to get the ip for"
	check_vm_active $1 || error "VM \"$1\" does not exist or is not running"
	[ -n "${VM_IP[$1]}" ] && return

	echo "[+] Obtaining the IP address"
	repeat=60
	for i in $(seq $repeat); do
		echo -n "."
		ip=$(get_address $1)
		[ -n "$ip" ] && break
		sleep 1
	done
	echo -en "\033[2K"
	[ -z "$ip" ] && error "Can't get IP address for $1"
	VM_IP[$1]=$ip
	echo $ip
}

wait_for_ping() {
	[ -z "$1" ] && error "Provide IP address to ping"
	[ "${VM_ONLINE[$1]}" == "true" ] && return

	echo "[+] Waiting for host to be online"
	repeat=60
	for i in $(seq $repeat); do
		echo -n "."
		ping -W1 -i1 -c1 $1 >/dev/null 2>&1
		[ $? -eq 0 ] && VM_ONLINE[$1]="true" && break
		sleep 1
	done
	echo -e "\033[2K$1 is live"
}

wait_vm_online() {
	[ -z "$1" ] && error "Provide VM name"
	get_vm_ip $1
	wait_for_ping ${VM_IP[$1]}
}

ssh_to_vm() {
	[ -z "$1" ] && error "Provide VM name to get the ip for"
	check_vm_active $1 || error "VM \"$1\" does not exist or is not running"

	wait_vm_online $1

	echo "[+] Connecting to $1 via ssh root@${VM_IP[$1]}"
	sleep 1
	ssh root@${VM_IP[$1]}
}

start_vm() {
	[ "$#" -lt 1 ] && error "Provide VM name to start"

	while [ "$#" -gt 0 ]; do
		check_vm_active $1 && shift && continue

		check_vm_exists $1
		if [ $? -ne 0 ]; then
			echo "VM \"$1\" does not exist"
			shift
			continue
		fi
		echo "[+] Starting the vm $1"
		sudo virsh start $1 > /dev/null 2>&1
		shift
	done
}

get_script_path() {
	if [ -f $SCRIPTS_DIR/$1 ]; then
		echo $SCRIPTS_DIR/$1
		return
	fi

	if [ -f $SCRIPTS_DIR/${1}.sh ]; then
		echo $SCRIPTS_DIR/${1}.sh
		return
	fi
}

run_script_in_vm() {
	local need_to_poweroff=0
	local ip

	if [ $# -lt 2 ]; then
		error "Run script requires 2 parameters."
	fi

	[ -z "$1" ] && error "Provide VM name to get the ip for"
	check_vm_exists $1 || error "VM \"$1\" does not exist"

	VM=$1

	if ! check_vm_active $VM; then
		start_vm $VM
		local need_to_poweroff=1
	fi

	script=$(get_script_path $2)

	[ -z "$script" ] && command=$2

	wait_vm_online $VM
	ip=${VM_IP[$VM]}

	# Strip the first two arguments, we're going to pass the rest
	# as arguments for the script
	shift 2

	if [ -n "$script" ]; then
		echo "[+] Running script \"$script $@\""
		ssh root@$ip '/bin/bash -s' < $script - $@
		ret=$?
	elif [ -n "$command" ]; then
		echo "[+] Running command \"$command\""
		ssh root@$ip "$command"
		ret=$?
	fi

	if [ "$need_to_poweroff" == "1" ]; then
		stop_vm $VM
	fi

	return $ret
}

parse_install_args() {
	while getopts "r:s:" arg; do
	case ${arg} in
		r)
			INSTALL_RPMS="$INSTALL_RPMS $OPTARG"
			;;
		s)
			INSTALL_RPMS="$INSTALL_RPMS $(get_scratch_kernel $OPTARG)"
			;;
		?)
			error "Invalid argument -${OPTARG}"
			;;
	esac
	done
}

install_rpms() {
	check_vm_active $1 || error "\"$1\" is not running!"

	if [ -n "$INSTALL_RPMS" ]; then
		REMOTE_DIR="/root/rpms_$RANDOM"

		copy_to_vm $1 $INSTALL_RPMS $REMOTE_DIR

		run_script_in_vm $1 install_rpm $REMOTE_DIR || error "Failed to install rpms"

		reboot_vm $1
	fi
}

clone_vm() {
	[ -z "$1" ] && error "Provide VM name to clone"
	VM=$1
	VM_DEV=$(get_vm_dev $VM)

	check_vm_inactive $VM
	if [ $? -ne 0 ]; then
		sudo virsh list --all
		error "VM either does not exist or it is already running"
	fi

	# Check if the block device exists
	[ -b "$VM_DEV" ] || error "$VM_DEV block device does not exist"

	if [ -n "$2" ]; then
		NEW_VM="$1_clone_$2"
		check_vm_exists $NEW_VM && error "VM with the name \"$NEW_VM\" already exist"
	else
		NEW_VM=$(create_new_vm_name)
	fi
	NEW_VM_DEV=$(get_vm_dev $NEW_VM)


	echo -e "New VM name:\t$NEW_VM"
	echo -e "New VM device:\t$NEW_VM_DEV"
	echo "==============================================="

	echo "[+] Creating snapshot of system volume"
	sudo lvcreate -s --name $NEW_VM $VM_DEV || error "Failed to create snapshot"
	LV_CREATED=$NEW_VM

	devname=${NEW_VM}_test
	echo "[+] Creating new test device $devname"
	sudo lvcreate -n $devname -V 20G --thinpool thin_pool lvm_pool || error "lvcreate failed"
	LV_CREATED="$LV_CREATED $devname"

	devname=${NEW_VM}_scratch
	echo "[+] Creating new scratch device $devname"
	sudo lvcreate -n $devname -V 20G --thinpool thin_pool lvm_pool || error "lvcreate failed"
	LV_CREATED="$LV_CREATED $devname"

	echo "[+] Cloning the virtual machine"
	NEW_XML=$(mktemp)

#	sudo virt-clone \
#		--original $VM \
#		--name $NEW_VM \
#		--file=$NEW_VM_DEV \
#		--preserve-data \
#		--print-xml > $NEW_XML || error "Failed to clone the VM"

	cat $TEMPLATE_CLONE_XML | sed "s/MY_NEW_VM_NAME/$NEW_VM/g" > $NEW_XML

	echo "[+] Defining the vm"
	sudo virsh define $NEW_XML || error "Failed to define the new VM"
	sudo rm -f $NEW_XML
	LV_CREATED=
	VM_CLONED=1
}

delete_vm() {
	[ "$#" -lt 1 ] && error "Provide VM name to delete"

	while [ "$#" -gt 0 ]; do
		check_vm_exists $1
		if [ $? -ne 0 ]; then
			echo "VM \"$1\" does not exist"
			shift
			continue
		fi
		echo "[+] Removing VM \"$1\""
		sudo virsh destroy $1 > /dev/null 2>&1
		unset VM_IP[$1]
		unset VM_ONINE[$1]
		sleep 1

		sudo lvremove -y $LVM_VG/$1 $LVM_VG/${1}_test $LVM_VG/${1}_scratch
		sudo virsh undefine $1 || echo "Can't undefine vm \"$1\""
		shift
	done
}

stop_vm() {
	[ "$#" -lt 1 ] && error "Provide VM name to stop"

	while [ "$#" -gt 0 ]; do
		check_vm_active $1
		if [ $? -ne 0 ]; then
			echo "VM \"$1\" does not exist, or isn't active"
			shift
			continue
		fi
		echo "[+] Stopping VM \"$1\""
		sudo virsh destroy $1 > /dev/null 2>&1
		unset VM_IP[$1]
		unset VM_ONLINE[$1]
		shift
	done
}

reboot_vm() {
	check_vm_active $1 || error "VM \"$1\" is not active or does not exist"
	echo "[+] Rebooting VM"
	run_script_in_vm $VM 'reboot'
	unset VM_ONLINE[$1]
	sleep 2
}

new_vm() {
	[ -z "$1" ] && error "Provide VM name to create"
	check_vm_exists $1 && error "VM \"$1\" already exists"

	case "$1" in
		rhel8)
			vm_name=rhel8
			release=centosstream-8
			ENABLE_EPEL='--run-command "dnf config-manager --set-enabled powertools && dnf install -y epel-release epel-next-release"'
		;;
		rhel9)
			vm_name=rhel9
			release=centosstream-9
			ENABLE_EPEL='--run-command "dnf config-manager --set-enabled crb && dnf install -y epel-release epel-next-release"'
		;;
		fedora35)
			vm_name=fedora35
			release=fedora-35
		;;
		fedora36)
			vm_name=fedora36
			release=fedora-36
		;;
		*) error "Vm $1 is not supported"
	esac

	devname=${vm_name}
	dev="/dev/mapper/lvm_pool-$devname"
	if [ ! -b "$dev" ]; then
		echo "[+] Creating new system device $devname"
		sudo lvcreate -n $devname -V $VM_LV_SIZE --thinpool thin_pool lvm_pool || error "lvcreate failed"
		LV_CREATED="$LV_CREATED $devname"
	else
		echo "[+] Cleaning the device"
		sudo blkdiscard $dev
	fi

	# Copy in config files
	COPY_IN="--copy-in ~/.gitconfig:/root/ \
		 --copy-in ~/.vimrc:/root/ \
		 --copy-in ~/.vim:/root/"

	echo "[+] Building the new image"
	builder="sudo virt-builder $release \
		--output $dev \
		--smp 8 --memsize 4096 \
		--hostname $vm_name \
		$ENABLE_EPEL \
		$COPY_IN \
		--copy-in $INIT_SCRIPT:/root/ \
		--ssh-inject \"root:string:$SSH_PUBKEY\" \
		--selinux-relabel || error 'virt-builder failed'"

	eval $builder

	NEW_XML=$(mktemp)
	cat $TEMPLATE_XML | sed "s/MY_NEW_VM_NAME/$1/g" > $NEW_XML

	echo "[+] Defining the vm"
	sudo virsh define $NEW_XML || error "Failed to define the new VM"
	sudo rm -f $NEW_XML
	LV_CREATED=

	start_vm $1

	case "$1" in
		rhel9)
			# We have to build and install inih-devel first
			# because it's missing in RHEL9
			run_script_in_vm $1 inih-devel
		;;
	esac

	run_script_in_vm $1 init
	stop_vm $1
}

run_xfstests() {
	local ip
	VM=$1

	# rest of the arguments will be provided to the xfstests
	shift 1

	run_script_in_vm $VM xfstests $@
	ip=${VM_IP[$VM]}

	kernel=$(ssh root@$ip 'uname -r')
	datetime=$(date +%Y-%m-%d_%H_%m_%S)
	outdir=$RESULTS_DIR/xfstests/$kernel/$datetime
	mkdir -p $outdir

	echo "[+] Copying files from the VM"
	scp -q -r root@$ip:/root/output/* $outdir
	[ $? -ne 0 ] && rmdir $outdir

	echo "[+] Results stored in $outdir"
}

test_e2fsprogs() {
	VM=$1

	shift 1

	run_script_in_vm $VM test_e2fsprogs $@
	ip=${VM_IP[$VM]}

	version=
	datetime=
	outdir=$RESULTS_DIR/e2fsprogs/$version/$datetime
	mkdir -p $outdir

	echo "[+] Copying files from the VM"
	scp -q -r root@$vm:/root/output/* $outdir
	[ $? -ne 0 ] && rmdir $outdir

	echo "[+] Results stored in $outdir"

}

get_scratch_kernel() {
	brewid=$1
	search="kernel-core-"
	url="https://download.eng.bos.redhat.com/brewroot/scratch/${RH_USERNAME}/task_$brewid"
	kernel=$(wget -q $url -O - | grep $search | grep x86_64 | sed -e 's/.*<a href="\(.*\)".*/\1/g')
	ver=${kernel#kernel-core-}

	files="$url/kernel-core-$ver $url/kernel-$ver $url/kernel-modules-$ver"
	echo $files
}

copy_to_vm() {
	[ $# -lt 3 ] && error "Not enough arguments"
	VM=$1
	REMOTE_DIR="${@: -1}"

	# Magical formula, do not disturb!
	# It removes the last argument from the $@
	set -- "${@:1:$(($#-1))}"

	shift

	check_vm_active $VM || error "VM \"$VM\" is not active or does not exist"

	FILES=
	tmp=$(mktemp)
	for file in `echo $@`; do
		if [ -f $file ]; then
			FILES="$FILES $file"
			continue
		fi
		wget -q --show-progress -P ${tmp} $file || error "Can't download \"$file\""
		filename=$(basename $file)
		FILES="$FILES ${tmp}/$filename"
	done

	wait_vm_online $VM
	ip=${VM_IP[$VM]}

	run_script_in_vm $VM "mkdir -p $REMOTE_DIR"
	echo "[+] Copy \"$FILES\" to remote directory \"$REMOTE_DIR\""
	scp -q -r $FILES root@$ip:$REMOTE_DIR || error "Failed copying the files"

	rm -fr $tmp
}

run_test() {
	local need_to_poweroff=0

	parse_install_args $@
	shift $((OPTIND - 1))

	[ $# -lt 2 ] && error "Not enough arguments"
	VM=$1
	TEST=$2

	echo $SUPPORTED_TESTS | grep -w $TEST > /dev/null 2>&1 || error "\"$TEST\" is not supported test"
	check_vm_exists $VM || error "VM \"$VM\" does not exist"

	# Is it clone? If not create one
	if [[ ! "$VM" =~ "clone" ]]; then
		clone_vm $VM
		VM=$NEW_VM
	fi

	if ! check_vm_active $VM; then
		start_vm $VM
		local need_to_poweroff=1
	fi

	shift 2

	install_rpms $VM

	case "$TEST" in
		xfstests)	run_xfstests $VM $@;;
		e2fsprogs)	test_e2fsprogs $VM $@;;
	esac

	if [ "$VM_CLONED" == "1" ]; then
		delete_vm $VM
		return
	fi

	if [ "$need_to_poweroff" == "1" ]; then
		stop_vm $VM
	fi
}

push_build_kernel() {
	[ $# -lt 1 ] && error "Not enough arguments"
	check_vm_exists $1 || error "VM \"$1\" does not exist"
	VM=$1

	shift
	((ARGS_SHIFT++))

	# Go into git directory
	if [ -d "$1" ]; then
		cd $1
		shift
		((ARGS_SHIFT++))
	fi

	# Get the branch name
	[ -n "$1" ] || error "Branch not specified"
	LOCAL_BRANCH=$1
	git branch | grep -w $1 > /dev/null 2>&1 || error "Branch \"$LOCAL_BRANCH\" not found"
	shift
	((ARGS_SHIFT++))

	# Is it clone? If not create one
	if [[ ! "$VM" =~ "clone" ]]; then
		clone_vm $VM
		VM=$NEW_VM
	fi

	if ! check_vm_active $VM; then
		start_vm $VM
		local need_to_poweroff=1
	fi

	wait_vm_online $VM
	ip=${VM_IP[$VM]}

	REMOTE_BRANCH=${LOCAL_BRANCH}_$RANDOM
	echo "[+] Push the branch to vm repo"
	git push ssh://root@$ip:/root/linux $LOCAL_BRANCH:$REMOTE_BRANCH

	run_script_in_vm $VM build_kernel $REMOTE_BRANCH || error "Build failed"

	reboot_vm $VM
}

push_build_test() {
	[ $# -lt 1 ] && error "Not enough arguments"
	check_vm_exists $1 || error "VM \"$1\" does not exist"
	VM=$1

	push_build_kernel $@
	shift $ARGS_SHIFT

	run_xfstests $VM $@

	if [ "$need_to_poweroff" == "1" ]; then
		stop_vm $VM
	fi
}

command_clone_vm() {
	parse_install_args $@
	shift $((OPTIND - 1))

	clone_vm $@
	start_vm $NEW_VM

	install_rpms $NEW_VM

	ssh_to_vm $NEW_VM
}

connect_to_console() {
	[ $# -lt 1 ] && error "Not enough arguments"
	check_vm_active $1 || error "VM \"$1\" is not running"

	sudo virsh console $1
}

list_vms() {
	sudo virsh list --all
}

update_vm() {
	[ "$#" -lt 1 ] && error "Provide VM name to update"
	tmp=$(mktemp)
	declare -A arrUpdate

	while [ "$#" -gt 0 ]; do
		check_vm_exists $1
		if [ $? -ne 0 ]; then
			echo "VM \"$1\" does not exist"
			shift
			continue
		fi
		log=${tmp}.$1
		touch $log
		echo "[+] Updating the vm $1 (log: $log)"
		run_script_in_vm $1 init update > $log 2>&1 &
		arrUpdate[$!]=$1
		shift
	done

	# Wait for all the update processes
	while true; do
		wait -n -p PID
		st=$?
		[ "$st" -eq 127 ] && break
		if [ "$st" -eq 0 ]; then
			res="DONE"
		else
			res="FAILED"
		fi
		echo "[+] ${arrUpdate[$PID]} update $res (log: $tmp.${arrUpdate[$PID]})"
		unset arrUpdate[$PID]
		vals=${arrUpdate[@]}
		[ -n "$vals" ] && echo -e "\tstill waiting for ${arrUpdate[@]}"
	done
}

###############################################################################
# Start of the script
###############################################################################

if [ ! -f "$CONFIG_FILE" ]; then
	echo "Configuration file \"$CONFIG_FILE\" does not exist."
	echo "Please use the template \"$TEMPLATE_CONFIG_FILE\" to create one"
	exit 1
fi

# Load the configuration file
. $CONFIG_FILE

[ -z "$SSH_PUBKEY" ] && echo "Variable SSH_PUBKEY is not set. See $TEMPLATE_CONFIG_FILE" && exit 1
[ -z "$LVM_VG" ] && echo "Variable LVM_VG is not set. See $TEMPLATE_CONFIG_FILE" && exit 1
[ -z "$THIN_POOL" ] && echo "Variable THIN_POOL is not set. See $TEMPLATE_CONFIG_FILE" && exit 1
[ -z "$RH_USERNAME" ] && echo "Variable RH_USERNAME is not set. See $TEMPLATE_CONFIG_FILE" && exit 1

check_requirements

# Check parameters
if [ $# -lt 1 ]; then
	error "Wrong parametes"
fi

COMMAND=$1
shift

case "$COMMAND" in
	clone)			command_clone_vm $@;;
	rm | delete)		delete_vm $@;;
	ls | list)		list_vms;;
	start)			start_vm $@;;
	stop)			stop_vm $@;;
	ip | addr)		get_vm_ip $@;;
	ssh)
				start_vm $1
				ssh_to_vm $@
				;;
	new)			new_vm $@;;
	run)			run_script_in_vm $@;;
	update)			update_vm $@;;
	test)			run_test $@;;
	testbuild)		push_build_test $@;;
	console)		connect_to_console $@;;
	build)
				push_build_kernel $@
				ssh_to_vm $VM
				;;
	help)
				usage
				exit 0
				;;
	*) error "Command \"$COMMAND\" not recognized"
esac

exit
