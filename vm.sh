#!/bin/bash

BASE_VMS="fedora36 fedora35 rhel8 rhel9"
BASE_DIR=`dirname "$(realpath $0)"`
SCRIPTS_DIR="$BASE_DIR/scripts"
TEMPLATES_DIR="$BASE_DIR/templates"
RESULTS_DIR="$BASE_DIR/results"
CONFIG_FILE="$BASE_DIR/vm.conf"
CONFIGS_DIR="$BASE_DIR/configs"
TEMPLATE_CONFIG_FILE="$BASE_DIR/vm.conf.template"
XFSTESTS_CONFIG="$CONFIGS_DIR/xfstests.config"

TEMPLATE_XML="$TEMPLATES_DIR/template.xml"
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
	echo "	test [ -r RPM ] [ -s BREW_ID ] VM TEST [-s SECTION ] [ -b BASELINE ] [OPTIONS]"
	echo "				Run TEST on VM with optional OPTIONS passed to the test itself. Optionally install RPM packages provided either as a file, link or identified by BREW_ID."
	echo "				Currently supported tests: $SUPPORTED_TESTS"
	echo "				Additionally SECTION to test can be specified (defaults to ext4), or all for all sections"
	echo "				If this is a baseline test, use -b"
	echo "	testbuild VM [PATH] BRANCH [ -s SECTION ] [ -b BASELINE ] [OPTIONS]"
	echo "				Push the BRANCH from repository in the current directory, or specified PATH to the VM."
	echo "				Build and install the kernel and run xfstests with specified OPTIONS"
	echo "				Additionally SECTION to test can be specified (defaults to ext4), or all for all sections"
	echo "				If this is a baseline test, use -b"
	echo "	run VM SCRIPT		Run SCRIPT in VM"
	echo "	console VM		Run 'virsh console' for the VM"
	echo "	build VM [PATH] BRANCH	Push the BRANCH from repository in the current directory, or speciied PATH to the VM."
	echo "				Build and install the kernel, reboot and connect to the vm"
	echo "	results			Print table with all xfstests results available"
	echo "	results show DIR...	Print table with all specified xfstests results"
	echo "	results compare BASE DIR..."
	echo "				Print table comparing specified xfstests results to the BASE"
	echo "	results rm DIR...	Remove all specified xfstests results"
	echo "	results rmall		Remoe all available xfstests results"
	echo "	results cleanup		Attempt to remove all missing, or incomplete results"
	echo "	results baseline OS	Show baseline results for specified OS"
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
	require_tool multitail
	require_tool comm

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
	printf "\r"
	[ -z "$ip" ] && error "Can't get IP address for $1"
	VM_IP[$1]=$ip
	echo $ip
}

wait_for_ping() {
	[ -z "$1" ] && error "Provide VM name to ping"
	[ "${VM_ONLINE[$1]}" == "true" ] && return

	ip=${VM_IP[$1]}
	echo "[+] Waiting for host to be online vm $1 ip $ip"
	repeat=60
	for i in $(seq $repeat); do
		echo -n "."
		ping -W1 -i1 -c1 $ip >/dev/null 2>&1
		[ $? -eq 0 ] && VM_ONLINE[$1]="true" && break
		sleep 1
	done
	printf "\r$1 is live\n"
}

wait_vm_online() {
	[ -z "$1" ] && error "Provide VM name"
	get_vm_ip $1
	wait_for_ping $1
}

define_new_vm() {
	[ "$#" -lt 1 ] && error "Provide VM name to define"
	new_xml=$(mktemp)

	devname="${LVM_VG}-$1"
	cat $TEMPLATE_XML | sed "s/MY_NEW_VM_NAME/$1/g;s/MY_NEW_DEV_NAME/$devname/g" > $new_xml

	echo "[+] Defining the vm $1"
	sudo virsh define $new_xml || error "Failed to define the new VM"
	rm -f $new_xml
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
		# Is it clone already? If so don't add another 'clone' to the name
		if [[ "$VM" =~ "clone" ]]; then
			NEW_VM="$1_$2"
		else
			NEW_VM="$1_clone_$2"
		fi

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
	define_new_vm $NEW_VM

	devname=${NEW_VM}_test
	echo "[+] Creating new test device $devname"
	sudo lvcreate -n $devname -V 20G --thinpool $THIN_POOL $LVM_VG || error "lvcreate failed"
	LV_CREATED="$LV_CREATED $devname"
	sudo virsh attach-disk $NEW_VM /dev/mapper/${LVM_VG}-${devname} vdb --config --cache none --driver qemu --subdriver raw --io native --targetbus virtio

	devname=${NEW_VM}_scratch
	echo "[+] Creating new scratch device $devname"
	sudo lvcreate -n $devname -V 20G --thinpool $THIN_POOL $LVM_VG || error "lvcreate failed"
	LV_CREATED="$LV_CREATED $devname"
	sudo virsh attach-disk $NEW_VM /dev/mapper/${LVM_VG}-${devname} vdc --config --cache none --driver qemu --subdriver raw --io native --targetbus virtio

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
	dev="/dev/mapper/${LVM_VG}-$devname"
	if [ ! -b "$dev" ]; then
		echo "[+] Creating new system device $devname"
		sudo lvcreate -n $devname -V $VM_LV_SIZE --thinpool $THIN_POOL $LVM_VG || error "lvcreate failed"
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

	define_new_vm $1
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
	copy_to_vm $1 $XFSTESTS_CONFIG /root/xfstests/configs/${vm_name}.config
	stop_vm $1
}

run_xfstests() {
	local ip
	local baseline
	VM=$1
	shift 1

	# Get the section options for the xfstests
	local sections=
	while getopts ":s:b:" arg; do
	case ${arg} in
		s)
			case $OPTARG in
				all)	sections="ext4 ext4_1024 ext3 ext2"
					;;
				*)	sections="$sections $OPTARG";;
			esac
			;;
		b)
			baseline=$(get_baseline_filename $OPTARG) || error "No such baseline $OPTARG"
			;;
		?)
			# sections must be specified first, stop upon
			# encountering anything else
			((OPTIND--))
			break
	esac
	done

	shift $((OPTIND - 1))

	# Update the xfstests config file
	hostname=`echo $VM | cut -f1 -d'_'`
	copy_to_vm $VM $XFSTESTS_CONFIG /root/xfstests/configs/${hostname}.config

	kernel=$(ssh root@$ip 'uname -r')
	datetime=$(date +%Y-%m-%d_%H_%m_%S)

	# Set the default if no section is specified
	[ -z "$sections" ] && sections="ext4"

	n=$(echo $sections | wc -w)

	# If we only have one section, run the test with normal output visible
	# Otherwise stop the VM, clone it and start tests in parallel
	if [ $n -eq 1 ]; then
		section=$(echo $sections | cut -f1)
		run_script_in_vm $VM xfstests -s $section $@

		ip=${VM_IP[$VM]}
		outdir=$RESULTS_DIR/xfstests/$kernel/$section/$datetime
		mkdir -p $outdir

		# Create file signifying it is a baseline result
		[ -n "$baseline" ] && touch $RESULTS_DIR/xfstests/$kernel/$baseline

		scp -q -r root@$ip:/root/output/* $outdir
		echo "[+] Section $section test is DONE. Results stored in $outdir"
		return
	else
		stop_vm $VM
	fi

	echo ""

	# Run each section in a separate VM clone from the provided VM in
	# parallel
	declare -A arrTests
	declare -A arrLogs
	clones=
	tmp=$(mktemp)
	for s in $sections; do
		log=${tmp}.$s
		outdir=$RESULTS_DIR/xfstests/$kernel/$s/$datetime

		if [ $n -gt 1 ]; then
			echo "[+] Cloning $VM for section $s"
			clone_vm $VM $s > $log 2>&1
			if [ $? -ne 0 ]; then
				echo "Cloning $VM failed, see log $log"
				continue
			fi
			clones="$clones $NEW_VM"
		else
			NEW_VM=$VM
		fi

		echo "[$s] Starting test on $NEW_VM"
		echo -e "\t live log:\t$log"
		echo -e "\t results:\t$outdir"

		# The VM needs to be started, otherwise run_script_in_vm
		# will stop the vm after it's done
		start_vm $NEW_VM > $log 2>&1

		# Run the test and copy out results
		(
		run_script_in_vm $NEW_VM xfstests -s $s $@

		# We knowVM is already running so it's fine to get ip directly
		ip=${VM_IP[$NEW_VM]}
		outdir=$RESULTS_DIR/xfstests/$kernel/$s/$datetime
		mkdir -p $outdir

		# Create file signifying it is a baseline result
		[ -n "$baseline" ] && touch $RESULTS_DIR/xfstests/$kernel/$baseline

		scp -q -r root@$ip:/root/output/* $outdir
		echo "[+] Section $s test is DONE. Results stored in $outdir"

		) >> $log 2>&1 &

		arrTests[$!]="$s $NEW_VM"
		arrLogs[$NEW_VM]=$log

		((n--))
	done

	# Watch the logs
	multitail --mark-interval 60 --follow-all ${arrLogs[@]}

	# Wait for all the tests to finish and gather results
	while true; do
		wait -n -p PID ${!arrTests[@]}
		status=$?
		[ "$status" -eq 127 ] && break

		section=${arrTests[$PID]% *}
		vm=${arrTests[$PID]#* }
		log=${arrLogs[$vm]}
		echo "[$section]"
		tail -n6 $log | grep -E '^Failures: |Failed ' || echo "No failures"

		unset arrTests[$PID]
		vals=${arrTests[@]}
		[ -z "$vals" ] && break
	done

	echo ""

	[ -n "$clones" ] && delete_vm $clones
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

	# If the target is a directory, make sure it exists first
	if [[ "$REMOTE_DIR" =~ .*/$ ]]; then
		run_script_in_vm $VM "mkdir -p $REMOTE_DIR"
	fi

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
	declare -A arrLogs

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
		arrLogs[$1]=$log
		shift
	done

	multitail --mark-interval 60 --follow-all ${arrLogs[@]}

	# Wait for all the update processes
	while true; do
		wait -n -p PID ${!arrUpdate[@]}
		st=$?
		[ "$st" -eq 127 ] && break
		unset arrUpdate[$PID]
		vals=${arrUpdate[@]}
		[ -z "$vals" ] && break
	done
}

get_baseline_filename() {
	case $1 in
		fedora35)	baseline=FEDORA35_BASELINE_x86_64;;
		fedora36)	baseline=FEDORA36_BASELINE_x86_64;;
		rhel8)		baseline=RHEL8_BASELINE_x86_64;;
		rhel9)		baseline=RHEL9_BASELINE_x86_64;;
		upstream)	baseline=UPSTREAM_BASELINE_x86_64;;
		*)		return 1;;
	esac
	echo $baseline
}

get_latest_baseline() {
	[ -z "$1" ] && return 1
	local resdir

	basefile=$(get_baseline_filename $1) || return 1

	resdir=$(
	for dir in `find ${RESULTS_DIR}/xfstests/ -type f -name $basefile -printf "%h\n"`; do
		basename $dir
	done | sort -t '.' -k1n -k2n -k3n | tail -n1
	)

	[ -n "$resdir" ] || return 1

	echo ${RESULTS_DIR}/xfstests/$resdir
}

get_resdir() {
	[ -z "$1" ] && return 1

	local resdir=""

	if [ -d "$1" ]; then
		resdir=$1
	elif [ -d "${RESULTS_DIR}/xfstests/$1" ]; then
		resdir=${RESULTS_DIR}/xfstests/$1
	else
		resdir=$(get_latest_baseline $1) || return 1
	fi

	if [ -z "$(ls -A $resdir)" ]; then
		return 1
	fi

	echo $resdir
}

distill_results() {
	local dir=$1
	local log=${dir}/check.log

	[ -s "$log" ] || return 1

#	if [ ! -s ${dir}/ran ]; then
	grep '^Ran: ' $log | tr ' ' '\n' | tail -n+2 | sort > $dir/ran
	grep '^Not run: ' $log | tr ' ' '\n' | tail -n+2 | sort > $dir/notrun
	grep '^Failures: ' $log | tr ' ' '\n' | tail -n+2 | sort > $dir/failures
#	fi
}

print_header() {
		l=$(echo $1 | wc -c)
		printf "%$((30+l/2))s\n" "$1"
		printf "%0.s-" {1..60}
		printf "\n"
}

show_results() {
	[ $# -lt 1 ] && error "No results to show"
	local tmp=$(mktemp)

	for i in $@; do
		resdir=$(get_resdir $i) || continue
		#ls $resdir >> $tmp
		find $resdir -maxdepth 1 -mindepth 1 -type d -printf "%f\n" >> $tmp
	done

	sections=$(sort $tmp | uniq)

	[ -z "$sections" ] && return

	printf "%0.s-" {1..60}
	printf "\n"

	for section in $sections; do
			print_header $section

		for i in $@; do

			resdir=$(get_resdir $i) || continue
			[ -d "${resdir}/${section}" ] || continue

			last=$(ls ${resdir}/${section} | sort -n | tail -n1)
			dir=${resdir}/${section}/${last}

			distill_results $dir || continue

			format="%-35.33s| %-10.8s| %s\n"

			out=$(wc -l $dir/ran | cut -d' ' -f1)
			printf "$format" $i "Ran:" $out

			out=$(wc -l $dir/notrun | cut -d' ' -f1)
			printf "$format" $i "Not run:" $out

			out=$(wc -l $dir/failures | cut -d' ' -f1)
			printf "$format" $i "Fails:" $out

			out=$(cat $dir/failures | tr '\n' ' ')
			[ -n "$out" ] && printf "$format" "$i" "Failed:" "$out"

			printf "%0.s-" {1..60}
			printf "\n"
		done
	done
}

compare_results() {
	[ $# -lt 2 ] && error "To compare results specify at leas two arguments"
	local header=0

	base=$(get_resdir $1) || error "Base result \"$1\" does not exist"
	sections=$(find $base -maxdepth 1 -mindepth 1 -type d -printf "%f\n")
	shift

	[ -z "$sections" ] && return

	printf "%0.s-" {1..60}
	printf "\n"

	for section in $sections; do

		for i in $@; do

			resdir=$(get_resdir $i) || continue

			[ -d "${resdir}/${section}" ] || continue

			last=$(ls ${resdir}/${section} | sort -n | tail -n1)
			dir=${resdir}/${section}/${last}

			distill_results $dir || continue

			lastbase=$(ls ${base}/${section} | sort -n | tail -n1)
			basedir=${base}/${section}/${lastbase}

			distill_results $basedir || continue

			[ $header -eq 0 ] && print_header $section

			format="%-35.33s| %-10.8s| %s\n"

			out=$(wc -l $dir/ran | cut -d' ' -f1)
			printf "$format" $i "Ran:" $out

			out=$(comm -23 ${basedir}/failures $dir/failures | tr '\n' ' ')
			[ -n "$out" ] && printf "$format" "$i" "Fixes:" "$out"

			out=$(comm -13 ${basedir}/failures $dir/failures | tr '\n' ' ')
			[ -n "$out" ] && printf "$format" "$i" "Breaks:" "$out"

			out=$(cat $dir/failures | tr '\n' ' ')
			[ -n "$out" ] && printf "$format" "$i" "Fails:" "$out"

			printf "%0.s-" {1..60}
			printf "\n"
		done
	done
}

remove_results() {
	[ $# - lt 1 ] && error "Nothing to remove"
	for i in $@; do
		resdir=${RESULTS_DIR}/xfstests/$i
		[ -d "$resdir" ] || continue
		echo "Removing results for \"$i\""
		rm -rf $resdir
	done
}

cleanup_results() {
	echo "[+] Cleaning up results directory"

	# Delete all empty directories
	find ${RESULTS_DIR}/xfstests -empty -type d -delete

	for i in $@; do
		resdir=${RESULTS_DIR}/xfstests/$i
		[ -d "$resdir" ] || continue

		for section in $(ls $resdir); do
			for run in $(ls ${resdir}/${section}); do

				log=${resdir}/${section}/${run}/check.log
				[ -s "$log" ] && continue

				echo "Remove broken run \"${resdir}/${section}/${run}\""
				rm -rf ${resdir}/${section}/${run}
			done
		done
	done

	# Delete all empty directories
	find ${RESULTS_DIR}/xfstests -empty -type d -delete
}

manage_results() {
	cmd=$1
	shift

	case "$cmd" in
		show)		show_results $@;;
		compare)	compare_results $@;;
		rm)		remove_results $@;;
		rmall)		remove_results $(ls ${RESULTS_DIR}/xfstests);;
		cleanup)	cleanup_results;;
		baseline)	get_latest_baseline $1;;
		*)		show_results $(ls ${RESULTS_DIR}/xfstests) ;;
	esac
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
	results)		manage_results $@;;
	help)
				usage
				exit 0
				;;
	*) error "Command \"$COMMAND\" not recognized"
esac

exit
