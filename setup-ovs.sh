#!/bin/sh

#
# For a neutron setup on the moonshot nodes, we have to move eth0 into
# br-ex, and copy its config to br-ex; and move eth1 into br-int, and
# copy its config to br-int .  For now, assume that the default route
# of the machine is associated with eth0/br-ex
#
# Moreover, assume that networkmanager:eth1 gets 10.0.0.1/8, and
# controller gets 10.0.0.3/8 (in sync with the management VPN); and
# the compute nodes get 10.0.x.y, where x starts at 1, and y starts
# at 1 and does not exceed 254.
#


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
if [ "$HOSTNAME" != "$NETWORKMANAGER" ]; then
    exit 0;
fi

apt-get install -y openvswitch-switch openvswitch-common

if [ ${USE_EXISTING_DATA_IPS} -eq 0 ]; then
    echo "10.0.0.1 $NETWORKMANAGER" > $OURDIR/data-hosts
    echo "10.0.0.3 $CONTROLLER" >> $OURDIR/data-hosts

    #
    # Now set static IPs for the compute nodes.
    #
    o3=1
    o4=1
    for node in $COMPUTENODES
    do
	echo "10.0.$o3.$o4 $node" >> $OURDIR/data-hosts

        # Skip 2 for openvpn tun tunnels
	o4=`expr $o4 + 1`
	if [ $o4 -gt 254 ] ; then
	    o4=10
	    o3=`expr $o3 + 1`
	fi
    done
else
    /usr/local/etc/emulab/tmcc topomap | gunzip | grep -v '^#' | sed -n -e 's/^\([a-zA-Z0-9\-]*\),.*:\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\2\t\1/p' \
	> $OURDIR/data-hosts
fi

# Do the network manager node first, no ssh
$DIRNAME/setup-ovs-node.sh

for node in $CONTROLLER $COMPUTENODES
do
    fqdn="$node.$EEID.$EPID.$OURDOMAIN"
    $SSH $fqdn mkdir -p $OURDIR
    scp -o StrictHostKeyChecking=no $OURDIR/data-hosts $fqdn:$OURDIR
    $SSH $fqdn $DIRNAME/setup-ovs-node.sh
done

exit 0
