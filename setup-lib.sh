#!/bin/sh

#
# Our default configuration
#
CONTROLLER="controller"
NETWORKMANAGER="networkmanager"
STORAGEHOST="controller"
OBJECTHOST="controller"
COMPUTENODES=""
BLOCKNODES=""
OBJECTNODES=""
DATALAN="lan-1"
MGMTLAN="lan-2"
BLOCKLAN=""
OBJECTLAN=""
SETUP_FLAT_DATA_NETWORK=1
USE_EXISTING_DATA_IPS=1
USE_EXISTING_MGMT_IPS=1
DO_APT_UPDATE=1
DO_UBUNTU_CLOUDARCHIVE=1

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

OURDIR=/root/setup
SETTINGS=$OURDIR/settings
LOCALSETTINGS=$OURDIR/settings.local
TOPOMAP=$OURDIR/topomap

mkdir -p $OURDIR
cd $OURDIR
touch $SETTINGS
touch $LOCALSETTINGS

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

if [ ! -f $OURDIR/apt-updated -a "${DO_APT_UPDATE}" = "1" ]; then
    apt-get update
    touch $OURDIR/apt-updated
fi

if [ ! -f /etc/apt/sources.list.d/cloudarchive-juno.list \
    -a ! -f $OURDIR/cloudarchive-added \
    -a "${DO_UBUNTU_CLOUDARCHIVE}" = "1" ]; then
    . /etc/lsb-release

    if [ "${DISTRIB_CODENAME}" = "trusty" ] ; then
	apt-get install -y ubuntu-cloud-keyring
	echo "deb http://ubuntu-cloud.archive.canonical.com/ubuntu" "${DISTRIB_CODENAME}-updates/juno main" > /etc/apt/sources.list.d/cloudarchive-juno.list
	apt-get update
    fi

    touch $OURDIR/cloudarchive-added
fi

#
# NB: this IP/mask is only valid after setting up the management network IP
# addresses because they might not be the Emulab ones.
#
MGMTIP=`cat /etc/hosts | grep $NODEID | head -1 | sed -n -e 's/^\\([0-9]*\\.[0-9]*\\.[0-9]*\\.[0-9]*\\).*$/\\1/p'`
MGMTNETMASK=`cat $OURDIR/data-netmask`
if [ -z "$MGMTLAN" ] ; then
    MGMTMAC=""
    MGMT_NETWORK_INTERFACE="tun0"
else
    MGMTMAC=`cat /var/emulab/boot/tmcc/ifconfig | sed -n -e "s/.* MAC=\([0-9a-f:\.]*\) .* LAN=${MGMTLAN}/\1/p"`
    MGMT_NETWORK_INTERFACE=`/usr/local/etc/emulab/findif -m $MGMTMAC`
fi

#
# NB: this IP/mask is only valid after data ips have been assigned, because
# they might not be the Emulab ones.
#
DATAIP=`cat $OURDIR/data-hosts | grep $NODEID | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
DATANETMASK=`cat $OURDIR/data-netmask`
DATAMAC=`cat /var/emulab/boot/tmcc/ifconfig | sed -n -e "s/.* MAC=\([0-9a-f:\.]*\) .* LAN=${DATALAN}/\1/p"`
DATA_NETWORK_INTERFACE=`/usr/local/etc/emulab/findif -m $DATAMAC`

#
# Openstack stuff
#
PSWDGEN="openssl rand -hex 10"
