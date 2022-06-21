#!/bin/bash

KERNEL_DIR=/root/linux
BRANCH=$1

cleanup() {
	# Just in case we want to push to the same branch again
	cd $KERNEL_DIR
	rm -f .localversion
}

trap cleanup EXIT

cp /lib/modules/$(uname -r)/build/.config $KERNEL_DIR/.config

modprobe ext4
modprobe loop

cd $KERNEL_DIR

if [ -n "$BRANCH" ]; then
	git checkout $BRANCH || exit 1
	echo .$BRANCH > localversion
else
	git pull --all
fi

make olddefconfig
make localmodconfig 0> /dev/null
make -j32 && make modules_install && make install
ret=$?

[ $ret -ne 0 ] && exit 1

release=$(make -s kernelrelease)
grubby --set-default vmlinuz-$release
