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
neutron qos-policy-create bw-limiter-megadc
neutron qos-bandwidth-limit-rule-create bw-limiter-megadc --max-kbps 100000 \
  --max-burst-kbps 10000

# create the policy for micro datacenter
neutron qos-policy-create bw-limiter-mdc
neutron qos-bandwidth-limit-rule-create bw-limiter-mdc --max-kbps 100000 \
  --max-burst-kbps 10000

neutron qos-policy-create bw-limiter-sg
neutron qos-bandwidth-limit-rule-create bw-limiter-sg --max-kbps 1000 \
  --max-burst-kbps 1000
