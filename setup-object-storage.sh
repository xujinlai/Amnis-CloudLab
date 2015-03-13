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

HOSTNAME=`hostname -s`
if [ "$HOSTNAME" != "$OBJECTHOST" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-object-host-done ]; then
    exit 0
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

myip=`cat $OURDIR/mgmt-hosts | grep $HOSTNAME | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`

apt-get install -y xfsprogs rsync

mkdir -p /storage
dd if=/dev/zero of=/storage/pv.objectstore.loop.1 bs=32768 count=524288
LDEV=`losetup -f`
losetup $LDEV /storage/pv.objectstore.loop.1

mkfs.xfs $LDEV

mkdir -p /storage/mnt/swift

cat <<EOF >> /etc/fstab
$LDEV /storage/mnt/swift/pv.objectstore.loop.1 xfs noatime,nodiratime,nobarrier,logbufs=8 0 2
EOF

mkdir -p /storage/mnt/swift/pv.objectstore.loop.1
mount /storage/mnt/swift/pv.objectstore.loop.1

cat <<EOF >> /etc/rsyncd.conf
uid = swift
gid = swift
log file = /var/log/rsyncd.log
pid file = /var/run/rsyncd.pid
address = $myip

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


apt-get install -y swift swift-account swift-container swift-object

curl -o /etc/swift/account-server.conf \
    https://raw.githubusercontent.com/openstack/swift/stable/juno/etc/account-server.conf-sample

curl -o /etc/swift/container-server.conf \
    https://raw.githubusercontent.com/openstack/swift/stable/juno/etc/container-server.conf-sample

curl -o /etc/swift/object-server.conf \
    https://raw.githubusercontent.com/openstack/swift/stable/juno/etc/object-server.conf-sample

cat <<EOF >> /etc/swift/account-server.conf
[DEFAULT]
bind_ip = $myip
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
bind_ip = $myip
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
bind_ip = $myip
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
