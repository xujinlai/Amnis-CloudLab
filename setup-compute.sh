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

if [ "$CONTROLLER" = "$HOSTNAME" -o "$NETWORKMANAGER" = "$HOSTNAME" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-compute-done ]; then
    exit 0
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

$APTGETINSTALL nova-compute sysfsutils
$APTGETINSTALL libguestfs-tools libguestfs0 python-guestfs

cat <<EOF >> /etc/nova/nova.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = $CONTROLLER
rabbit_userid = ${RABBIT_USER}
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
my_ip = $MGMTIP
verbose = ${VERBOSE_LOGGING}
debug = ${DEBUG_LOGGING}

[keystone_authtoken]
auth_uri = http://$CONTROLLER:5000/v2.0
identity_uri = http://$CONTROLLER:35357
admin_tenant_name = service
admin_user = nova
admin_password = ${NOVA_PASS}

[glance]
host = $CONTROLLER
EOF

#
# Change vnc_enabled = True for x86 -- but for aarch64, there is
# no video device, for KVM mode, anyway, it seems.
#
ARCH=`uname -m`
cname=`getfqdn $CONTROLLER`
if [ "$ARCH" = "aarch64" ] ; then
    cat <<EOF >> /etc/nova/nova.conf
[DEFAULT]
vnc_enabled = False
vncserver_listen = ${MGMTIP}
vncserver_proxyclient_address = $MGMTIP
novncproxy_base_url = http://${cname}:6080/vnc_auto.html
EOF
else
    cat <<EOF >> /etc/nova/nova.conf
[DEFAULT]
vnc_enabled = True
vncserver_listen = ${MGMTIP}
vncserver_proxyclient_address = $MGMTIP
novncproxy_base_url = http://${cname}:6080/vnc_auto.html
EOF
fi

if [ ${ENABLE_NEW_SERIAL_SUPPORT} = 1 ]; then
    cat <<EOF >> /etc/nova/nova.conf
[serial_console]
enabled = true
listen = $MGMTIP
proxyclient_address = $MGMTIP
base_url=ws://${cname}:6083/
EOF
fi

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

if [ ${OSCODENAME} = "juno" ]; then
    #
    # Patch quick :(
    #
    patch -d / -p0 < $DIRNAME/etc/nova-juno-root-device-name.patch
fi

service_restart nova-compute
service_enable nova-compute

# XXXX ???
# rm -f /var/lib/nova/nova.sqlite

touch $OURDIR/setup-compute-done

exit 0
