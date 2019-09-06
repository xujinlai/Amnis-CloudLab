#!/bin/sh

##
## Setup the Amnis Cluster
## which is an extension of Storm
##

set -x

DIRNAME=`dirname $0`
# Suck in a ton of profile settings from our parent's setup scripts.
. $DIRNAME/../../setup-lib.sh

# Grab our openstack creds.
. $OURDIR/admin-openrc.sh

# Set some local parameter defaults, before we suck in the params from
# the profile.
AMNIS_PUBKEY=""
AMNIS_EXT_NET="flat-lan-1-net"
AMNIS_PROJECT_REPO="https://github.com/xujinlai/Amnis-Project.git"
AMNIS_STORM_REPO="https://github.com/xujinlai/amnis-storm.git"
AMNIS_STORM_TAR="https://www-us.apache.org/dist/storm/apache-storm-2.0.0/apache-storm-2.0.0.tar.gz"
AMNIS_DEMO_BRANCH="master"

# Grab our parameters.
. $OURDIR/parameters

# Local functions.
__openstack() {
    __err=1
    __debug=
    __times=0
    while [ $__times -lt 16 -a ! $__err -eq 0 ]; do
        openstack $__debug "$@"
        __err=$?
        if [ $__err -eq 0 ]; then
            break
        fi
        __debug=" --debug "
        __times=`expr $__times + 1`
        if [ $__times -gt 1 ]; then
            echo "ERROR: openstack command failed: sleeping and trying again!"
            sleep 8
        fi
    done
}

mkdir -p $OURDIR/amnis
cd $OURDIR/amnis

HDOMAIN=`hostname`

#
# First, change all the public-facing service endpoints to our FQDN.  We
# really should be doing this in the OpenStack profile too; but ONAP
# requires it.
#
__openstack endpoint list | grep -q public
if [ $? -eq 0 ]; then
    IFS='
'
    for line in `openstack endpoint list | grep public`; do
	sid=`echo $line | awk '/ / {print $2}'`
	surl=`echo $line | sed -e 's/^.*\(http[^ ]*\) *.*$/\1/'`
	url=`echo "$surl" | sed -e "s/$CONTROLLER:/$HDOMAIN:/"`
	echo "Changing public endpoint ($surl) to ($url)"
	__openstack endpoint set --url "$url" "$sid"
    done
    unset IFS
else
    for sid in `openstack endpoint list | awk '/ / {print \$2}' | grep -v ^ID\$`; do
	surl=`openstack endpoint show $sid | grep publicurl | awk '/ / {print \$4}'`
	if [ -n "$surl" ]; then
	    url=`echo "$surl" | sed -e "s/$CONTROLLER:/$HDOMAIN:/"`
	    echo "Changing public endpoint ($surl) to ($url)"
	    echo "update endpoint set url='$url' where interface='public' and legacy_endpoint_id='$sid'" \
	        | mysql keystone
	fi
    done
fi


#
# Also, change the OS_AUTH_URL value to point to the FQDN, for later use
# in the Amnis env file.
#
export OS_AUTH_URL=`echo "$OS_AUTH_URL" | sed -e "s/$CONTROLLER:/$HDOMAIN:/"`


