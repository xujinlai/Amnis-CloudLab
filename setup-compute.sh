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

#
# This is a nasty bug in oslo_service; see 
# https://review.openstack.org/#/c/256267/
#
if [ $OSVERSION -ge $OSKILO ]; then
    maybe_install_packages python-oslo.service
    patch -d / -p0 < $DIRNAME/etc/oslo_service-liberty-sig-MAINLOOP.patch
fi

maybe_install_packages nova-compute sysfsutils
maybe_install_packages libguestfs-tools libguestfs0 python-guestfs

#
# Once we install packages, if the user wants a bigger VM disk space
# area, we make that and copy anything in /var/lib/nova into it (which
# may include stuff that was just installed).  Then we bind mount it to
# /var/lib/nova .
#
if [ "$COMPUTE_EXTRA_NOVA_DISK_SPACE" = "1" ]; then
    mkdir -p /mnt/var-lib-nova
    /usr/local/etc/emulab/mkextrafs.pl -r sda -s 4 /mnt/var-lib-nova
    if [ $? = 0 ]; then
	chown nova:nova /mnt/var-lib-nova
	rsync -avz /var/lib/nova/ /mnt/var-lib-nova/
	mount -o bind /mnt/var-lib-nova /var/lib/nova
	echo "/mnt/var-lib-nova /var/lib/nova none defaults,bind 0 0" \
	    >> /etc/fstab
    else
	echo "*** ERROR: could not make larger Nova /var/lib/nova dir!"
    fi
fi

crudini --set /etc/nova/nova.conf DEFAULT rpc_backend rabbit
crudini --set /etc/nova/nova.conf DEFAULT auth_strategy keystone
crudini --set /etc/nova/nova.conf DEFAULT my_ip ${MGMTIP}
crudini --set /etc/nova/nova.conf glance host $CONTROLLER
crudini --set /etc/nova/nova.conf DEFAULT verbose ${VERBOSE_LOGGING}
crudini --set /etc/nova/nova.conf DEFAULT debug ${DEBUG_LOGGING}

if [ $OSVERSION -lt $OSKILO ]; then
    crudini --set /etc/nova/nova.conf DEFAULT rabbit_host $CONTROLLER
    crudini --set /etc/nova/nova.conf DEFAULT rabbit_userid ${RABBIT_USER}
    crudini --set /etc/nova/nova.conf DEFAULT rabbit_password "${RABBIT_PASS}"

    crudini --set /etc/nova/nova.conf keystone_authtoken \
	auth_uri http://${CONTROLLER}:5000/v2.0
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	identity_uri http://${CONTROLLER}:35357
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	admin_tenant_name service
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	admin_user nova
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	admin_password "${NOVA_PASS}"
else
    crudini --set /etc/nova/nova.conf oslo_messaging_rabbit \
	rabbit_host $CONTROLLER
    crudini --set /etc/nova/nova.conf oslo_messaging_rabbit \
	rabbit_userid ${RABBIT_USER}
    crudini --set /etc/nova/nova.conf oslo_messaging_rabbit \
	rabbit_password "${RABBIT_PASS}"

    crudini --set /etc/nova/nova.conf keystone_authtoken \
	auth_uri http://${CONTROLLER}:5000
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	auth_url http://${CONTROLLER}:35357
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	${AUTH_TYPE_PARAM} password
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	${PROJECT_DOMAIN_PARAM} default
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	${USER_DOMAIN_PARAM} default
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	project_name service
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	username nova
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	password "${NOVA_PASS}"
fi

if [ $OSVERSION -ge $OSKILO ]; then
    crudini --set /etc/nova/nova.conf oslo_concurrency \
	lock_path /var/lib/nova/tmp
fi

if [ $OSVERSION -ge $OSLIBERTY ]; then
    crudini --set /etc/nova/nova.conf enabled_apis 'osapi_compute,metadata'

    crudini --set /etc/nova/nova.conf DEFAULT \
	network_api_class nova.network.neutronv2.api.API
    crudini --set /etc/nova/nova.conf DEFAULT use_neutron True
    crudini --set /etc/nova/nova.conf DEFAULT \
	security_group_api neutron
    crudini --set /etc/nova/nova.conf DEFAULT \
	linuxnet_interface_driver nova.network.linux_net.NeutronLinuxBridgeInterfaceDriver
    crudini --set /etc/nova/nova.conf DEFAULT \
	firewall_driver nova.virt.firewall.NoopFirewallDriver
fi

VNCSECTION="DEFAULT"
if [ $OSVERSION -ge $OSLIBERTY ]; then
    VNCSECTION="vnc"
fi

cname=`getfqdn $CONTROLLER`
crudini --set /etc/nova/nova.conf $VNCSECTION vncserver_listen ${MGMTIP}
crudini --set /etc/nova/nova.conf $VNCSECTION vncserver_proxyclient_address ${MGMTIP}
crudini --set /etc/nova/nova.conf $VNCSECTION \
    novncproxy_base_url "http://${cname}:6080/vnc_auto.html"
#
# Change vnc_enabled = True for x86 -- but for aarch64, there is
# no video device, for KVM mode, anyway, it seems.
#
ARCH=`uname -m`
if [ "$ARCH" = "aarch64" ] ; then
    if [ $OSVERSION -le $OSKILO ]; then
	crudini --set /etc/nova/nova.conf $VNCSECTION vnc_enabled False
    else
	# QEMU/Nova on Liberty gives aarch64 a vga adapter/bus.
	crudini --set /etc/nova/nova.conf $VNCSECTION vnc_enabled True
    fi
else
    crudini --set /etc/nova/nova.conf $VNCSECTION vnc_enabled True
fi

if [ ${ENABLE_NEW_SERIAL_SUPPORT} = 1 ]; then
    crudini --set /etc/nova/nova.conf serial_console enabled true
    crudini --set /etc/nova/nova.conf serial_console listen $MGMTIP
    crudini --set /etc/nova/nova.conf serial_console proxyclient_address $MGMTIP
    crudini --set /etc/nova/nova.conf serial_console base_url ws://${cname}:6083/
fi

crudini --set /etc/nova/nova-compute.conf DEFAULT \
    compute_driver libvirt.LibvirtDriver
crudini --set /etc/nova/nova-compute.conf libvirt virt_type kvm

if [ "$ARCH" = "aarch64" ] ; then
    crudini --set /etc/nova/nova-compute.conf libvirt cpu_mode custom
    crudini --set /etc/nova/nova-compute.conf libvirt cpu_model host

    if [ $OSVERSION -ge $OSLIBERTY ]; then
	crudini --set /etc/nova/nova-compute.conf libvirt video_type vga
	crudini --set /etc/nova/nova-compute.conf libvirt use_usb_tablet False
    fi
fi

if [ ${OSCODENAME} = "juno" ]; then
    #
    # Patch quick :(
    #
    patch -d / -p0 < $DIRNAME/etc/nova-juno-root-device-name.patch
fi

service_restart nova-compute
service_enable nova-compute
service_restart libvirt-bin
service_enable libvirt-bin

# XXXX ???
# rm -f /var/lib/nova/nova.sqlite

touch $OURDIR/setup-compute-done

exit 0
