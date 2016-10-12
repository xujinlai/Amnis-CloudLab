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

logtstart "linuxbridge-node"

#
# Figure out which interfaces need to go where.  We already have 
# $EXTERNAL_NETWORK_INTERFACE from setup-lib.sh , and it and its configuration
# get applied to br-ex .  So, we need to find which interface corresponds to
# DATALAN on this node, if any, and move it (and its configuration OR its new
# new DATAIP iff USE_EXISTING_IPS was set) to br-int
#
EXTERNAL_NETWORK_BRIDGE="br-ex"
#DATA_NETWORK_INTERFACE=`ip addr show | grep "inet $MYIP" | sed -e "s/.*scope global \(.*\)\$/\1/"`
DATA_NETWORK_BRIDGE="br-data"
INTEGRATION_NETWORK_BRIDGE="br-int"

#
# If this is the controller, we don't have to do much network setup; just
# setup the data network with its IP.
#
#if [ "$HOSTNAME" = "$CONTROLLER" ]; then
#    if [ ${USE_EXISTING_IPS} -eq 0 ]; then
#	ifconfig ${DATA_NETWORK_INTERFACE} $DATAIP netmask 255.0.0.0 up
#    fi
#    exit 0;
#fi

#
# Grab our control net info before we change things around.
#
if [ ! -f $OURDIR/ctlnet.vars ]; then
    ctlip="$MYIP"
    ctlmac=`ip -o link show ${EXTERNAL_NETWORK_INTERFACE} | sed -n -e 's/^.*link\/ether \([0-9a-fA-F:]*\) .*$/\1/p'`
    ctlstrippedmac=`echo $ctlmac | sed -e 's/://g'`
    ctlnetmask=`ifconfig ${EXTERNAL_NETWORK_INTERFACE} | sed -n -e 's/^.*Mask:\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
    ctlgw=`ip route show default | sed -n -e 's/^default via \([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
    ctlnet=`ip route show dev ${EXTERNAL_NETWORK_INTERFACE} | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\/[0-9]*\) .*$/\1/p'`

    echo "ctlip=\"$ctlip\"" > $OURDIR/ctlnet.vars
    echo "ctlmac=\"$ctlmac\"" >> $OURDIR/ctlnet.vars
    echo "ctlstrippedmac=\"$ctlstrippedmac\"" >> $OURDIR/ctlnet.vars
    echo "ctlnetmask=\"$ctlnetmask\"" >> $OURDIR/ctlnet.vars
    echo "ctlgw=\"$ctlgw\"" >> $OURDIR/ctlnet.vars
    echo "ctlnet=\"$ctlnet\"" >> $OURDIR/ctlnet.vars
else
    . $OURDIR/ctlnet.vars
fi

#
# Make the configuration for the $EXTERNAL_NETWORK_INTERFACE be static.
#
DNSDOMAIN=`cat /etc/resolv.conf | grep search | head -1 | awk '{ print $2 }'`
DNSSERVER=`cat /etc/resolv.conf | grep nameserver | head -1 | awk '{ print $2 }'`

#
# We need to blow away the Emulab config -- no more dhcp
# This would definitely break experiment modify, of course
#
cat <<EOF > /etc/network/interfaces
#
# Openstack Network Node in Cloudlab/Emulab/Apt/Federation
#

# The loopback network interface
auto lo
iface lo inet loopback

auto ${EXTERNAL_NETWORK_INTERFACE}
iface ${EXTERNAL_NETWORK_INTERFACE} inet static
    address $ctlip
    netmask $ctlnetmask
    gateway $ctlgw
    dns-search $DNSDOMAIN
    dns-nameservers $DNSSERVER
EOF

#
# Add the management network config if necessary (if not, it's already a VPN)
#
if [ ! -z "$MGMTLAN" ]; then
    cat <<EOF >> /etc/network/interfaces

auto ${MGMT_NETWORK_INTERFACE}
iface ${MGMT_NETWORK_INTERFACE} inet static
    address $MGMTIP
    netmask $MGMTNETMASK
EOF
    if [ -n "$MGMTVLANDEV" ]; then
	cat <<EOF >> /etc/network/interfaces
    vlan-raw-device ${MGMTVLANDEV}
EOF
    fi
fi

#
# (Maybe) Setup the flat data networks
#
for lan in $DATAFLATLANS ; do
    # suck in the vars we'll use to configure this one
    . $OURDIR/info.$lan

    cat <<EOF >> /etc/network/interfaces

auto ${DATADEV}
iface ${DATADEV} inet static
    address $DATAIP
    netmask $DATANETMASK
EOF
    if [ -n "$DATAVLANDEV" ]; then
	cat <<EOF >> /etc/network/interfaces
    vlan-raw-device ${DATAVLANDEV}
EOF
    fi
done

#
# (Maybe) Setup the VLAN data networks.
# Note, these are for the case where we're giving openstack the chance
# to manage these networks... so we delete the emulab-created vlan devices,
# create an openvswitch switch for the vlan device, and just add the physical
# device as a port.  Simple.
#
for lan in $DATAVLANS ; do
    # suck in the vars we'll use to configure this one
    . $OURDIR/info.$lan

    ifconfig $DATADEV down
    vconfig rem $DATADEV
done

#else
#    ifconfig ${DATA_NETWORK_INTERFACE} $DATAIP netmask 255.0.0.0 up
#
#    cat <<EOF >> /etc/network/interfaces
#
#auto ${DATA_NETWORK_INTERFACE}
#iface ${DATA_NETWORK_INTERFACE} inet static
#    address $DATAIP
#    netmask $DATANETMASK
#EOF
#    if [ -n "$DATAVLANDEV" ]; then
#	cat <<EOF >> /etc/network/interfaces
#    vlan-raw-device ${DATAVLANDEV}
#EOF
#    fi
#fi

#
# Set the hostname for later after reboot!
#
echo `hostname` > /etc/hostname

echo "*** Removing Emulab rc.hostnames and rc.ifconfig boot scripts"
mv /usr/local/etc/emulab/rc/rc.hostnames /usr/local/etc/emulab/rc/rc.hostnames.NO
mv /usr/local/etc/emulab/rc/rc.ifconfig /usr/local/etc/emulab/rc/rc.ifconfig.NO

if [ ! ${HAVE_SYSTEMD} -eq 0 ] ; then
    # Maybe this is helpful too
    update-rc.d networking remove
    update-rc.d networking defaults
    # This seems to block systemd from doing its job...
    systemctl disable ifup-wait-emulab-cnet.service
    systemctl mask ifup-wait-emulab-cnet.service
    systemctl stop ifup-wait-emulab-cnet.service

    systemctl daemon-reload
fi

logtend "linuxbridge-node"

exit 0

#
# Install a basic ARP reply filter that prevents us from sending ARP replies on
# the control net for anything we're not allowed to use (i.e., we can reply for
# ourselves, and any public addresses we're allowed to use).  Really, we only
# need the public address part on the network manager, but may as well let
# any node reply as any public address we're allowed to use).
#

# Cheat and use our IPADDR/NETMASK instead of NETWORK/NETMASK below...
OURNET=`ip addr show br-ex | sed -n -e 's/.*inet \([0-9\.\/]*\) .*/\1/p'`
# Grab the port that corresponds to our
OURPORT=`ovs-ofctl show br-ex | sed -n -e "s/[ \t]*\([0-9]*\)(${EXTERNAL_NETWORK_INTERFACE}.*\$/\1/p"`

#
# Ok, make the anti-ARP spoofing rules live, and also place them in the right
# place to be picked up by our neutron openvswitch agent so that when it
# remove_all_flows() it also installs our "system" defaults.
#
mkdir -p /etc/neutron/ovs-default-flows
FF=/etc/neutron/ovs-default-flows/br-ex
touch ${FF}

FLOW="dl_type=0x0806,nw_proto=0x2,arp_spa=${ctlip},actions=NORMAL"
ovs-ofctl add-flow br-ex "$FLOW"
echo "$FLOW" >> $FF

for addr in $PUBLICADDRS ; do
    FLOW="dl_type=0x0806,nw_proto=0x2,arp_spa=${addr},actions=NORMAL"
    ovs-ofctl add-flow br-ex "$FLOW"
    echo "$FLOW" >> $FF
done
# Allow any inbound ARP replies on the control network.
FLOW="dl_type=0x0806,nw_proto=0x2,arp_spa=${OURNET},in_port=${OURPORT},actions=NORMAL"
ovs-ofctl add-flow br-ex "$FLOW"
echo "$FLOW" >> $FF

# Drop any other control network addr ARP replies on the br-ex switch.
FLOW="dl_type=0x0806,nw_proto=0x2,arp_spa=${OURNET},actions=drop"
ovs-ofctl add-flow br-ex "$FLOW"
echo "$FLOW" >> $FF

# Also, drop Emulab vnode control network addr ARP replies on br-ex!
FLOW="dl_type=0x0806,nw_proto=0x2,arp_spa=172.16.0.0/12,actions=drop"
ovs-ofctl add-flow br-ex "$FLOW"
echo "$FLOW" >> $FF

exit 0
