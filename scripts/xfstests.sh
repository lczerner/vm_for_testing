#!/bin/bash

DMESG_LOG=/root/dmesg.log
XFSTESTS_LOG=/root/xfstests.log

error() {
	echo "ERROR: $@"
	exit 1
}

[ -d /root/xfstests ] || error "xfstests not found"

#losetup /dev/loop0 || losetup -f /home/file0 || error "Failed to setup /dev/loop0"
#losetup /dev/loop1 || losetup -f /home/file1 || error "Failed to setup /dev/loop1"

modprobe ext4
mkfs.ext4 -Fq /dev/vda
mkfs.ext4 -Fq /dev/vdb

cd /root/xfstests
rm -rf results

dmesg -C

./check $@ | tee $XFSTESTS_LOG

dmesg > $DMESG_LOG

rm -rf /root/output
mkdir /root/output
cp -r $DMESG_LOG $XFSTESTS_LOG /root/xfstests/results/* /root/output
