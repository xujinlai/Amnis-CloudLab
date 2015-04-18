#!/bin/sh

set -x

DIRNAME=`dirname $0`

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "$DIRNAME/setup-lib.sh"

echo "*** Setting up root ssh pubkey access across all nodes..."

# All nodes need to publish public keys, and acquire others'
$DIRNAME/setup-root-ssh.sh 1> $OURDIR/setup-root-ssh.log 2>&1

if [ "$HOSTNAME" != "$NETWORKMANAGER" ]; then
    exit 0;
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

echo "*** Waiting for ssh access to all nodes..."

for node in $NODES ; do
    [ "$node" = "$NETWORKMANAGER" ] && continue

    SUCCESS=1
    fqdn=$node.$EEID.$EPID.$OURDOMAIN
    while [ $SUCCESS -ne 0 ] ; do
	sleep 1
	ssh -o ConnectTimeout=1 -o PasswordAuthentication=No -o NumberOfPasswordPrompts=0 -o StrictHostKeyChecking=No $fqdn /bin/ls > /dev/null
	SUCCESS=$?
    done
    echo "*** $node is up!"
done

echo "*** Setting up Management and Data Network IP Addresses"

#
# Create IP addresses for the Management and Data networks, as necessary.
#
if [ -z "${MGMTLAN}" -o ${USE_EXISTING_MGMT_IPS} -eq 0 ]; then
    echo "255.255.0.0" > $OURDIR/mgmt-netmask
    echo "192.168.0.1 $NETWORKMANAGER" > $OURDIR/mgmt-hosts
    echo "192.168.0.3 $CONTROLLER" >> $OURDIR/mgmt-hosts
    o3=0
    o4=5
    for node in $NODES
    do
	[ "$node" = "$CONTROLLER" -o "$node" = "$NETWORKMANAGER" ] \
	    && continue

	echo "192.168.$o3.$o4 $node" >> $OURDIR/mgmt-hosts

        # Skip 2 for openvpn tun tunnels
	o4=`expr $o4 + 2`
	if [ $o4 -gt 253 ] ; then
	    o4=10
	    o3=`expr $o3 + 1`
	fi
    done
else
    cat $TOPOMAP | grep -v '^#' | sed -e 's/,/ /' \
	| sed -n -e "s/\([a-zA-Z0-9_\-]*\) .*${MGMTLAN}:\([0-9\.]*\).*\$/\2\t\1/p" \
	> $OURDIR/mgmt-hosts
    cat /var/emulab/boot/tmcc/ifconfig \
	| sed -n -e "s/.* MASK=\([0-9\.]*\) .* LAN=${MGMTLAN}/\1/p" \
	> $OURDIR/mgmt-netmask
fi

#
# If USE_EXISTING_DATA_IPS is set to 0, we will re-IP those data lan
# interfaces: networkmanager:eth1 gets 10.0.0.1/8, and controller gets
# 10.0.0.3/8; and the compute nodes get 10.0.x.y, where x starts at 1,
# and y starts at 1 and does not exceed 254.
#
if [ ${USE_EXISTING_DATA_IPS} -eq 0 ]; then
    echo "255.0.0.0" > $OURDIR/data-netmask
    echo "10.0.0.1 $NETWORKMANAGER" > $OURDIR/data-hosts
    echo "10.0.0.3 $CONTROLLER" >> $OURDIR/data-hosts

    #
    # Now set static IPs for the compute nodes.
    #
    o3=1
    o4=1
    for node in $NODES
    do
	[ "$node" = "$CONTROLLER" -o "$node" = "$NETWORKMANAGER" ] \
	    && continue

	echo "10.0.$o3.$o4 $node" >> $OURDIR/data-hosts

        # Skip 2 for openvpn tun tunnels
	o4=`expr $o4 + 1`
	if [ $o4 -gt 254 ] ; then
	    o4=10
	    o3=`expr $o3 + 1`
	fi
    done
else
    cat $TOPOMAP | grep -v '^#' | sed -e 's/,/ /' \
	| sed -n -e "s/\([a-zA-Z0-9_\-]*\) .*${DATALAN}:\([0-9\.]*\).*\$/\2\t\1/p" \
	> $OURDIR/data-hosts
    cat /var/emulab/boot/tmcc/ifconfig \
	| sed -n -e "s/.* MASK=\([0-9\.]*\) .* LAN=${DATALAN}/\1/p" \
	> $OURDIR/data-netmask
fi

#
# Get our hosts files setup to point to the new management network.
#
cat $OURDIR/mgmt-hosts > /etc/hosts
for node in $NODES 
do
    [ "$node" = "$NETWORKMANAGER" ] && continue

    fqdn="$node.$EEID.$EPID.$OURDOMAIN"
    $SSH $fqdn mkdir -p $OURDIR
    scp -p -o StrictHostKeyChecking=no \
	$SETTINGS $OURDIR/mgmt-hosts $OURDIR/mgmt-netmask \
	$OURDIR/data-hosts $OURDIR/data-netmask \
	$fqdn:$OURDIR
    $SSH $fqdn cp $OURDIR/mgmt-hosts /etc/hosts
done

echo "*** Setting up the Management Network"

if [ -z "${MGMTLAN}" ]; then
    echo "*** Building a VPN-based Management Network"

    $DIRNAME/setup-vpn.sh 1> $OURDIR/setup-vpn.log 2>&1

    # Give the VPN a chance to settle down
    PINGED=0
    while [ $PINGED -eq 0 ]; do
	sleep 2
	ping -c 1 $CONTROLLER
	if [ $? -eq 0 ]; then
	    PINGED=1
	fi
    done
else
    echo "*** Using $MGMTLAN as the Management Network"
fi

echo "*** Moving Interfaces into OpenVSwitch Bridges"

$DIRNAME/setup-ovs.sh 1> $OURDIR/setup-ovs.log 2>&1

echo "*** Building an Openstack!"

ssh -o StrictHostKeyChecking=no ${CONTROLLER} "sh -c $DIRNAME/setup-controller.sh 1> $OURDIR/setup-controller.log 2>&1 </dev/null &"

exit 0
