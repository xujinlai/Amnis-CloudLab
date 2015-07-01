#!/bin/sh

#
# Our default configuration
#
CONTROLLER="ctl"
NETWORKMANAGER="nm"
STORAGEHOST="ctl"
OBJECTHOST="ctl"
COMPUTENODES=""
BLOCKNODES=""
OBJECTNODES=""
DATALAN="lan-1"
MGMTLAN="lan-2"
BLOCKLAN=""
OBJECTLAN=""
SETUP_TUNNEL_DATA_NETWORK=1
SETUP_FLAT_DATA_NETWORK=1
USE_EXISTING_DATA_IPS=1
USE_EXISTING_MGMT_IPS=1
DO_APT_INSTALL=1
DO_APT_UPDATE=1
DO_UBUNTU_CLOUDARCHIVE=1
BUILD_AARCH64_FROM_CORE=0
#ADMIN_PASS=`$PSWDGEN`
#ADMIN_PASS=admin
ADMIN_PASS="N!ceD3m0"

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
HOSTNAME=`cat /var/emulab/boot/nickname | cut -f1 -d.`
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

#
# Grab our topomap so we can see how many nodes we have.
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

NODES=`cat $TOPOMAP | grep -v '^#' | sed -n -e 's/^\([a-zA-Z0-9\-]*\),.*:.*$/\1/p' | xargs`
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
# NB: this IP/mask is only valid after setting up the management network IP
# addresses because they might not be the Emulab ones.
#
MGMTIP=`cat /etc/hosts | grep $NODEID | head -1 | sed -n -e 's/^\\([0-9]*\\.[0-9]*\\.[0-9]*\\.[0-9]*\\).*$/\\1/p'`
MGMTNETMASK=`cat $OURDIR/mgmt-netmask`
if [ -z "$MGMTLAN" ] ; then
    MGMTMAC=""
    MGMT_NETWORK_INTERFACE="tun0"
else
    cat /var/emulab/boot/tmcc/ifconfig | grep "IFACETYPE=vlan" | grep "${MGMTLAN}"
    if [ $? = 0 ]; then
	MGMTVLAN=1
	MGMTMAC=`cat /var/emulab/boot/tmcc/ifconfig | sed -n -e "s/^.* VMAC=\([0-9a-f:\.]*\) .* LAN=${MGMTLAN}.*\$/\1/p"`
	MGMT_NETWORK_INTERFACE=`/usr/local/etc/emulab/findif -m $MGMTMAC`
	MGMTVLANDEV=`ip link show ${MGMT_NETWORK_INTERFACE} | sed -n -e "s/^.*${MGMT_NETWORK_INTERFACE}\@\([0-9a-zA-Z_]*\): .*\$/\1/p"`
    else
	MGMTVLAN=0
	MGMTMAC=`cat /var/emulab/boot/tmcc/ifconfig | sed -n -e "s/.* MAC=\([0-9a-f:\.]*\) .* LAN=${MGMTLAN}/\1/p"`
	MGMT_NETWORK_INTERFACE=`/usr/local/etc/emulab/findif -m $MGMTMAC`
    fi
fi

#
# NB: this IP/mask is only valid after data ips have been assigned, because
# they might not be the Emulab ones.
#
DATAIP=`cat $OURDIR/data-hosts | grep $NODEID | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
DATANETMASK=`cat $OURDIR/data-netmask`
cat /var/emulab/boot/tmcc/ifconfig | grep "IFACETYPE=vlan" | grep "${DATALAN}"
if [ $? = 0 ]; then
    DATAVLAN=1
    DATAMAC=`cat /var/emulab/boot/tmcc/ifconfig | sed -n -e "s/^.* VMAC=\([0-9a-f:\.]*\) .* LAN=${DATALAN}.*\$/\1/p"`
    DATA_NETWORK_INTERFACE=`/usr/local/etc/emulab/findif -m $DATAMAC`
    DATAVLANDEV=`ip link show ${DATA_NETWORK_INTERFACE} | sed -n -e "s/^.*${DATA_NETWORK_INTERFACE}\@\([0-9a-zA-Z_]*\): .*\$/\1/p"`
else
    DATAVLAN=0
    DATAMAC=`cat /var/emulab/boot/tmcc/ifconfig | sed -n -e "s/.* MAC=\([0-9a-f:\.]*\) .* LAN=${DATALAN}/\1/p"`
    DATA_NETWORK_INTERFACE=`/usr/local/etc/emulab/findif -m $DATAMAC`
fi

#
# Openstack stuff
#
PSWDGEN="openssl rand -hex 10"
