# Script for managing virtual machines for testing

This is a simple script for managing virtual machines used for testing.
Currently only RHEL8, RHEL9 and Fedora 35 operating systems are supported and
it's mainly used to runnung xfstests on ext4. But it can be easily expanded in
the future.

## What can it do?

* Create and initialize new virtual machine
* Clone a virtual machine for testing
* Run automatized scripts and tests on virtual machine

## What do you need?

You have to have the following tools available: `lvm` `virsh` `virt-builder`
`ssh`

The script utilizes lvm thin provisioning so you have to have lvm `volume
group` and lvm `thin-pool` already set up with some free space available.

**Example:**
	
	# Create a new volume group
	vgcreate lvm_pool /dev/sda /dev/sdb
	
	# Create a new thin-pool
	lvcreate -L 100G --thinpool thin-pool lvm_pool

The script also requires some configuration. See `vm.conf.template`.

## Disclaimer

This script is for my personal use and may not meet your expectations. I made
no effor making sure it works on any system other than mine for any purpose
other than what I use it for. **Please be careful!**
