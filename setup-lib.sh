#!/bin/sh

DIRNAME=`dirname $0`

PSWDGEN="openssl rand -hex 10"

#
# Our default configuration
#
CONTROLLER="ctl"
NETWORKMANAGER="nm"
STORAGEHOST="ctl"
OBJECTHOST="ctl"
COMPUTENODES=""
BAREMETALNODES=""
BLOCKNODES=""
OBJECTNODES=""
DATALAN="lan-1"
MGMTLAN="lan-2"
BLOCKLAN=""
OBJECTLAN=""
DATATUNNELS=1
DATAFLATLANS="lan-1"
DATAVLANS=""
DATAVXLANS=0
USE_EXISTING_IPS=1
DO_APT_INSTALL=1
DO_APT_UPDATE=1
ENABLE_NEW_SERIAL_SUPPORT=0
DO_UBUNTU_CLOUDARCHIVE=1
BUILD_AARCH64_FROM_CORE=0
DISABLE_SECURITY_GROUPS=0
DEFAULT_SECGROUP_ENABLE_SSH_ICMP=1
#
# We have an 'adminapi' user that gets a random password.  Then, we have
# the dashboard and instance password, that comes in from geni-lib/rspec as a
# hash, that defaults to the same as the old default profile.
#
# /root/setup/admin-openrc.sh contains the adminapi user, not admin!  We do it
# this way because we need a real passwd so that various CLI tools and openstack
# components have a real user/pass to auth as.
#
ADMIN_API='adminapi'
ADMIN_API_PASS=`$PSWDGEN`
ADMIN='admin'
ADMIN_PASS_HASH='$6$kOIVUcvsnrD/hETx$JahyKoIJf1EFNI2AWCtfzn3ZBoBfaJrRQkjC0kW6VkTwPI9K3TtEWTh/axrHP.e5mmcM96/bTQs1.e7HSKIk10'

OURDIR=/root/setup
SETTINGS=$OURDIR/settings
LOCALSETTINGS=$OURDIR/settings.local
TOPOMAP=$OURDIR/topomap

mkdir -p $OURDIR
cd $OURDIR
touch $SETTINGS
touch $LOCALSETTINGS

BOOTDIR=/var/emulab/boot
SWAPPER=`cat $BOOTDIR/swapper`

#
# Suck in user configuration overrides, if we haven't already
#
if [ ! -e $OURDIR/parameters ]; then
    touch $OURDIR/parameters
    if [ "$SWAPPER" = "geniuser" ]; then
	geni-get manifest | sed -n -e 's/^[^<]*<[^:]*:parameter>\([^<]*\)<\/[^:]*:parameter>/\1/p' > $OURDIR/parameters
    fi
fi
. $OURDIR/parameters

BOOTDIR=/var/emulab/boot
TMCC=/usr/local/etc/emulab/tmcc

CREATOR=`cat $BOOTDIR/creator`
SWAPPER=`cat $BOOTDIR/swapper`
NODEID=`cat $BOOTDIR/nickname | cut -d . -f 1`
PNODEID=`cat $BOOTDIR/nodeid`
EEID=`cat $BOOTDIR/nickname | cut -d . -f 2`
EPID=`cat $BOOTDIR/nickname | cut -d . -f 3`
OURDOMAIN=`cat $BOOTDIR/mydomain`
NFQDN="`cat $BOOTDIR/nickname`.$OURDOMAIN"
PFQDN="`cat $BOOTDIR/nodeid`.$OURDOMAIN"
MYIP=`cat $BOOTDIR/myip`
EXTERNAL_NETWORK_INTERFACE=`cat $BOOTDIR/controlif`
HOSTNAME=`cat ${BOOTDIR}/nickname | cut -f1 -d.`
ARCH=`uname -m`

# Check if our init is systemd
dpkg-query -S /sbin/init | grep -q systemd
HAVE_SYSTEMD=`expr $? = 0`

. /etc/lsb-release
if [ ${DISTRIB_CODENAME} = "vivid" ]; then
    OSCODENAME="kilo"
else
    OSCODENAME="juno"
fi

SSH="ssh -o StrictHostKeyChecking=no"

if [ "$SWAPPER" = "geniuser" ]; then
    SWAPPER_EMAIL=`geni-get slice_email`
else
    SWAPPER_EMAIL="$SWAPPER@$OURDOMAIN"
fi

if [ "$SWAPPER" = "geniuser" ]; then
    PUBLICADDRS=`geni-get manifest | perl -e 'while (<STDIN>) { while ($_ =~ m/\<emulab:ipv4 address="([\d.]+)\" netmask=\"([\d\.]+)\"/g) { print "$1\n"; } }' | xargs`
    PUBLICCOUNT=0
    for ip in $PUBLICADDRS ; do
	PUBLICCOUNT=`expr $PUBLICCOUNT + 1`
    done
else
    PUBLICADDRS=""
    PUBLICCOUNT=0
fi

##
## Grab our geni creds, and create a GENI credential cert
##
#
# NB: force the install of python-m2crypto if geniuser
#
if [ "$SWAPPER" = "geniuser" ]; then
    dpkg-query -l python-m2crypto | grep -q ii
    if [ ! $? = 0 ]; then
	apt-get install python-m2crypto
    fi
fi
if [ ! -e $OURDIR/geni.key ]; then
    geni-get key > $OURDIR/geni.key
fi
if [ ! -e $OURDIR/geni.certificate ]; then
    geni-get certificate > $OURDIR/geni.certificate
fi

if [ ! -e /root/.ssl/encrypted.pem ]; then
    mkdir -p /root/.ssl
    chmod 600 /root/.ssl

    cat $OURDIR/geni.key > /root/.ssl/encrypted.pem
    cat $OURDIR/geni.certificate >> /root/.ssl/encrypted.pem
fi

#
# Grab our topomap so we can see how many nodes we have.
# NB: only safe to use topomap for non-fqdn things.
#
if [ ! -f $TOPOMAP ]; then
    $TMCC topomap | gunzip > $TOPOMAP
fi

#
# Since some of our testbeds only have one experiment interface per node,
# just do this little hack job -- if MGMTLAN was specified, but it's not in
# the topomap, we null it out and use the VPN Management setup instead.
#
if [ ! -z "$MGMTLAN" ] ; then
    cat $TOPOMAP | grep "$MGMTLAN"
    if [ $? -ne 0 ] ; then
	echo "*** Cannot find Management LAN $MGMTLAN ; falling back to VPN!"
	MGMTLAN=""
    fi
fi

#
# Create a map of node nickname to FQDN.  This supports geni multi-site
# experiments.
#
if [ \( -s /root/.ssl/encrypted.pem \) -a \( ! \( -e $OURDIR/manifests.xml \) \) ]; then
    python $DIRNAME/getmanifests.py > $OURDIR/manifests.xml
    cat manifests.xml | sed -e 's/<node /\n<node /g'  | sed -n -e "s/^<node [^>]*client_id=['\"]*\([^'\"]*\)['\"].*<host name=['\"]\([^'\"]*\)['\"].*$/\1\t\2/p" > $OURDIR/fqdn.map
fi

#
# Setup the fqdn map the non-geni way if necessary!
#
if [ ! -s $OURDIR/fqdn.map ]; then
    NODES=`cat $TOPOMAP | grep -v '^#' | sed -n -e 's/^\([a-zA-Z0-9\-]*\),.*:.*$/\1/p' | xargs`
    FQDNS=""
    for n in $NODES ; do 
	fqdn="$n.$EEID.$EPID.$OURDOMAIN"
	FQDNS="${FQDNS} $fqdn"

	/bin/echo -e "$n\t$fqdn" >> $OURDIR/fqdn.map
    done
fi

#
# Grab our list of short-name and FQDN nodes.  One way or the other, we have
# an fqdn map.  First we tried the GENI way; then the old Emulab way with
# topomap.
#
NODES=`cat $OURDIR/fqdn.map | cut -f1 | xargs`
FQDNS=`cat $OURDIR/fqdn.map | cut -f2 | xargs`

if [ -z "${COMPUTENODES}" ]; then
    # Figure out which networkmanager (netmgr) and controller (ctrl) names we have
    for node in $NODES
    do
	if [ "$node" = "networkmanager" ]; then
	    NETWORKMANAGER="networkmanager"
	fi
	if [ "$node" = "controller" ]; then
	    # If we were using the controller as storage and object host, then
	    # keep using it (just use the old name we've detected).
	    if [ "$STORAGEHOST" = "$CONTROLLER" ]; then
		STORAGEHOST="controller"
	    fi
	    if [ "$OBJECTHOST" = "$CONTROLLER" ]; then
		OBJECTHOST="controller"
	    fi
	    CONTROLLER="controller"
	fi
    done
    # Figure out which ones are the compute nodes
    for node in $NODES
    do
	if [ "$node" != "$CONTROLLER" -a "$node" != "$NETWORKMANAGER" \
	     -a "$node" != "$STORAGEHOST" -a "$node" != "$OBJECTHOST" ]; then
	    COMPUTENODES="$COMPUTENODES $node"
	fi
    done
fi

OTHERNODES=""
for node in $NODES
do
    [ "$node" = "$NODEID" ] && continue

    OTHERNODES="$OTHERNODES $node"
done

# Save the node stuff off to settings
grep CONTROLLER $SETTINGS
if [ ! $? = 0 ]; then
    echo "CONTROLLER=\"${CONTROLLER}\"" >> $SETTINGS
    echo "NETWORKMANAGER=\"${NETWORKMANAGER}\"" >> $SETTINGS
    echo "STORAGEHOST=\"${STORAGEHOST}\"" >> $SETTINGS
    echo "OBJECTHOST=\"${OBJECTHOST}\"" >> $SETTINGS
    echo "COMPUTENODES=\"${COMPUTENODES}\"" >> $SETTINGS
fi

# Setup apt-get to not prompt us
export DEBIAN_FRONTEND=noninteractive
#  -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
APTGETINSTALLOPTS='-y'
APTGETINSTALL="apt-get install $APTGETINSTALLOPTS"
# Don't install/update packages if this is not set
if [ ! ${DO_APT_INSTALL} -eq 1 ]; then
    APTGETINSTALL="/bin/true ${APTGETINSTALL}"
fi

if [ ! -f $OURDIR/apt-updated -a "${DO_APT_UPDATE}" = "1" ]; then
    apt-get update
    touch $OURDIR/apt-updated
fi

if [ ! -f /etc/apt/sources.list.d/cloudarchive-${OSCODENAME}.list \
    -a ! -f $OURDIR/cloudarchive-added \
    -a "${DO_UBUNTU_CLOUDARCHIVE}" = "1" ]; then
    if [ "${DISTRIB_CODENAME}" = "trusty" ] ; then
	$APTGETINSTALL install -y ubuntu-cloud-keyring
	echo "deb http://ubuntu-cloud.archive.canonical.com/ubuntu" "${DISTRIB_CODENAME}-updates/${OSCODENAME} main" > /etc/apt/sources.list.d/cloudarchive-${OSCODENAME}.list
	apt-get update
    fi

    touch $OURDIR/cloudarchive-added
fi

#
# We rely on crudini in a few spots, instead of sed whacking.
#
$APTGETINSTALL crudini

#
# Create IP addresses for the Management and Data networks, as necessary.
#
if [ ! -f $OURDIR/nextsparesubnet ] ; then
    #
    # This is horrible, but for openstack networks that need IP addrs, that
    # were not specified in our experiment description (i.e., by Emulab,
    # Cloudlab, or the geni-lib based rspec file), we have to generate them.
    # We stay away from 172.16 because Emulab/Cloudlab use it internally for
    # virtual machine IP addresses.  We also know that Emulab/Cloudlab/geni-lib
    # always allocate addresses starting at 10.1.1.1, and increment the second
    # octet for a new subnet.  We assume that 1) no subnet will ever be larger
    # than 255*255 hosts, and 2) that we can start our subnets at 10.254.0.0
    # and decrement the second octet any time we need to IP a new openstack
    # network.
    #
    NEXTSPARESUBNET=254
    echo ${NEXTSPARESUBNET} > $OURDIR/nextsparesubnet
else
    NEXTSPARESUBNET=`cat $OURDIR/nextsparesubnet`
fi

if [ ! -f $OURDIR/mgmt-hosts ] ; then
    echo "*** Setting up Management and Data Network IP Addresses"

    if [ -z "${MGMTLAN}" -o ${USE_EXISTING_IPS} -eq 0 ]; then
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
	cat ${BOOTDIR}/tmcc/ifconfig \
	    | sed -n -e "s/^.* MASK=\([0-9\.]*\) .* LAN=${MGMTLAN}.*$/\1/p" \
	    > $OURDIR/mgmt-netmask
    fi

    #
    # If USE_EXISTING_IPS is set to 0, we will re-IP those data lan
    # interfaces: networkmanager:eth1 gets 10.z.0.1/8, and controller gets
    # 10.z.0.3/8; and the compute nodes get 10.z.x.y, where x starts at 1,
    # and y starts at 1 and does not exceed 254.
    #
    # We only assign IPs to flat networks because they are the only networks
    # that the physical hosts (i.e., controller, networkmanager, compute nodes)
    # have an interface on.  Technically, we don't *need* to do this, but do it.
    # One thing it gives us is the ability to run GRE or VXLAN networks over the
    # flat networks.
    #
    if [ ${USE_EXISTING_IPS} -eq 0 ]; then
	for lan in $DATAFLATLANS $DATAVLANS; do
	    echo "255.255.0.0" > $OURDIR/data-netmask.$lan
	    echo "10.$NEXTSPARESUBNET.0.0/255.255.0.0" > $OURDIR/data-cidr.$lan
	    echo "10.$NEXTSPARESUBNET.0.0" > $OURDIR/data-network.$lan
	    echo "10.$NEXTSPARESUBNET.0.1 $NETWORKMANAGER" > $OURDIR/data-hosts.$lan
	    echo "10.$NEXTSPARESUBNET.0.3 $CONTROLLER" >> $OURDIR/data-hosts.$lan

            #
            # Now set static IPs for the compute nodes.
            #
	    o3=1
	    o4=1
	    for node in $NODES
	    do
		[ "$node" = "$CONTROLLER" -o "$node" = "$NETWORKMANAGER" ] \
		    && continue

		echo "10.$NEXTSPARESUBNET.$o3.$o4 $node" >> $OURDIR/data-hosts

                # Skip 2 for openvpn tun tunnels
		o4=`expr $o4 + 1`
		if [ $o4 -gt 254 ] ; then
		    o4=10
		    o3=`expr $o3 + 1`
		fi
	    done

	    # Start the pool at the next availble addr!  Don't skip.
	    # XXX: could cause problems for adding new phys hosts... oh well.
	    o3=`expr $o3 + 10`
	    # Also save two addrs, one for the dhcp agent, and one for the
	    # router interface
	    echo "start=10.$NEXTSPARESUBNET.$o3.3,end=10.$NEXTSPARESUBNET.254.254" \
		> $OURDIR/data-allocation-pool.$lan

	    echo "10.$NEXTSPARESUBNET.$o3.1" > $OURDIR/router-ipaddr.$lan
	    echo "10.$NEXTSPARESUBNET.$o3.2" > $OURDIR/dhcp-agent-ipaddr.$lan

	    NEXTSPARESUBNET=`expr $NEXTSPARESUBNET + 1`
	done
    else
	for lan in $DATAFLATLANS ; do
	    cat $TOPOMAP | grep -v '^#' | sed -e 's/,/ /' \
		| sed -n -e "s/\([a-zA-Z0-9_\-]*\) .*${lan}:\([0-9\.]*\).*\$/\2\t\1/p" \
		> $OURDIR/data-hosts.$lan
	    netmask=`cat ${BOOTDIR}/tmcc/ifconfig \
  		         | sed -n -e "s/^.* MASK=\([0-9\.]*\) .* LAN=${lan}.*$/\1/p"`
	    echo "$netmask" > $OURDIR/data-netmask.$lan
	    nmdataip=`cat $OURDIR/data-hosts.${lan} | grep ${NETWORKMANAGER} | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
	    IFS=.
	    read -r i1 i2 i3 i4 <<EOF
$nmdataip
EOF
	    read -r m1 m2 m3 m4 <<EOF
$netmask
EOF
	    unset IFS
	    network=`printf "%d.%d.%d.%d\n" "$((i1 & m1))" "$((i2 & m2))" "$((i3 & m3))" "$((i4 & m4))"`
	    echo "$network/$netmask" > $OURDIR/data-cidr.$lan
	    echo "$network" > $OURDIR/data-network.$lan

	    #
	    # Setup our allocation pool
	    #
	    # First grab all our IP addresses
	    allips=`cat /root/setup/data-hosts.$lan | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
	    gi1=0; gi2=0; gi3=0; gi4=0;
	    # Figure out the max currently-used IP in this subnet
	    for ip in ${allips} ; do
		IFS=.
		read -r i1 i2 i3 i4 <<EOF
$ip
EOF
		unset IFS
		if [ $i1 -gt $gi1 ]; then gi1=$i1; gi2=0;gi3=0;gi4=0; fi
		if [ $i2 -gt $gi2 ]; then gi2=$i2; gi3=0;gi4=0; fi
		if [ $i3 -gt $gi3 ]; then gi3=$i3; gi4=0; fi
		if [ $i4 -gt $gi4 ]; then gi4=$i4; fi
	    done
	    # Get the next available one...
	    # Note, we don't try to stay inside the netmask :(
	    gi4=`expr $gi4 + 1`
	    if [ $gi4 = 255 ]; then gi4=1; gi3=`expr $gi3 + 1`; fi
	    if [ $gi3 = 255 ]; then gi3=1; gi2=`expr $gi2 + 1`; fi
	    if [ $gi2 = 255 ]; then gi2=1; gi1=`expr $gi1 + 1`; fi

	    endaddr=`printf "%d.%d.%d.%d\n" "$((i1 | ((~m1)+256)))" "$((i2 | ((~m2)+256)))" "$((i3 | ((~m3)+256)))" "$((i4 | ((~m4)+256)))"`

	    #
            # So, this previous calculation is correct, but openstack doesn't
	    # like 255 in any of the octets!  Argh!  So, "fix" any that have it.
            # Argh...
            #
	    IFS=.
	    read -r i1 i2 i3 i4 <<EOF
$endaddr
EOF
	    unset IFS
	    if [ $i1 = 255 ]; then i1=254; fi
	    if [ $i2 = 255 ]; then i2=254; fi
	    if [ $i3 = 255 ]; then i3=254; fi
	    if [ $i4 = 255 ]; then i4=254; fi
	    endaddr="$i1.$i2.$i3.$i4"

	    # Also save two addrs, one for the dhcp agent, and one for the
	    # router interface
	    echo "$gi1.$gi2.$gi3.$gi4" > $OURDIR/router-ipaddr.$lan
	    gi4=`expr $gi4 + 1`
	    echo "$gi1.$gi2.$gi3.$gi4" > $OURDIR/dhcp-agent-ipaddr.$lan
	    gi4=`expr $gi4 + 1`
	    # Start the pool at the next availble addr!  Don't skip.
	    # XXX: could cause problems for adding new phys hosts... oh well.
	    echo "start=$gi1.$gi2.$gi3.$gi4,end=$endaddr" \
		> $OURDIR/data-allocation-pool.$lan
	done
    fi

    # Save off nextsparesubnet
    echo "${NEXTSPARESUBNET}" > $OURDIR/nextsparesubnet
fi

#
# Setup IP configuration for neutron tunnel nets
#
if [ ${DATATUNNELS} -gt 0 ]; then
    i=0
    while [ $i -lt ${DATATUNNELS} ]; do
	LAN="tun${i}"
	subnet=${NEXTSPARESUBNET}

	if [ -f $OURDIR/ipinfo.$LAN ]; then
	    i=`expr $i + 1`
	    continue
	fi

	echo "LAN='$LAN'" >> $OURDIR/ipinfo.$LAN
	echo "ALLOCATION_POOL='start=10.${subnet}.1.1,end=10.${subnet}.254.254'" >> $OURDIR/ipinfo.$LAN
	echo "CIDR='10.$subnet.0.0/255.255.0.0'" >> $OURDIR/ipinfo.$LAN

	NEXTSPARESUBNET=`expr ${NEXTSPARESUBNET} - 1`
	i=`expr $i + 1`
    done

    # Save off nextsparesubnet
    echo "${NEXTSPARESUBNET}" > $OURDIR/nextsparesubnet
fi

#
# Setup IP configuration for vlan networks
#
for lan in $DATAVLANS ; do
    LAN="$lan"
    subnet=${NEXTSPARESUBNET}

    if [ -f $OURDIR/ipinfo.$LAN ]; then
	continue
    fi

    echo "LAN='$LAN'" >> $OURDIR/ipinfo.$LAN
    echo "ALLOCATION_POOL='start=10.${subnet}.1.1,end=10.${subnet}.254.254'" >> $OURDIR/ipinfo.$LAN
    echo "CIDR='10.$subnet.0.0/255.255.0.0'" >> $OURDIR/ipinfo.$LAN

    NEXTSPARESUBNET=`expr ${NEXTSPARESUBNET} - 1`
done
# Save off nextsparesubnet
echo "${NEXTSPARESUBNET}" > $OURDIR/nextsparesubnet

#
# Setup IP configuration for neutron vxlan nets
#
if [ ${DATAVXLANS} -gt 0 ]; then
    i=0
    while [ $i -lt ${DATAVXLANS} ]; do
	LAN="vxlan${i}"
	subnet=${NEXTSPARESUBNET}

	if [ -f $OURDIR/ipinfo.$LAN ]; then
	    i=`expr $i + 1`
	    continue
	fi

	echo "LAN='$LAN'" >> $OURDIR/ipinfo.$LAN
	echo "ALLOCATION_POOL='start=10.${subnet}.1.1,end=10.${subnet}.254.254'" >> $OURDIR/ipinfo.$LAN
	echo "CIDR='10.$subnet.0.0/255.255.0.0'" >> $OURDIR/ipinfo.$LAN

	NEXTSPARESUBNET=`expr ${NEXTSPARESUBNET} - 1`
	i=`expr $i + 1`
    done

    # Save off nextsparesubnet
    echo "${NEXTSPARESUBNET}" > $OURDIR/nextsparesubnet
fi

#
# NB: this IP/mask is only valid after setting up the management network IP
# addresses because they might not be the Emulab ones.
#
MGMTIP=`cat /etc/hosts | grep -E "$NODEID$" | head -1 | sed -n -e 's/^\\([0-9]*\\.[0-9]*\\.[0-9]*\\.[0-9]*\\).*$/\\1/p'`
MGMTNETMASK=`cat $OURDIR/mgmt-netmask`
if [ -z "$MGMTLAN" ] ; then
    MGMTMAC=""
    MGMT_NETWORK_INTERFACE="tun0"
else
    cat ${BOOTDIR}/tmcc/ifconfig | grep "IFACETYPE=vlan" | grep "${MGMTLAN}"
    if [ $? = 0 ]; then
	MGMTVLAN=1
	MGMTMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* VMAC=\([0-9a-f:\.]*\) .* LAN=${MGMTLAN}.*\$/\1/p"`
	MGMT_NETWORK_INTERFACE=`/usr/local/etc/emulab/findif -m $MGMTMAC`
	MGMTVLANDEV=`ip link show ${MGMT_NETWORK_INTERFACE} | sed -n -e "s/^.*${MGMT_NETWORK_INTERFACE}\@\([0-9a-zA-Z_]*\): .*\$/\1/p"`
    else
	MGMTVLAN=0
	MGMTMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/.* MAC=\([0-9a-f:\.]*\) .* LAN=${MGMTLAN}/\1/p"`
	MGMT_NETWORK_INTERFACE=`/usr/local/etc/emulab/findif -m $MGMTMAC`
    fi
fi

#
# NB: this IP/mask is only valid after data ips have been assigned, because
# they might not be the Emulab ones.
#
for lan in $DATAFLATLANS ; do
    if [ -e $OURDIR/info.$lan ] ; then
	continue
    fi

    DATAIP=`cat $OURDIR/data-hosts.$lan | grep -E "$NODEID$" | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
    DATANETMASK=`cat $OURDIR/data-netmask.$lan`
    cat ${BOOTDIR}/tmcc/ifconfig | grep "IFACETYPE=vlan" | grep "${lan}"
    if [ $? = 0 ]; then
	DATAVLAN=1
	DATAMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* VMAC=\([0-9a-f:\.]*\) .* LAN=${lan}.*\$/\1/p"`
	DATADEV=`/usr/local/etc/emulab/findif -m $DATAMAC`
	DATAVLANDEV=`ip link show ${DATADEV} | sed -n -e "s/^.*${DATADEV}\@\([0-9a-zA-Z_]*\): .*\$/\1/p"`
	DATAVLANTAG=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* LAN=${lan} VTAG=\([0-9]*\).*\$/\1/p"`
    else
	DATAVLAN=0
	DATAVLANDEV=""
	DATAVLANTAG=0
	DATAMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* MAC=\([0-9a-f:\.]*\) .* LAN=${lan}.*$/\1/p"`
	DATADEV=`/usr/local/etc/emulab/findif -m $DATAMAC`
    fi

    echo "DATABRIDGE=br-${lan}" >> $OURDIR/info.$lan
    echo "DATAIP=${DATAIP}" >> $OURDIR/info.$lan
    echo "DATANETMASK=${DATANETMASK}" >> $OURDIR/info.$lan
    echo "DATAVLAN=${DATAVLAN}" >> $OURDIR/info.$lan
    echo "DATAVLANTAG=${DATAVLANTAG}" >> $OURDIR/info.$lan
    echo "DATAVLANDEV=${DATAVLANDEV}" >> $OURDIR/info.$lan
    echo "DATAMAC=${DATAMAC}" >> $OURDIR/info.$lan
    echo "DATADEV=${DATADEV}" >> $OURDIR/info.$lan
done

for lan in $DATAVLANS ; do
    if [ -e $OURDIR/info.$lan ] ; then
	continue
    fi

    #DATAIP=`cat $OURDIR/data-hosts.$lan | grep -E "$NODEID$" | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
    #DATANETMASK=`cat $OURDIR/data-netmask.$lan`
    DATAVLAN=1
    DATAMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* VMAC=\([0-9a-f:\.]*\) .* LAN=${lan}.*\$/\1/p"`
    DATADEV=`/usr/local/etc/emulab/findif -m $DATAMAC`
    DATAVLANDEV=`ip link show ${DATADEV} | sed -n -e "s/^.*${DATADEV}\@\([0-9a-zA-Z_]*\): .*\$/\1/p"`
    DATAVLANTAG=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* LAN=${lan} VTAG=\([0-9]*\).*\$/\1/p"`

    echo "DATABRIDGE=br-${DATAVLANDEV}" >> $OURDIR/info.$lan
    #echo "DATAIP=${DATAIP}" >> $OURDIR/info.$lan
    #echo "DATANETMASK=${DATANETMASK}" >> $OURDIR/info.$lan
    echo "DATAVLAN=${DATAVLAN}" >> $OURDIR/info.$lan
    echo "DATAVLANTAG=${DATAVLANTAG}" >> $OURDIR/info.$lan
    echo "DATAVLANDEV=${DATAVLANDEV}" >> $OURDIR/info.$lan
    echo "DATAMAC=${DATAMAC}" >> $OURDIR/info.$lan
    echo "DATADEV=${DATADEV}" >> $OURDIR/info.$lan
done

##
## Setup some one-time neutron configuration variables, based on our network
## configuration
##
if [ ! -f $OURDIR/info.neutron ]; then
    #
    # Which type drives do we want to configure?
    #
    network_types=""
    # NB: we always configure flat, because the external net is flat
    #if [ -n "${DATAFLATLANS}" ]; then
	if [ -n "${network_types}" ]; then
	    network_types="${network_types},"
	fi
	network_types="${network_types}flat"
    #fi
    if [ -n "${DATAFLATLANS}" -a ${DATATUNNELS} -gt 0 ]; then
	if [ -n "${network_types}" ]; then
	    network_types="${network_types},"
	fi
	network_types="${network_types}gre"
    fi
    if [ -n "${DATAVLANS}" ]; then
	if [ -n "${network_types}" ]; then
	    network_types="${network_types},"
	fi
	network_types="${network_types}vlan"
    fi
    if [ -n "${DATAVXLANS}" ]; then
	if [ -n "${network_types}" ]; then
	    network_types="${network_types},"
	fi
	network_types="${network_types}vxlan"
    fi

    echo "network_types=\"${network_types}\"" >> $OURDIR/info.neutron

    #
    # What are our flat networks?
    #
    flat_networks="external"
    for lan in $DATAFLATLANS ; do
	if [ -n "${flat_networks}" ]; then
	    flat_networks="${flat_networks},"
	fi
	flat_networks="${flat_networks}${lan}"
    done

    echo "flat_networks=\"${flat_networks}\"" >> $OURDIR/info.neutron

    #
    # Figure out the bridge mappings
    #
    bridge_mappings="bridge_mappings=external:br-ex"
    for lan in $DATAFLATLANS ; do
	. $OURDIR/info.${lan}
	bridge_mappings="${bridge_mappings},${lan}:${DATABRIDGE}"
    done
    for lan in $DATAVLANS ; do
	. $OURDIR/info.${lan}
	# NB: neutron doesn't like to see the same map entry multiple times...
	echo "$bridge_mappings" | grep -q "${DATAVLANDEV}:"
	if [ $? = 0 ] ; then
	    continue;
	else
	    bridge_mappings="${bridge_mappings},${DATAVLANDEV}:${DATABRIDGE}"
	fi
    done

    echo "bridge_mappings=\"${bridge_mappings}\"" >> $OURDIR/info.neutron

    #
    # Figure out the network_vlan_ranges
    #
    network_vlan_ranges=""
    for lan in $DATAVLANS ; do
	. $OURDIR/info.${lan}
	if [ -n "${network_vlan_ranges}" ] ; then
	    network_vlan_ranges="${network_vlan_ranges},"
	fi
	network_vlan_ranges="${network_vlan_ranges}${DATAVLANDEV}:${DATAVLANTAG}:${DATAVLANTAG}"
    done

    echo "network_vlan_ranges=\"network_vlan_ranges=${network_vlan_ranges}\"" >> $OURDIR/info.neutron

    #
    # What's our first flat network, which will host our GRE tunnels?
    #
    gre_local_ip=""
    enable_tunneling=""
    tunnel_types=""
    for lan in $DATAFLATLANS ; do
	. $OURDIR/info.$lan

        # Just use the first one
	gre_local_ip="local_ip = $DATAIP"
	enable_tunneling="enable_tunneling = True"
	tunnel_types=""
	if [ ${DATATUNNELS} -gt 0 ]; then
	    if [ -z "${tunnel_types}" ]; then
		tunnel_types="tunnel_types = gre"
	    else
		tunnel_types="${tunnel_types},gre"
	    fi
	fi
	if [ ${DATAVXLANS} -gt 0 ]; then
	    if [ -z "${tunnel_types}" ]; then
		tunnel_types="tunnel_types = vxlan"
	    else
		tunnel_types="${tunnel_types},vxlan"
	    fi
	fi

	break
    done

    echo "gre_local_ip=\"${gre_local_ip}\"" >> $OURDIR/info.neutron
    echo "enable_tunneling=\"${enable_tunneling}\"" >> $OURDIR/info.neutron
    echo "tunnel_types=\"${tunnel_types}\"" >> $OURDIR/info.neutron

fi

##
## Util functions.
##

getfqdn() {
    n=$1
    fqdn=`cat $OURDIR/fqdn.map | grep -E "$n\s" | cut -f2`
    echo $fqdn
}
