#!/bin/bash

E2FSPROGS_LOG=/root/e2fsprogs.log
E2FSPROGS_DIR=/root/e2fsprogs
BRANCH=$1

cleanup() {
	# Just in case we want to push to the same branch again
	cd $E2FSPROGS_DIR
	git checkout master
}

trap cleanup EXIT

if [ ! -d "$E2FSPROGS_DIR" ]; then
	git clone git://git.kernel.org/pub/scm/fs/ext2/e2fsprogs.git e2fsprogs
fi

cd $E2FSPROGS_DIR

if [ -n "$BRANCH" ]; then
	git checkout $BRANCH || exit 1
else
	git pull --all
fi

./configure && make -j32
[ $? -ne 0 ] && exit 1
make fullcheck | tee $E2FSPROGS_LOG

rm -rf /root/output
mkdir /root/output
cp -r $E2FSPROGS_LOG $E2FSPROGS_DIR/tests/*.{failed,log} /root/output
