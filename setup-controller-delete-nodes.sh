#!/bin/sh

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

DIRNAME=`dirname $0`

# Grab our lib stuff.
. "$DIRNAME/setup-lib.sh"

if [ "$HOSTNAME" != "$CONTROLLER" ]; then
    exit 0;
fi

OLDNODES="$@"

if [ -z "$OLDNODES" ] ; then
    echo "ERROR: $0 <list-of-oldnodes-short-names>"
    exit 1
fi

#
# For now, we just do the stupid thing and "evacuate" the VMs from the
# old hypervisor to a new hypervisor.  Let Openstack pick for now...
#
# To do this, we disable the compute service, force it down, and
# evacuate!
#
for node in $OLDNODES ; do
    echo "*** Forcing compute service on $node down and disabling it ..."
    fqdn=`getfqdn $node`
    id=`nova service-list | awk "/ $fqdn / { print \\$2 }"`
    nova service-disable $fqdn nova-compute
    # Hm, this only supported in some versions, so...
    nova service-force-down $fqdn nova-compute
    # ... do this too, to make sure the service doesn't come up
    $SSH $fqdn service nova-compute stop
    echo "update services set updated_at=NULL where id=$id" \
	| mysql -u nova --password=${NOVA_DBPASS} nova

done

#
# Ok, now that all these nodes are down, evacuate them (and this way the
# scheduler won't choose any of the going-down nodes as hosts for the
# evacuated VMs).
#
fqdnlist=""
for node in $OLDNODES ; do
    echo "*** Evacuating all instances from $node ..."
    fqdn=`getfqdn $node`

    nova host-evacuate $fqdn

    # Create a list for the next step so we don't have to keep resolving
    # FQDNs
    fqdnlist="${fqdnlist} $fqdn"
done

#
# Ok, now we want to wait until all those nodes no longer have instances
# on them.
#
sucess=0
while [ $success -ne 1 ]; do
    success=1
    for fqdn in $fqdnlist ; do
	sleep 8
	count=`nova hypervisor-servers $fqdn | awk '/ instance-.* / { print $2 }' | wc -l`
	if [ $count -gt 0 ]; then
	    success=0
	    echo "*** $fqdn still has $count instances"
	fi
    done
done

for node in $OLDNODES ; do
    echo "*** Deleting compute service on $node ..."
    fqdn=`getfqdn $node`
    id=`nova service-list | awk "/ $fqdn / { print \\$2 }"`
    nova service-delete $id
done

echo "*** Evacuated and deleted nodes $OLDNODES !"
exit 0
