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

HOSTNAME=`hostname -s`
if [ "$HOSTNAME" != "$STORAGEHOST" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-storage-host-done ]; then
    exit 0
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

myip=`cat $OURDIR/mgmt-hosts | grep $HOSTNAME | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`

apt-get install -y lvm2

# XXX: have to copy the .bak versions back into place on uBoot-nodes.
cp -p /boot/boot.scr.bak /boot/boot.scr
cp -p /boot/uImage.bak /boot/uImage
cp -p /boot/uInitrd.bak /boot/uInitrd

mkdir -p /storage
dd if=/dev/zero of=/storage/pvloop.1 bs=32768 count=524288
LDEV=`losetup -f`
losetup $LDEV /storage/pvloop.1

pvcreate /dev/loop0
vgcreate cinder-volumes /dev/loop0

apt-get install -y cinder-volume python-mysqldb

if [ "${STORAGEHOST}" != "${CONTROLLER}" ]; then
    # Just slap these in.
    cat <<EOF >> /etc/cinder/cinder.conf
[database]
connection = mysql://cinder:${CINDER_DBPASS}@$CONTROLLER/cinder

[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER}
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
my_ip = $myip
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

touch $OURDIR/setup-storage-host-done

exit 0
