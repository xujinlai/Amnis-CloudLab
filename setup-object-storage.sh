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

mkdir -p /var/log/swift
chown -R syslog.adm /var/log/swift

$APTGETINSTALL swift swift-account swift-container swift-object

wget -O /etc/swift/account-server.conf \
    "https://git.openstack.org/cgit/openstack/swift/plain/etc/account-server.conf-sample?h=stable/${OSCODENAME}"

wget -O /etc/swift/container-server.conf \
    "https://git.openstack.org/cgit/openstack/swift/plain/etc/container-server.conf-sample?h=stable/${OSCODENAME}"

wget -O /etc/swift/object-server.conf \
    "https://git.openstack.org/cgit/openstack/swift/plain/etc/object-server.conf-sample?h=stable/${OSCODENAME}"

if [ "$OSCODENAME" = "kilo" ]; then
    wget -O /etc/swift/container-reconciler.conf \
	"https://git.openstack.org/cgit/openstack/swift/plain/etc/container-reconciler.conf-sample?h=stable/${OSCODENAME}"
    wget -O /etc/swift/object-expirer.conf \
	"https://git.openstack.org/cgit/openstack/swift/plain/etc/object-expirer.conf-sample?h=stable/${OSCODENAME}"
fi

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

crudini --set /etc/swift/account-server.conf DEFAULT log_facility LOG_LOCAL1
crudini --set /etc/swift/account-server.conf DEFAULT log_level INFO
crudini --set /etc/swift/account-server.conf DEFAULT log_name swift-account
crudini --set /etc/swift/account-server.conf app:account-server log_facility LOG_LOCAL1
crudini --set /etc/swift/account-server.conf app:account-server log_level INFO
crudini --set /etc/swift/account-server.conf app:account-server log_name swift-account
crudini --set /etc/swift/account-server.conf account-replicator log_facility LOG_LOCAL1
crudini --set /etc/swift/account-server.conf account-replicator log_level INFO
crudini --set /etc/swift/account-server.conf account-replicator log_name swift-account-replicator
crudini --set /etc/swift/account-server.conf account-auditor log_facility LOG_LOCAL1
crudini --set /etc/swift/account-server.conf account-auditor log_level INFO
crudini --set /etc/swift/account-server.conf account-auditor log_name swift-account-auditor
crudini --set /etc/swift/account-server.conf account-reaper log_facility LOG_LOCAL1
crudini --set /etc/swift/account-server.conf account-reaper log_level INFO
crudini --set /etc/swift/account-server.conf account-reaper log_name swift-account-reaper

echo 'if $programname == "swift-account" then { action(type="omfile" file="/var/log/swift/swift-account.log") }' >> /etc/rsyslog.d/99-swift.conf

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

crudini --set /etc/swift/container-server.conf DEFAULT log_facility LOG_LOCAL1
crudini --set /etc/swift/container-server.conf DEFAULT log_level INFO
crudini --set /etc/swift/container-server.conf DEFAULT log_name swift-container
crudini --set /etc/swift/container-server.conf app:container-server log_facility LOG_LOCAL1
crudini --set /etc/swift/container-server.conf app:container-server log_level INFO
crudini --set /etc/swift/container-server.conf app:container-server log_name swift-container
crudini --set /etc/swift/container-server.conf container-replicator log_facility LOG_LOCAL1
crudini --set /etc/swift/container-server.conf container-replicator log_level INFO
crudini --set /etc/swift/container-server.conf container-replicator log_name swift-container-replicator
crudini --set /etc/swift/container-server.conf container-updater log_facility LOG_LOCAL1
crudini --set /etc/swift/container-server.conf container-updater log_level INFO
crudini --set /etc/swift/container-server.conf container-updater log_name swift-container-updater
crudini --set /etc/swift/container-server.conf container-auditor log_facility LOG_LOCAL1
crudini --set /etc/swift/container-server.conf container-auditor log_level INFO
crudini --set /etc/swift/container-server.conf container-auditor log_name swift-container-auditor
crudini --set /etc/swift/container-server.conf container-sync log_facility LOG_LOCAL1
crudini --set /etc/swift/container-server.conf container-sync log_level INFO
crudini --set /etc/swift/container-server.conf container-sync log_name swift-container-sync

echo 'if $programname == "swift-container" then { action(type="omfile" file="/var/log/swift/swift-container.log") }' >> /etc/rsyslog.d/99-swift.conf

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
if [ "$OSCODENAME" = "kilo" ]; then
    cat <<EOF >> /etc/swift/object-server.conf
[filter:recon]
recon_lock_path = /var/lock
EOF
fi

crudini --set /etc/swift/object-server.conf DEFAULT log_facility LOG_LOCAL1
crudini --set /etc/swift/object-server.conf DEFAULT log_level INFO
crudini --set /etc/swift/object-server.conf DEFAULT log_name swift-object
crudini --set /etc/swift/object-server.conf app:object-server log_facility LOG_LOCAL1
crudini --set /etc/swift/object-server.conf app:object-server log_level INFO
crudini --set /etc/swift/object-server.conf app:object-server log_name swift-object
crudini --set /etc/swift/object-server.conf object-replicator log_facility LOG_LOCAL1
crudini --set /etc/swift/object-server.conf object-replicator log_level INFO
crudini --set /etc/swift/object-server.conf object-replicator log_name swift-object-replicator
crudini --set /etc/swift/object-server.conf object-reconstructor log_facility LOG_LOCAL1
crudini --set /etc/swift/object-server.conf object-reconstructor log_level INFO
crudini --set /etc/swift/object-server.conf object-reconstructor log_name swift-object-reconstructor
crudini --set /etc/swift/object-server.conf object-updater log_facility LOG_LOCAL1
crudini --set /etc/swift/object-server.conf object-updater log_level INFO
crudini --set /etc/swift/object-server.conf object-updater log_name swift-object-updater
crudini --set /etc/swift/object-server.conf object-auditor log_facility LOG_LOCAL1
crudini --set /etc/swift/object-server.conf object-auditor log_level INFO
crudini --set /etc/swift/object-server.conf object-auditor log_name swift-object-auditor

echo 'if $programname == "swift-object" then { action(type="omfile" file="/var/log/swift/swift-object.log") }' >> /etc/rsyslog.d/99-swift.conf

chown -R swift:swift /storage/mnt/swift

mkdir -p /var/cache/swift
chown -R swift:swift /var/cache/swift

if [ ${HAVE_SYSTEMD} -eq 0 ]; then
    swift-init all start
    service rsyslog restart
else
    systemctl restart rsyslog
    systemctl restart swift-account.service
    systemctl restart swift-account-replicator.service
    systemctl restart swift-account-auditor.service
    systemctl restart swift-account-reaper.service
    systemctl restart swift-container.service
    systemctl restart swift-container-auditor.service
    systemctl restart swift-container-replicator.service
    systemctl restart swift-container-sync.service
    systemctl restart swift-container-updater.service
    systemctl restart swift-object.service
    systemctl restart swift-object-auditor.service
    systemctl restart swift-object-replicator.service
    systemctl restart swift-object-updater.service
fi

touch $OURDIR/setup-object-host-done

exit 0
