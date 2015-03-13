#!/bin/sh

##
## Setup a OpenStack compute node for Ceilometer.
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
if [ "$HOSTNAME" = "$CONTROLLER" -o "$HOSTNAME" = "$NETWORKMANAGER" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-compute-telemetry-done ]; then
    exit 0
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi



apt-get install -y ceilometer-agent-compute

# Just slap these in.
cat <<EOF >> /etc/nova/nova.conf
[DEFAULT]
instance_usage_audit = True
instance_usage_audit_period = hour
notify_on_state_change = vm_and_task_state
notification_driver = nova.openstack.common.notifier.rpc_notifier
notification_driver = ceilometer.compute.nova_notifier
EOF

service nova-compute restart

cat <<EOF >> /etc/ceilometer/ceilometer.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER}
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
verbose = True
log_dir = /var/log/ceilometer

[keystone_authtoken]
auth_uri = http://${CONTROLLER}:5000/v2.0
identity_uri = http://${CONTROLLER}:35357
admin_tenant_name = service
admin_user = ceilometer
admin_password = ${CEILOMETER_PASS}

[publisher]
# Secret value for signing metering messages (string value)
metering_secret = ${CEILOMETER_SECRET}

[service_credentials]
os_auth_url = http://${CONTROLLER}:5000/v2.0
os_username = ceilometer
os_tenant_name = service
os_password = ${CEILOMETER_PASS}
os_endpoint_type = internalURL
EOF

#sed -i -e "s/^\\(.*connection.*=.*\\)$/#\1/" /etc/ceilometer/ceilometer.conf
sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/ceilometer/ceilometer.conf
sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/ceilometer/ceilometer.conf
sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/ceilometer/ceilometer.conf

service ceilometer-agent-compute restart

touch $OURDIR/setup-compute-telemetry-done

exit 0
