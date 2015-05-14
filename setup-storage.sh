#!/bin/sh

##
## Setup a OpenStack compute node for Nova.
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ "$HOSTNAME" != "$STORAGEHOST" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-storage-host-done ]; then
    exit 0
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi
if [ -f $LOCALSETTINGS ]; then
    . $LOCALSETTINGS
fi

ARCH=`uname -m`

$APTGETINSTALL lvm2

if [ "$ARCH" = "aarch64" ]; then
    # XXX: have to copy the .bak versions back into place on uBoot-nodes.
    cp -p /boot/boot.scr.bak /boot/boot.scr
    cp -p /boot/uImage.bak /boot/uImage
    cp -p /boot/uInitrd.bak /boot/uInitrd
fi

#
# First try to make LVM volumes; fall back to loop device in /storage.  We use
# /storage for swift later, so we make the dir either way.
#

mkdir -p /storage
if [ -z "$LVM" ] ; then
    LVM=1
    VGNAME="openstack-volumes"
    MKEXTRAFS_ARGS="-l -v ${VGNAME} -m util -z 1G"
    # On Cloudlab ARM machines, there is no second disk nor extra disk space
    if [ "$ARCH" = "aarch64" ]; then
	MKEXTRAFS_ARGS=""
	LVM=0
    fi

    /usr/local/etc/emulab/mkextrafs.pl ${MKEXTRAFS_ARGS}
    if [ $? -ne 0 ]; then
	/usr/local/etc/emulab/mkextrafs.pl ${MKEXTRAFS_ARGS} -f
	if [ $? -ne 0 ]; then
	    /usr/local/etc/emulab/mkextrafs.pl -f /storage
	    LVM=0
	fi
    fi
fi

if [ $LVM -eq 0 ] ; then
    dd if=/dev/zero of=/storage/pvloop.1 bs=32768 count=131072
    LDEV=`losetup -f`
    losetup $LDEV /storage/pvloop.1

    pvcreate /dev/loop0
    vgcreate $VGNAME /dev/loop0
fi

$APTGETINSTALL cinder-volume python-mysqldb

if [ "${STORAGEHOST}" != "${CONTROLLER}" ]; then
    # Just slap these in.
    cat <<EOF >> /etc/cinder/cinder.conf
[database]
connection = mysql://cinder:${CINDER_DBPASS}@$CONTROLLER/cinder

[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER}
rabbit_userid = ${RABBIT_USER}
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
my_ip = $MGMTIP
verbose = True
glance_host = ${CONTROLLER}

[keystone_authtoken]
auth_uri = http://$CONTROLLER:5000/v2.0
identity_uri = http://$CONTROLLER:35357
admin_tenant_name = service
admin_user = cinder
admin_password = ${CINDER_PASS}
EOF

    sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/cinder/cinder.conf
    sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/cinder/cinder.conf
    sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/cinder/cinder.conf
fi

service tgt restart
service cinder-volume restart
rm -f /var/lib/cinder/cinder.sqlite

echo "LVM=$LVM" >> $LOCALSETTINGS
echo "VGNAME=${VGNAME}" >> $LOCALSETTINGS

touch $OURDIR/setup-storage-host-done

exit 0
