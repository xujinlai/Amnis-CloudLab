#!/bin/sh

##
## Setup the OpenStack QoS policies
## The default policy contains: MegaDC, MDC, SmartGateway
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

logtstart "qos"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

# create the policy for mega datacenter
openstack network qos policy create bw-limiter-megadc
openstack network qos rule create --type bandwidth-limit --egress bw-limiter-megadc --max-kbps 100000 --max-burst-kbits 80000
openstack network qos rule create --type bandwidth-limit --ingress bw-limiter-megadc --max-kbps 100000 --max-burst-kbits 80000

# create the policy for micro datacenter
openstack network qos policy create bw-limiter-mdc
openstack network qos rule create --type bandwidth-limit --egress bw-limiter-mdc --max-kbps 100000 --max-burst-kbits 80000
openstack network qos rule create --type bandwidth-limit --ingress bw-limiter-mdc --max-kbps 100000 --max-burst-kbits 80000

# create the policy for micro datacenter
openstack network qos policy create bw-limiter-sg
openstack network qos rule create --type bandwidth-limit --egress bw-limiter-sg --max-kbps 1000 --max-burst-kbits 800
openstack network qos rule create --type bandwidth-limit --ingress bw-limiter-sg --max-kbps 1000 --max-burst-kbits 800


logtend "qos"
exit 0