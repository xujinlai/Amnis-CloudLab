#!/bin/sh

##
## Setup a OpenStack Storage Node for Telemetry
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

if [ -f $OURDIR/setup-storage-telemetry-done ]; then
    exit 0
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

cat <<EOF >> /etc/cinder/cinder.conf
[DEFAULT]
control_exchange = cinder
notification_driver = cinder.openstack.common.notifier.rpc_notifier
EOF

service cinder-volume restart

touch $OURDIR/setup-storage-telemetry-done

exit 0
