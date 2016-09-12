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

#
# Fork off a bunch of parallelizable tasks, then do some misc stuff,
# then wait.
#
echo "*** Backgrounding quota setup..."
$DIRNAME/setup-basic-quotas.sh  >> $OURDIR/setup-basic-quotas.log 2>&1 &
quotaspid=$!
echo "*** Backgrounding network setup..."
$DIRNAME/setup-basic-networks.sh  >> $OURDIR/setup-basic-networks.log 2>&1 &
networkspid=$!
echo "*** Backgrounding user setup..."
$DIRNAME/setup-basic-users.sh  >> $OURDIR/setup-basic-users.log 2>&1 &
userspid=$!

if [ ${DEFAULT_SECGROUP_ENABLE_SSH_ICMP} -eq 1 ]; then
    echo "*** Setting up security group default rules..."
    nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0
    nova secgroup-add-rule default tcp 22 22 0.0.0.0/0
fi

. $DIRNAME/setup-images-lib.sh
lockfile-create $IMAGESETUPLOCKFILE
if [ -f $IMAGEUPLOADCMDFILE ]; then
    echo "*** Adding Images ..."
    . $OURDIR/admin-openrc.sh
    . $IMAGEUPLOADCMDFILE
fi
lockfile-remove $IMAGESETUPLOCKFILE

ARCH=`uname -m`
if [ "$ARCH" = "aarch64" ] ; then
    echo "*** Doing aarch64-specific setup..."
    $DIRNAME/setup-basic-aarch64.sh
else
    echo "*** Doing x86_64-specific setup..."
    $DIRNAME/setup-basic-x86_64.sh
fi

for pid in "$quotaspid $networkspid $userspid" ; do
    wait $pid
done

exit 0
