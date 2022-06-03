#!/bin/bash

dnf -y install rpm-build meson g++ gcc

rpm -ivh http://mirror.stream.centos.org/9-stream/BaseOS/source/tree/Packages/inih-49-5.el9.src.rpm

cd /root/rpmbuild/SPECS
rpmbuild -bb inih.spec

cd /root/rpmbuild/RPMS/x86_64
dnf -y install inih-deve*.rpm
