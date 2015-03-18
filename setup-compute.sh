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

DIRNAME=`dirname $0`

# Grab our libs
. "$DIRNAME/setup-lib.sh"

HOSTNAME=`hostname -s`
if [ "$HOSTNAME" == "$CONTROLLER" -o "$HOSTNAME" == "$NETWORKMANAGER" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-compute-done ]; then
    exit 0
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

apt-get install -y nova-compute sysfsutils < /dev/null
apt-get install -y libguestfs-tools libguestfs0 python-guestfs < /dev/null

#
# Change vnc_enabled = True for x86 -- but for aarch64, there is
# no video device, for KVM mode, anyway, it seems.
#
cat <<EOF >> /etc/nova/nova.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = $CONTROLLER
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
my_ip = $MGMTIP
vnc_enabled = False
vncserver_listen = 0.0.0.0
vncserver_proxyclient_address = $MGMTIP
novncproxy_base_url = http://$CONTROLLER:6080/vnc_auto.html
verbose = True

[keystone_authtoken]
auth_uri = http://$CONTROLLER:5000/v2.0
identity_uri = http://$CONTROLLER:35357
admin_tenant_name = service
admin_user = nova
admin_password = ${NOVA_PASS}

[glance]
host = $CONTROLLER
EOF

cat <<EOF >> /etc/nova/nova-compute.conf

[DEFAULT]
compute_driver=libvirt.LibvirtDriver

[libvirt]
virt_type=kvm
EOF

if [ "$ARCH" = "aarch64" ] ; then
    cat <<EOF >> /etc/nova/nova-compute.conf
cpu_mode=custom
cpu_model=host
EOF
fi

#
# Patch quick :(
#
patch -d / -p0 < $DIRNAME/etc/nova-juno-root-device-name.patch

service nova-compute restart

# XXXX ???
# rm -f /var/lib/nova/nova.sqlite

touch $OURDIR/setup-compute-done

exit 0
