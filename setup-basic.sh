#!/bin/sh

##
## Initialize some basic useful stuff.
##

set -x

DIRNAME=`dirname $0`

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "$DIRNAME/setup-lib.sh"

if [ "$HOSTNAME" != "$CONTROLLER" ]; then
    exit 0;
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

. $OURDIR/admin-openrc.sh

echo "*** Adding Images ..."

ARCH=`uname -m`
if [ "$ARCH" = "aarch64" ] ; then
    $DIRNAME/setup-basic-aarch64.sh
else
    $DIRNAME/setup-basic-x86_64.sh
fi

echo "*** Creating GRE data network and subnet ..."

neutron net-create tun-data-net
# Use the very last /16 of the 172.16/12 so that we don't overlap with Emulab
# private vnode control net.
neutron subnet-create tun-data-net  --name tun-data-subnet 172.31/16
neutron router-create tun-data-router
neutron router-interface-add tun-data-router tun-data-subnet
neutron router-gateway-set tun-data-router ext-net

if [ ${SETUP_FLAT_DATA_NETWORK} -eq 1 ]; then

    echo "*** Creating Flat data network and subnet ..."

    nmdataip=`cat $OURDIR/data-hosts | grep ${NETWORKMANAGER} | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`

    neutron net-create flat-data-net --shared --provider:physical_network data --provider:network_type flat
    neutron subnet-create flat-data-net --name flat-data-subnet --allocation-pool start=10.254.1.1,end=10.254.254.254 --gateway $nmdataip 10.0.0.0/8

    neutron router-create flat-data-router
    neutron router-interface-add flat-data-router flat-data-subnet
    if [ $PUBLICCOUNT -ge 3 ] ; then
	neutron router-gateway-set flat-data-router ext-net
    fi
fi

if [ "$SWAPPER" = "geniuser" ] ; then
    echo "*** Importing GENI user keys..."
    $DIRNAME/setup-user-info.py
fi

exit 0
