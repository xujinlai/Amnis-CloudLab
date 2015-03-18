#!/bin/sh

##
## Initialize some basic aarch64 stuff.
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

echo "*** Downloading an x86_64 image ..."

wget https://cloud-images.ubuntu.com/trusty/current/trusty-server-cloudimg-amd64-disk1.img

echo "*** Importing new image ..."

glance image-create --name trusty-server --is-public True  --disk-format qcow2 --container-format bare --progress --file trusty-server-cloudimg-amd64-disk1.img

exit 0
