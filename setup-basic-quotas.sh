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


if [ ${DEFAULT_SECGROUP_ENABLE_SSH_ICMP} -eq 1 ]; then
    nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0
    nova secgroup-add-rule default tcp 22 22 0.0.0.0/0
fi

if [ $GENIUSER -eq 1 ] ; then
    echo "*** Importing GENI user keys for admin user..."
    $DIRNAME/setup-user-info.py

    #
    # XXX: ugh, this is ugly, but now that we have two admin users, we have
    # to create keys for the admin user -- but we upload keys as the adminapi
    # user.  I can't find a way with the API to upload keys for another user
    # (seems very dumb, I must be missing something, but...)... so what we do
    # is add the keys once for the adminapi user, change the db manually to
    # make those keys be for the admin user, then add the same keys again (for
    # the adminapi user).  Then both admin users have the keys.
    #
    AAID=`keystone user-get ${ADMIN_API} | awk '/ id / {print $4}'`
    AID=`keystone user-get admin | awk '/ id / {print $4}'`
    echo "update key_pairs set user_id='$AID' where user_id='$AAID'" \
	| mysql -u root --password=${DB_ROOT_PASS} nova

    # Ok, do it again!
    echo "*** Importing GENI user keys, for ${ADMIN_API} user..."
    $DIRNAME/setup-user-info.py
fi

if [ $QUOTASOFF -eq 1 ]; then
    nova quota-class-update --instances -1 default
    nova quota-class-update --cores -1 default
    nova quota-class-update --ram -1 default
    nova quota-class-update --floating-ips -1 default
    nova quota-class-update --fixed-ips -1 default
    nova quota-class-update --metadata-items -1 default
    nova quota-class-update --injected-files -1 default
    nova quota-class-update --injected-file-content-bytes -1 default
    nova quota-class-update --injected-file-path-bytes -1 default
    nova quota-class-update --key-pairs -1 default
    nova quota-class-update --security-groups -1 default
    nova quota-class-update --security-group-rules -1 default
    nova quota-class-update --server-groups -1 default
    nova quota-class-update --server-group-members -1 default

    neutron quota-update --network -1
    neutron quota-update --subnet -1
    neutron quota-update --port -1
    neutron quota-update --router -1
    neutron quota-update --floatingip -1
    neutron quota-update --security-group -1
    neutron quota-update --security-group-rule -1
    neutron quota-update --rbac-policy -1
    neutron quota-update --vip -1
    neutron quota-update --pool -1
    neutron quota-update --member -1
    neutron quota-update --health-monitor -1

    cinder quota-class-update --volumes -1 default
    cinder quota-class-update --snapshots -1 default
    cinder quota-class-update --gigabytes -1 default
    # Guess you can't set these via CLI?
    #cinder quota-class-update --backup-_gigabytes -1 default
    #cinder quota-class-update --backups -1 default
    #cinder quota-class-update --per-volume-gigabytes -1 default

    openstack quota set --class --ram -1 admin
    openstack quota set --class --secgroup-rules -1 admin
    openstack quota set --class --instances -1 admin
    openstack quota set --class --key-pairs -1 admin
    openstack quota set --class --fixed-ips -1 admin
    openstack quota set --class --secgroups -1 admin
    openstack quota set --class --injected-file-size -1 admin
    openstack quota set --class --floating-ips -1 admin
    openstack quota set --class --injected-files -1 admin
    openstack quota set --class --cores -1 admin
    openstack quota set --class --injected-path-size -1 admin
    openstack quota set --class --gigabytes -1 admin
    openstack quota set --class --volumes -1 admin
    openstack quota set --class --snapshots -1 admin
    openstack quota set --class --volume-type -1 admin
fi
