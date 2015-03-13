#!/bin/sh

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

SSH="ssh -o StrictHostKeyChecking=no"

if [ "$SWAPPER" = "geniuser" ]; then
    SWAPPER_EMAIL=`geni-get user_email`
else
    SWAPPER_EMAIL="$SWAPPER@$OURDOMAIN"
fi

#
# Grab our topomap so we can see how many nodes we have.
#
TTF=`mktemp topomap.XXXXXX`
$TMCC topomap | gunzip > $TTF

CONTROLLER="controller"
NETWORKMANAGER="networkmanager"
NODES=`cat $TTF | grep -v '^#' | sed -n -e 's/^\([a-zA-Z0-9\-]*\),.*:.*$/\1/p' | xargs`
COMPUTENODES=""
for node in $NODES
do
    if [ "$node" != "$CONTROLLER" -a "$node" != "$NETWORKMANAGER" ]; then
	COMPUTENODES="$COMPUTENODES $node"
    fi
done
rm -f $TTF

#
# Openstack stuff
#
PSWDGEN="openssl rand -hex 10"


OURDIR=/root/setup
SETTINGS=$OURDIR/settings

mkdir -p $OURDIR
cd $OURDIR

SETUP_FLAT_DATA_NETWORK=1
USE_EXISTING_DATA_IPS=1
EXTERNAL_NETWORK_INTERFACE="eth0"
EXTERNAL_NETWORK_BRIDGE="br-ex"
DATA_NETWORK_INTERFACE="eth1"
DATA_NETWORK_BRIDGE="br-int"

EXT_FLOAT_IP_START=128.110.154.240
EXT_FLOAT_IP_END=128.110.154.254
