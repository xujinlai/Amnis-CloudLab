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

# All nodes need to publish public keys, and acquire others'
$DIRNAME/setup-root-ssh.sh 1> $OURDIR/setup-root-ssh.log 2>&1

HOSTNAME=`hostname -s`
if [ "$HOSTNAME" != "$NETWORKMANAGER" ]; then
    exit 0;
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

echo "*** Waiting for all nodes..."

for node in $CONTROLLER $COMPUTENODES ; do
    SUCCESS=1
    fqdn=$node.$EEID.$EPID.$OURDOMAIN
    while [ $SUCCESS -ne 0 ] ; do
	sleep 1
	#su -c "ssh -l $SWAPPER -o ConnectTimeout=1 -o PasswordAuthentication=No -o NumberOfPasswordPrompts=0 -o StrictHostKeyChecking=No $fqdn /bin/ls" $SWAPPER > /dev/null
	ssh -o ConnectTimeout=1 -o PasswordAuthentication=No -o NumberOfPasswordPrompts=0 -o StrictHostKeyChecking=No $fqdn /bin/ls > /dev/null
	SUCCESS=$?
    done
    echo "*** $node is up!"
done

echo "*** Building an Openstack!"

#$DIRNAME/setup-root-ssh.sh 1> $OURDIR/setup-root-ssh.log 2>&1
$DIRNAME/setup-ovs.sh 1> $OURDIR/setup-ovs.log 2>&1
$DIRNAME/setup-vpn.sh 1> $OURDIR/setup-vpn.log 2>&1

# Give the VPN a chance to settle down
PINGED=0
while [ $PINGED -eq 0 ]; do
    sleep 2
    ping -c 1 controller
    if [ $? -eq 0 ]; then
	PINGED=1
    fi
done

ssh -o StrictHostKeyChecking=no controller "sh -c $DIRNAME/setup-controller.sh 1> $OURDIR/setup-controller.log 2>&1 </dev/null &"

exit 0
