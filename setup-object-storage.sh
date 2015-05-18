#!/bin/sh

##
## Setup a OpenStack object storage node.
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ "$HOSTNAME" != "$OBJECTHOST" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-object-host-done ]; then
    exit 0
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi
if [ -f $LOCALSETTINGS ]; then
    . $LOCALSETTINGS
fi

$APTGETINSTALL xfsprogs rsync

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
    dd if=/dev/zero of=/storage/swiftv1 bs=32768 count=131072
    LDEV=`losetup -f`
    losetup $LDEV /storage/swiftv1
else
    lvcreate -n swiftv1 -L 4G $VGNAME
    LDEV=/dev/${VGNAME}/swiftv1
fi

mkfs.xfs $LDEV

mkdir -p /storage/mnt/swift
cat <<EOF >> /etc/fstab
$LDEV /storage/mnt/swift/swiftv1 xfs noatime,nodiratime,nobarrier,logbufs=8 0 2
EOF

mkdir -p /storage/mnt/swift/swiftv1
mount /storage/mnt/swift/swiftv1

cat <<EOF >> /etc/rsyncd.conf
uid = swift
gid = swift
log file = /var/log/rsyncd.log
pid file = /var/run/rsyncd.pid
address = $MGMTIP

[account]
max connections = 8
path = /storage/mnt/swift
read only = false
lock file = /var/lock/account.lock

[container]
max connections = 8
path = /storage/mnt/swift
read only = false
lock file = /var/lock/container.lock

[object]
max connections = 8
path = /storage/mnt/swift
read only = false
lock file = /var/lock/object.lock
EOF

cat <<EOF >> /etc/default/rsync
RSYNC_ENABLE=true
EOF

service rsync start


$APTGETINSTALL swift swift-account swift-container swift-object

wget -O /etc/swift/account-server.conf \
    https://raw.githubusercontent.com/openstack/swift/stable/${OSCODENAME}/etc/account-server.conf-sample

wget -O /etc/swift/container-server.conf \
    https://raw.githubusercontent.com/openstack/swift/stable/${OSCODENAME}/etc/container-server.conf-sample

wget -O /etc/swift/object-server.conf \
    https://raw.githubusercontent.com/openstack/swift/stable/${OSCODENAME}/etc/object-server.conf-sample

cat <<EOF >> /etc/swift/account-server.conf
[DEFAULT]
bind_ip = $MGMTIP
bind_port = 6002
user = swift
swift_dir = /etc/swift
devices = /storage/mnt/swift

[pipeline:main]
pipeline = healthcheck recon account-server

[filter:recon]
recon_cache_path = /var/cache/swift
EOF

cat <<EOF >> /etc/swift/container-server.conf
[DEFAULT]
bind_ip = $MGMTIP
bind_port = 6001
user = swift
swift_dir = /etc/swift
devices = /storage/mnt/swift

[pipeline:main]
pipeline = healthcheck recon container-server

[filter:recon]
recon_cache_path = /var/cache/swift
EOF

cat <<EOF >> /etc/swift/object-server.conf
[DEFAULT]
bind_ip = $MGMTIP
bind_port = 6000
user = swift
swift_dir = /etc/swift
devices = /storage/mnt/swift

[pipeline:main]
pipeline = healthcheck recon object-server

[filter:recon]
recon_cache_path = /var/cache/swift
EOF

chown -R swift:swift /storage/mnt/swift

mkdir -p /var/cache/swift
chown -R swift:swift /var/cache/swift

swift-init all start

touch $OURDIR/setup-object-host-done

exit 0
