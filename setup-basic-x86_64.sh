#!/bin/sh

##
## Initialize some basic aarch64 stuff.
##

set -x

DIRNAME=`dirname $0`

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "$DIRNAME/setup-lib.sh"

if [ "$HOSTNAME" != "$CONTROLLER" ]; then
    exit 0;
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

. $OURDIR/admin-openrc.sh

echo "*** Downloading an x86_64 image ..."

#wget https://cloud-images.ubuntu.com/trusty/current/trusty-server-cloudimg-amd64-disk1.img
wget http://boss.apt.emulab.net/downloads/trusty-server-cloudimg-amd64-disk1.img

echo "*** Modifying to support 3 NICs..."

modprobe nbd max_part=8
qemu-nbd --connect=/dev/nbd0 trusty-server-cloudimg-amd64-disk1.img
mount /dev/nbd0p1 /mnt/
cat <<EOF >> /etc/network/interfaces/eth1.cfg
auto eth1
iface eth1 inet dhcp
EOF
cat <<EOF >> /etc/network/interfaces/eth2.cfg
auto eth2
iface eth2 inet dhcp
EOF

echo "*** Setting up sshd ..."
sed -i -e 's/^.*PermitRootLogin .*$/PermitRootLogin yes/' /mnt/etc/ssh/sshd_config
sed -i -e 's/^.*PasswordAuthentication .*$/PasswordAuthentication yes/' /mnt/etc/ssh/sshd_config

echo "*** Modifying root password..."

echo "*** fixing root password ..."
sed -i -e 's@root:[^:]*:@root:$6$QDmiL4Pp$OxXz9eP112jYY4rljT.1QUFqw.PW9g85VMapJehvRIDrkio1LN.74Tq40XbkvxCXAGEcLi.eZOaCFqgelSzOA/:@' /mnt/etc/shadow

echo "*** fixing ubuntu password ..."
sed -i -e 's@ubuntu:[^:]*:@ubuntu:$6$QDmiL4Pp$OxXz9eP112jYY4rljT.1QUFqw.PW9g85VMapJehvRIDrkio1LN.74Tq40XbkvxCXAGEcLi.eZOaCFqgelSzOA/:@' /mnt/etc/shadow

# permit root login!!
sed -i -e 's/^disable_root: true$/disable_root: false/' /mnt/etc/cloud/cloud.cfg

# don't overwrite the Ubuntu passwd we just hacked in
sed -i -e 's/^.*lock_passwd:.*$/     lock_passwd: False/' /mnt/etc/cloud/cloud.cfg

umount /mnt
qemu-nbd -d /dev/nbd0

echo "*** Importing new image ..."

glance image-create --name trusty-server --is-public True  --disk-format qcow2 --container-format bare --progress --file trusty-server-cloudimg-amd64-disk1.img

exit 0
