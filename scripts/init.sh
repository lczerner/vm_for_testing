#!/bin/bash

hostname=$(hostname)
base_hname=${hostname%%.*}

if [ "$1" == "update" ]; then
	dnf --skip-broken -y update

	cd /root/linux
	git pull --all &

	cd /root/e2fsprogs
	git pull &

	cd /root/xfsprogs
	git pull
	make -j8 && make install && make install-dev

	cd /root/fio
	git pull
	git checkout fio-3.28 -b 3.28
	./configure && make -j8 && make install

	cd /root/xfstests
	git pull
	make -j8 && make install

	cd /root/ltp
	git pull
	make autotools
	./configure
	make -j8
	make install

	mkdir /mnt/test1
	mkdir /mnt/test2

	# Create fsgqa users
	useradd -m fsgqa
	useradd 123456-fsgqa
	useradd fsgqa2

	semodule -B

	echo "Waiting for git"
	wait
	exit
fi

dnf --skip-broken -y groupinstall 'Development Tools'
dnf --skip-broken -y install acl attr automake bc dump e2fsprogs gawk gcc gdbm-devel git kernel-devel libacl-devel libaio-devel libcap-devel libtool libuuid-devel lvm2 make psmisc python3 quota sed sqlite udftools xfsprogs userspace-rcu-devel libblkid-devel libattr-devel ncurses-devel e2fsprogs-devel zlib-devel vim-enhanced wget inih-devel bison flex elfutils-libelf-devel openssl-devel openssl-libs openssl dwarves tar grubby zstd bzip2 meson libuuid-devel beakerlib beakerlib-redhat rhts-test-env iotop tmux screen dbench fio git indent inih-devel meson krb5-workstation kexec-tools crash fsverity-utils

git clone git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git &

# Install all custom rpms
dnf --skip-broken -y install /root/*.dnf
dnf --skip-broken -y update

# Setup kdump
grubby --args="crashkernel=512M" --update-kernel=ALL
systemctl enable kdump.service
sysctl kernel.panic_on_oops=1 >> /etc/sysctl.conf

git clone git://git.kernel.org/pub/scm/fs/ext2/e2fsprogs.git e2fsprogs
git clone git://git.kernel.org/pub/scm/fs/xfs/xfstests-dev.git xfstests
git clone git://git.kernel.org/pub/scm/fs/xfs/xfsprogs-dev.git xfsprogs
git clone http://git.kernel.dk/fio.git
git clone https://github.com/linux-test-project/ltp.git


# Compile xfstests
cd xfsprogs
make -j8 && make install && make install-dev
cd ../fio
git checkout fio-3.28 -b 3.28
./configure && make -j8 && make install
cd ../xfstests
make -j8 && make install

cd /root/ltp
make autotools
./configure
make -j8
make install


mkdir /mnt/test1
mkdir /mnt/test2

# Create fsgqa users
useradd -m fsgqa
useradd 123456-fsgqa
useradd fsgqa2

semodule -B
wait
