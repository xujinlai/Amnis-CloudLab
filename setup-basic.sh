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

#
# Setup tunnel-based networks
#
if [ ${DATATUNNELS} -gt 0 ]; then
    i=0
    while [ $i -lt ${DATATUNNELS} ]; do
	LAN="tun${i}"
	#. $OURDIR/info.$LAN
	. $OURDIR/ipinfo.$LAN

	echo "*** Creating GRE data network $LAN and subnet $CIDR ..."

	neutron net-create ${LAN}-net --provider:network_type gre
	neutron subnet-create ${LAN}-net  --name ${LAN}-subnet "$CIDR"
	neutron router-create ${LAN}-router
	neutron router-interface-add ${LAN}-router ${LAN}-subnet
	neutron router-gateway-set ${LAN}-router ext-net

	i=`expr $i + 1`
    done
fi

for lan in ${DATAFLATLANS} ; do
    . $OURDIR/info.${lan}

    name="$lan"
    echo "*** Creating Flat data network ${lan} and subnet ..."

    nmdataip=`cat $OURDIR/data-hosts.${lan} | grep ${NETWORKMANAGER} | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
    allocation_pool=`cat $OURDIR/data-allocation-pool.${lan}`
    cidr=`cat $OURDIR/data-cidr.${lan}`
    # Make sure to set the right gateway IP (to our router)
    routeripaddr=`cat $OURDIR/router-ipaddr.$lan`

    neutron net-create ${name}-net --shared --provider:physical_network ${lan} --provider:network_type flat
    neutron subnet-create ${name}-net --name ${name}-subnet --allocation-pool ${allocation_pool} --gateway $routeripaddr $cidr

    subnetid=`neutron subnet-show ${name}-subnet | awk '/ id / {print $4}'`

    neutron router-create ${name}-router
    neutron router-interface-add ${name}-router ${name}-subnet
    #if [ $PUBLICCOUNT -ge 3 ] ; then
	neutron router-gateway-set ${name}-router ext-net
    #fi

    # Fix up the dhcp agent port IP addr.  We can't set this in the
    # creation command, so do a port update!
    ports=`neutron port-list | grep $subnetid | awk '{print $2}'`
    for port in $ports ; do
	owner=`neutron port-show $port | awk '/ device_owner / {print $4}'`
	#if [ "x$owner" = "xnetwork:router_interface" -a -f $OURDIR/router-ipaddr.$lan ]; then
	#    newipaddr=`cat $OURDIR/router-ipaddr.$lan`
	#    neutron port-update $port --fixed-ip subnet_id=$subnetid,ip_address=$newipaddr
	#fi
	if [ "x$owner" = "xnetwork:dhcp" -a -f $OURDIR/dhcp-agent-ipaddr.$lan ]; then
	    newipaddr=`cat $OURDIR/dhcp-agent-ipaddr.$lan`
	    neutron port-update $port --fixed-ip subnet_id=$subnetid,ip_address=$newipaddr
	fi
    done
done

for lan in ${DATAVLANS} ; do
    . $OURDIR/info.${lan}
    . $OURDIR/ipinfo.${lan}

    echo "*** Creating VLAN data network $lan and subnet $CIDR ..."

    neutron net-create ${lan}-net --shared --provider:physical_network ${DATAVLANDEV} --provider:network_type vlan
    # NB: for now don't specify an allocation_pool:
    #  --allocation-pool ${ALLOCATION_POOL}
    neutron subnet-create ${lan}-net --name ${lan}-subnet "$CIDR"

    neutron router-create ${lan}-router
    neutron router-interface-add ${lan}-router ${lan}-subnet
    #if [ $PUBLICCOUNT -ge 3 ] ; then
	neutron router-gateway-set ${lan}-router ext-net
    #fi
done

#
# Setup VXLAN-based networks
#
if [ ${DATAVXLANS} -gt 0 ]; then
    i=0
    while [ $i -lt ${DATAVXLANS} ]; do
	LAN="vxlan${i}"
	#. $OURDIR/info.$LAN
	. $OURDIR/ipinfo.$LAN

	echo "*** Creating VXLAN data network $LAN and subnet $CIDR ..."

	neutron net-create ${LAN}-net --provider:network_type vxlan
	neutron subnet-create ${LAN}-net  --name ${LAN}-subnet "$CIDR"
	neutron router-create ${LAN}-router
	neutron router-interface-add ${LAN}-router ${LAN}-subnet
	neutron router-gateway-set ${LAN}-router ext-net

	i=`expr $i + 1`
    done
fi

if [ ${DEFAULT_SECGROUP_ENABLE_SSH_ICMP} -eq 1 ]; then
    nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0
    nova secgroup-add-rule default tcp 22 22 0.0.0.0/0
fi

if [ "$SWAPPER" = "geniuser" ] ; then
    echo "*** Importing GENI user keys for admin user..."
    $DIRNAME/setup-user-info.py

    #
    # XXX: ugh, this is ugly, but now that we have two admin users, we have
    # to create keys for the admin user -- but we upload keys as the adminapi
    # user.  I can't find a way with the API to upload keys for another user
    # (seems very dumb, I must be missing something, but...)... so what we do
    # is add the keys once for the adminapi user, change the db manually to
    # make those keys be for the admin user, then add the same keys again (for
    # the adminapi user).  Then both admin users have the keys.
    #
    AAID=`keystone user-get ${ADMIN_API} | awk '/ id / {print $4}'`
    AID=`keystone user-get admin | awk '/ id / {print $4}'`
    echo "update key_pairs set user_id='$AID' where user_id='$AAID'" \
	| mysql -u root --password=${DB_ROOT_PASS} nova

    # Ok, do it again!
    echo "*** Importing GENI user keys, for ${ADMIN_API} user..."
    $DIRNAME/setup-user-info.py
fi

exit 0
