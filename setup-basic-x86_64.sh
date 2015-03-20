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

wget https://cloud-images.ubuntu.com/trusty/current/trusty-server-cloudimg-amd64-disk1.img

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

echo "*** Modifying root password..."

sed -in -e 's@root:\*:@root:$6$lMUVMHvx$JkBLzWKF/v6s/UQx1RlNPbIS7nEVjqfZwtQJcb1r.pEuMiV0JO1Z9r4w2s9ULJ22JLlY8.sU.whzQRil0f7sF/:@' /mnt/etc/shadow

umount /mnt
qemu-nbd -d /dev/nbd0

echo "*** Importing new image ..."

glance image-create --name trusty-server --is-public True  --disk-format qcow2 --container-format bare --progress --file trusty-server-cloudimg-amd64-disk1.img

exit 0
