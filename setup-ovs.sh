#!/bin/sh

#
# For a neutron setup, we have to move the external interface into
# br-ex, and copy its config to br-ex; move the data lan (ethX) into br-int,
# and copy its config to br-int .  For now, we assume the default route of
# the machine is associated with eth0/br-ex .
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

if [ "$HOSTNAME" != "$NETWORKMANAGER" ]; then
    exit 0;
fi

# Do the network manager node first, no ssh
echo "*** Setting up OpenVSwitch on $HOSTNAME"
$DIRNAME/setup-ovs-node.sh

for node in $NODES
do
    [ "$node" = "$NETWORKMANAGER" ] && continue

    echo "*** Setting up OpenVSwitch on $node"
    fqdn="$node.$EEID.$EPID.$OURDOMAIN"
    $SSH $fqdn $DIRNAME/setup-ovs-node.sh
done

exit 0
