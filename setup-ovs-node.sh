#!/bin/sh

#
# This sets up openvswitch networks (on neutron, the external and data
# networks).  The networkmanager and compute nodes' physical interfaces
# have to get moved into br-ex and br-int, respectively -- on the
# moonshots, that's eth0 and eth1.  The controller is special; it doesn't
# get an openvswitch setup, and gets eth1 10.0.0.3/8 .  The networkmanager
# is also special; it gets eth1 10.0.0.1/8, but its eth0 moves into br-ex,
# and its eth1 moves into br-int.  The compute nodes get IP addrs from
# 10.0.1.1/8 and up, but setup-ovs.sh determines that.
#

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

HOSTNAME=`hostname -s`

dataip=`cat $OURDIR/data-hosts | grep $HOSTNAME | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`

#
# If this is the controller, we don't have to do much network setup; just
# setup the data network with its IP.
#
if [ "$HOSTNAME" = "$CONTROLLER" ]; then
    if [ ${USE_EXISTING_DATA_IPS} -eq 0 ]; then
	ifconfig ${DATA_NETWORK_INTERFACE} $dataip netmask 255.0.0.0 up
    fi
    exit 0;
fi

#
# Otherwise, first we need openvswitch.
#
apt-get install -y openvswitch-common openvswitch-switch

# Make sure it's running
service openvswitch restart

#
# Setup the external network
#
ovs-vsctl add-br br-ex
ovs-vsctl add-port br-ex ${EXTERNAL_NETWORK_INTERFACE}
#ethtool -K $EXTERNAL_NETWORK_INTERFACE gro off

#
# Now move the $EXTERNAL_NETWORK_INTERFACE and default route config to br-ex
#
myip=`ifconfig ${EXTERNAL_NETWORK_INTERFACE} | sed -n -e 's/^.*inet addr:\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
mynetmask=`ifconfig ${EXTERNAL_NETWORK_INTERFACE} | sed -n -e 's/^.*Mask:\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
mygw=`ip route show default | sed -n -e 's/^default via \([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`

#
# We need to blow away the Emulab config -- no more dhcp
# This would definitely break experiment modify, of course
#
cat <<EOF > /etc/network/interfaces
# Openstack Network Node in Cloudlab

auto lo eth0

# The loopback network interface
iface lo inet loopback

iface br-ex inet static
    address $myip
    netmask $mynetmask
    gateway $mygw

iface ${EXTERNAL_NETWORK_INTERFACE} inet static
    address 0.0.0.0
EOF

ifconfig ${EXTERNAL_NETWORK_INTERFACE} 0 up
ifconfig br-ex $myip netmask $mynetmask up
route add default gw $mygw

service openvswitch-switch restart

#
# Make sure we have the integration bridge
#
ovs-vsctl add-br br-int

#
# (Maybe) Setup the data network
#
if [ ${SETUP_FLAT_DATA_NETWORK} -eq 1 ]; then
    ovs-vsctl add-br br-data
    ovs-vsctl add-port br-data ${DATA_NETWORK_INTERFACE}

    ifconfig ${DATA_NETWORK_INTERFACE} 0 up
    ifconfig br-data $dataip netmask 255.0.0.0 up

    cat <<EOF >> /etc/network/interfaces

auto lo eth0 ${DATA_NETWORK_INTERFACE}

iface br-data inet static
    address $dataip
    netmask 255.0.0.0

iface ${DATA_NETWORK_INTERFACE} inet static
    address 0.0.0.0
EOF
else
    if [ ${USE_EXISTING_DATA_IPS} -eq 0 ]; then
	ifconfig ${DATA_NETWORK_INTERFACE} $dataip netmask 255.0.0.0 up

	cat <<EOF >> /etc/network/interfaces

auto lo eth0 ${DATA_NETWORK_INTERFACE}

iface ${DATA_NETWORK_INTERFACE} inet static
    address $dataip
    netmask 255.0.0.0
EOF
    fi
fi

service openvswitch-switch restart

ip route flush cache

# Just wait a bit
#sleep 8

exit 0
