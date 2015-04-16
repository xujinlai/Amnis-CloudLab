#!/bin/sh

##
## Setup the OpenStack controller node.
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

# Make sure our repos are setup.
#apt-get install ubuntu-cloud-keyring
#echo "deb http://ubuntu-cloud.archive.canonical.com/ubuntu" \
#    "trusty-updates/juno main" > /etc/apt/sources.list.d/cloudarchive-juno.list

#sudo add-apt-repository ppa:ubuntu-cloud-archive/juno-staging 

#
# Setup mail to users
#
apt-get install -y dma
echo "Your OpenStack instance is setting up on `hostname` ." \
    |  mail -s "OpenStack Instance Setting Up" ${SWAPPER_EMAIL} &

#
# Install the database
#
if [ -z "${DB_ROOT_PASS}" ]; then
    apt-get install -y mariadb-server python-mysqldb < /dev/null
    service mysql stop
    # Change the root password; secure the users/dbs.
    mysqld_safe --skip-grant-tables --skip-networking &
    sleep 8
    DB_ROOT_PASS=`$PSWDGEN`
    # This does what mysql_secure_installation does on Ubuntu
    echo "use mysql; update user set password=PASSWORD(\"${DB_ROOT_PASS}\") where User='root'; delete from user where User=''; delete from user where User='root' and Host not in ('localhost', '127.0.0.1', '::1'); drop database test; delete from db where Db='test' or Db='test\\_%'; flush privileges;" | mysql -u root 
    # Shutdown our unprotected server
    mysqladmin --password=${DB_ROOT_PASS} shutdown
    # Put it on the management network and set recommended settings
    echo "[mysqld]" >> /etc/mysql/my.cnf
    echo "bind-address = $MGMTIP" >> /etc/mysql/my.cnf
    echo "default-storage-engine = innodb" >> /etc/mysql/my.cnf
    echo "innodb_file_per_table" >> /etc/mysql/my.cnf
    echo "collation-server = utf8_general_ci" >> /etc/mysql/my.cnf
    echo "init-connect = 'SET NAMES utf8'" >> /etc/mysql/my.cnf
    echo "character-set-server = utf8" >> /etc/mysql/my.cnf
    echo "max_connections = 5000" >> /etc/mysql/my.cnf
    # Restart it!
    service mysql restart
    # Save the passwd
    echo "DB_ROOT_PASS=\"${DB_ROOT_PASS}\"" >> $SETTINGS
fi

#
# Install a message broker
#
if [ -z "${RABBIT_PASS}" ]; then
    apt-get install -y rabbitmq-server

cat <<EOF > /etc/rabbitmq/rabbitmq.config
[
 {rabbit,
  [
   {loopback_users, []}
  ]}
]
.
EOF

    RABBIT_PASS=`$PSWDGEN`
    rabbitmqctl change_password guest $RABBIT_PASS
    # Save the passwd
    echo "RABBIT_PASS=\"${RABBIT_PASS}\"" >> $SETTINGS

    service rabbitmq-server restart
fi

#
# Install the Identity Service
#
if [ -z "${KEYSTONE_DBPASS}" ]; then
    KEYSTONE_DBPASS=`$PSWDGEN`
    echo "create database keystone" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on keystone.* to 'keystone'@'localhost' identified by '$KEYSTONE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on keystone.* to 'keystone'@'%' identified by '$KEYSTONE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    apt-get install -y keystone python-keystoneclient

    ADMIN_TOKEN=`$PSWDGEN`

    sed -i -e "s/^.*admin_token.*=.*$/admin_token=$ADMIN_TOKEN/" /etc/keystone/keystone.conf
    sed -i -e "s/^.*connection.*=.*$/connection=mysql:\\/\\/keystone:${KEYSTONE_DBPASS}@$CONTROLLER\\/keystone/" /etc/keystone/keystone.conf
    sed -i -e "s/^.*provider=.*$/provider=keystone.token.providers.uuid.Provider/" /etc/keystone/keystone.conf
    sed -i -e "s/^.*driver=keystone.token.*$/driver=keystone.token.persistence.backends.sql.Token/" /etc/keystone/keystone.conf

    sed -i -e "s/^.*verbose.*=.*$/verbose=true/" /etc/keystone/keystone.conf

    su -s /bin/sh -c "/usr/bin/keystone-manage db_sync" keystone

    service keystone restart
    rm -f /var/lib/keystone/keystone.db

    sleep 8

    # optional of course
    (crontab -l -u keystone 2>&1 | grep -q token_flush) || \
        echo '@hourly /usr/bin/keystone-manage token_flush >/var/log/keystone/keystone-tokenflush.log 2>&1' \
        >> /var/spool/cron/crontabs/keystone

    # Create admin token
    export OS_SERVICE_TOKEN=$ADMIN_TOKEN
    export OS_SERVICE_ENDPOINT=http://$CONTROLLER:35357/v2.0

    # Create the admin tenant
    keystone tenant-create --name admin --description "Admin Tenant"
    # Create the admin user
    ADMIN_PASS=`$PSWDGEN`
    ADMIN_PASS=admin
    ADMIN_PASS="N!ceD3m0"
    keystone user-create --name admin --pass ${ADMIN_PASS} --email "${SWAPPER_EMAIL}"
    # Create the admin role
    keystone role-create --name admin
    # Add the admin tenant and user to the admin role:
    keystone user-role-add --tenant admin --user admin --role admin
    # Create the _member_ role:
    keystone role-create --name _member_
    # Add the admin tenant and user to the _member_ role:
    keystone user-role-add --tenant admin --user admin --role _member_
    # Create the service tenant:
    keystone tenant-create --name service --description "Service Tenant"
    # Create the service entity for the Identity service:
    keystone service-create --name keystone --type identity \
        --description "OpenStack Identity Service"
    # Create the API endpoint for the Identity service:
    keystone endpoint-create \
        --service-id `keystone service-list | awk '/ identity / {print $2}'` \
        --publicurl http://$CONTROLLER:5000/v2.0 \
        --internalurl http://$CONTROLLER:5000/v2.0 \
        --adminurl http://$CONTROLLER:35357/v2.0 \
        --region regionOne

    unset OS_SERVICE_TOKEN OS_SERVICE_ENDPOINT

    sed -i -e "s/^.*admin_token.*$/#admin_token =/" /etc/keystone/keystone.conf

    # Save the passwd
    echo "ADMIN_PASS=\"${ADMIN_PASS}\"" >> $SETTINGS
    echo "KEYSTONE_DBPASS=\"${KEYSTONE_DBPASS}\"" >> $SETTINGS
fi

#
# From here on out, we need to be the admin user.
#
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=$ADMIN_PASS
export OS_AUTH_URL=http://$CONTROLLER:35357/v2.0

echo "export OS_TENANT_NAME=admin" > $OURDIR/admin-openrc.sh
echo "export OS_USERNAME=admin" >> $OURDIR/admin-openrc.sh
echo "export OS_PASSWORD=${ADMIN_PASS}" >> $OURDIR/admin-openrc.sh
echo "export OS_AUTH_URL=http://$CONTROLLER:35357/v2.0" >> $OURDIR/admin-openrc.sh

#
# Install the Image service
#
if [ -z "${GLANCE_DBPASS}" ]; then
    GLANCE_DBPASS=`$PSWDGEN`
    GLANCE_PASS=`$PSWDGEN`

    echo "create database glance" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on glance.* to 'glance'@'localhost' identified by '$GLANCE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on glance.* to 'glance'@'%' identified by '$GLANCE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    keystone user-create --name glance --pass $GLANCE_PASS
    keystone user-role-add --user glance --tenant service --role admin
    keystone service-create --name glance --type image \
	--description "OpenStack Image Service"

    keystone endpoint-create \
	--service-id `keystone service-list | awk '/ image / {print $2}'` \
	--publicurl http://$CONTROLLER:9292 \
	--internalurl http://$CONTROLLER:9292 \
	--adminurl http://$CONTROLLER:9292 \
	--region regionOne

    apt-get install -y glance python-glanceclient

    sed -i -e "s/^.*connection.*=.*$/connection = mysql:\\/\\/glance:${GLANCE_DBPASS}@$CONTROLLER\\/glance/" /etc/glance/glance-api.conf
    # Just slap these in.
    cat <<EOF >> /etc/glance/glance-api.conf
[keystone_authtoken]
auth_uri = http://$CONTROLLER:5000/v2.0
identity_uri = http://$CONTROLLER:35357
admin_tenant_name = service
admin_user = glance
admin_password = ${GLANCE_PASS}

[paste_deploy]
flavor = keystone
EOF
    sed -i -e "s/^.*verbose.*=.*$/verbose=true/" /etc/glance/glance-api.conf

    sed -i -e "s/^.*connection.*=.*$/connection = mysql:\\/\\/glance:${GLANCE_DBPASS}@$CONTROLLER\\/glance/" /etc/glance/glance-registry.conf
    # Just slap these in.
    cat <<EOF >> /etc/glance/glance-registry.conf
[keystone_authtoken]
auth_uri = http://$CONTROLLER:5000/v2.0
identity_uri = http://$CONTROLLER:35357
admin_tenant_name = service
admin_user = glance
admin_password = ${GLANCE_PASS}

[paste_deploy]
flavor = keystone
EOF
    sed -i -e "s/^.*verbose.*=.*$/verbose=true/" /etc/glance/glance-registry.conf

    su -s /bin/sh -c "/usr/bin/glance-manage db_sync" glance

    service glance-registry restart
    service glance-api restart
    rm -f /var/lib/glance/glance.sqlite

    echo "GLANCE_DBPASS=\"${GLANCE_DBPASS}\"" >> $SETTINGS
    echo "GLANCE_PASS=\"${GLANCE_PASS}\"" >> $SETTINGS
fi

#
# Install the Compute service on the controller
#
if [ -z "${NOVA_DBPASS}" ]; then
    NOVA_DBPASS=`$PSWDGEN`
    NOVA_PASS=`$PSWDGEN`

    # Make sure we're consistent with the clients
    apt-get install -y nova-api

    echo "create database nova" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on nova.* to 'nova'@'localhost' identified by '$NOVA_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on nova.* to 'nova'@'%' identified by '$NOVA_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    keystone user-create --name nova --pass $NOVA_PASS
    keystone user-role-add --user nova --tenant service --role admin
    keystone service-create --name nova --type compute \
	--description "OpenStack Compute Service"
    keystone endpoint-create \
	--service-id `keystone service-list | awk '/ compute / {print $2}'` \
	--publicurl http://$CONTROLLER:8774/v2/%\(tenant_id\)s \
	--internalurl http://$CONTROLLER:8774/v2/%\(tenant_id\)s \
	--adminurl http://$CONTROLLER:8774/v2/%\(tenant_id\)s \
	--region regionOne

    apt-get install -y nova-api nova-cert nova-conductor nova-consoleauth \
	nova-novncproxy nova-scheduler python-novaclient

    # Just slap these in.
    cat <<EOF >> /etc/nova/nova.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = $CONTROLLER
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
my_ip = ${MGMTIP}
vncserver_listen = ${MGMTIP}
vncserver_proxyclient_address = ${MGMTIP}
verbose = True

[database]
connection = mysql://nova:$NOVA_DBPASS@$CONTROLLER/nova

[keystone_authtoken]
auth_uri = http://$CONTROLLER:5000/v2.0
identity_uri = http://$CONTROLLER:35357
admin_tenant_name = service
admin_user = nova
admin_password = ${NOVA_PASS}

[glance]
host = $CONTROLLER
EOF

    su -s /bin/sh -c "nova-manage db sync" nova

    service nova-api restart
    service nova-cert restart
    service nova-consoleauth restart
    service nova-scheduler restart
    service nova-conductor restart
    service nova-novncproxy restart

    rm -f /var/lib/nova/nova.sqlite

    echo "NOVA_DBPASS=\"${NOVA_DBPASS}\"" >> $SETTINGS
    echo "NOVA_PASS=\"${NOVA_PASS}\"" >> $SETTINGS
fi

#
# Install the Compute service on the compute nodes
#
if [ -z "${NOVA_COMPUTENODES_DONE}" ]; then
    NOVA_COMPUTENODES_DONE=1

    for node in $COMPUTENODES
    do
	fqdn="$node.$EEID.$EPID.$OURDOMAIN"

	# Copy the latest settings (passwords, endpoints, whatever) over
	scp -o StrictHostKeyChecking=no $SETTINGS admin-openrc.sh $fqdn:$OURDIR

	$SSH $fqdn $DIRNAME/setup-compute.sh
    done

    echo "NOVA_COMPUTENODES_DONE=\"${NOVA_COMPUTENODES_DONE}\"" >> $SETTINGS
fi

#
# Install the Network service on the controller
#
if [ -z "${NEUTRON_DBPASS}" ]; then
    NEUTRON_DBPASS=`$PSWDGEN`
    NEUTRON_PASS=`$PSWDGEN`
    NEUTRON_METADATA_SECRET=`$PSWDGEN`

    echo "create database neutron" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on neutron.* to 'neutron'@'localhost' identified by '$NEUTRON_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on neutron.* to 'neutron'@'%' identified by '$NEUTRON_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    keystone user-create --name neutron --pass ${NEUTRON_PASS}
    keystone user-role-add --user neutron --tenant service --role admin

    keystone service-create --name neutron --type network \
	--description "OpenStack Networking Service"

    keystone endpoint-create \
	--service-id `keystone service-list | awk '/ network / {print $2}'` \
	--publicurl http://$CONTROLLER:9696 \
	--adminurl http://$CONTROLLER:9696 \
	--internalurl http://$CONTROLLER:9696 \
	--region regionOne

    apt-get install -y neutron-server neutron-plugin-ml2 python-neutronclient

    service_tenant_id=`keystone tenant-get service | grep id | cut -d '|' -f 3`

sed -i -e "s/^\\(.*connection.*=.*\\)$/#\1/" /etc/neutron/neutron.conf
sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/neutron/neutron.conf
sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/neutron/neutron.conf
sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/neutron/neutron.conf

    cat <<EOF >> /etc/neutron/neutron.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = $CONTROLLER
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
my_ip = ${MGMTIP}
vncserver_listen = ${MGMTIP}
vncserver_proxyclient_address = ${MGMTIP}
verbose = True
core_plugin = ml2
service_plugins = router
allow_overlapping_ips = True
notify_nova_on_port_status_changes = True
notify_nova_on_port_data_changes = True
nova_url = http://$CONTROLLER:8774/v2
nova_admin_auth_url = http://$CONTROLLER:35357/v2.0
nova_region_name = regionOne
nova_admin_username = nova
nova_admin_tenant_id = ${service_tenant_id}
nova_admin_password = ${NOVA_PASS}

[database]
connection = mysql://neutron:$NEUTRON_DBPASS@$CONTROLLER/neutron

[keystone_authtoken]
auth_uri = http://$CONTROLLER:5000/v2.0
identity_uri = http://$CONTROLLER:35357
admin_tenant_name = service
admin_user = neutron
admin_password = ${NEUTRON_PASS}

[glance]
host = $CONTROLLER
EOF

# enable_security_group = True
# firewall_driver = neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver

    cat <<EOF >> /etc/neutron/plugins/ml2/ml2_conf.ini
[ml2]
type_drivers = flat,gre
tenant_network_types = flat,gre
mechanism_drivers = openvswitch

[ml2_type_flat]
flat_networks = external,data

[ml2_type_gre]
tunnel_id_ranges = 1:1000

[securitygroup]
enable_security_group = True
enable_ipset = True
firewall_driver = neutron.agent.firewall.NoopFirewallDriver
EOF

    cat <<EOF >> /etc/nova/nova.conf
[DEFAULT]
network_api_class = nova.network.neutronv2.api.API
security_group_api = neutron
linuxnet_interface_driver = nova.network.linux_net.LinuxOVSInterfaceDriver
firewall_driver = nova.virt.firewall.NoopFirewallDriver

[neutron]
url = http://$CONTROLLER:9696
auth_strategy = keystone
admin_auth_url = http://$CONTROLLER:35357/v2.0
admin_tenant_name = service
admin_username = neutron
admin_password = ${NEUTRON_PASS}
service_metadata_proxy = True
metadata_proxy_shared_secret = ${NEUTRON_METADATA_SECRET}
EOF

    su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade juno" neutron

    service nova-api restart
    service nova-scheduler restart
    service nova-conductor restart
    service neutron-server restart

    echo "NEUTRON_DBPASS=\"${NEUTRON_DBPASS}\"" >> $SETTINGS
    echo "NEUTRON_PASS=\"${NEUTRON_PASS}\"" >> $SETTINGS
    echo "NEUTRON_METADATA_SECRET=\"${NEUTRON_METADATA_SECRET}\"" >> $SETTINGS
fi

#
# Install the Network service on the networkmanager
#
if [ -z "${NEUTRON_NETWORKMANAGER_DONE}" ]; then
    NEUTRON_NETWORKMANAGER_DONE=1

    fqdn="$NETWORKMANAGER.$EEID.$EPID.$OURDOMAIN"

    # Copy the latest settings (passwords, endpoints, whatever) over
    scp -o StrictHostKeyChecking=no $SETTINGS $fqdn:$SETTINGS

    ssh -o StrictHostKeyChecking=no $fqdn \
	$DIRNAME/setup-networkmanager.sh

    echo "NEUTRON_NETWORKMANAGER_DONE=\"${NEUTRON_NETWORKMANAGER_DONE}\"" >> $SETTINGS
fi

#
# Install the Network service on the compute nodes
#
if [ -z "${NEUTRON_COMPUTENODES_DONE}" ]; then
    NEUTRON_COMPUTENODES_DONE=1

    for node in $COMPUTENODES
    do
	fqdn="$node.$EEID.$EPID.$OURDOMAIN"

	# Copy the latest settings (passwords, endpoints, whatever) over
	scp -o StrictHostKeyChecking=no $SETTINGS $fqdn:$SETTINGS

	ssh -o StrictHostKeyChecking=no $fqdn $DIRNAME/setup-compute-network.sh
    done

    echo "NEUTRON_COMPUTENODES_DONE=\"${NEUTRON_COMPUTENODES_DONE}\"" >> $SETTINGS
fi

#
# Configure the networks on the controller
#
if [ -z "${NEUTRON_NETWORKS_DONE}" ]; then
    NEUTRON_NETWORKS_DONE=1

    neutron net-create ext-net --shared --router:external True \
	--provider:physical_network external --provider:network_type flat

    mygw=`ip route show default | sed -n -e 's/^default via \([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
    mynet=`ip route show dev br-ex | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\/[0-9]*\) .*$/\1/p'`

    neutron subnet-create ext-net --name ext-subnet \
	--disable-dhcp --gateway $mygw $mynet

    SID=`neutron subnet-show ext-subnet | awk '/ id / {print $4}'`
    # NB: get rid of the default one!
    if [ ! -z "$SID" ]; then
	echo "delete from ipallocationpools where subnet_id='$SID'" \
	    | mysql --password=${DB_ROOT_PASS} neutron
    fi

    # NB: this is important to do before we connect any routers to the ext-net
    # (i.e., in setup-basic.sh)
    for ip in $PUBLICADDRS ; do
	echo "insert into ipallocationpools values (UUID(),'$SID','$ip','$ip')" \
	    | mysql --password=${DB_ROOT_PASS} neutron
    done

    echo "NEUTRON_NETWORKS_DONE=\"${NEUTRON_NETWORKS_DONE}\"" >> $SETTINGS
fi

#
# Install the Dashboard service on the controller
#
if [ -z "${DASHBOARD_DONE}" ]; then
    DASHBOARD_DONE=1

    apt-get install -y openstack-dashboard apache2 libapache2-mod-wsgi memcached python-memcache

    sed -i -e 's/OPENSTACK_HOST.*=.*$/OPENSTACK_HOST = "controller"/' \
	/etc/openstack-dashboard/local_settings.py
    sed -i -e 's/^.*ALLOWED_HOSTS = \[.*$/ALLOWED_HOSTS = \["*"\]/' \
	/etc/openstack-dashboard/local_settings.py

    service apache2 restart
    service memcached restart

    echo "DASHBOARD_DONE=\"${DASHBOARD_DONE}\"" >> $SETTINGS
fi

#
# Install some block storage.
#
#if [ 0 -eq 1 -a -z "${CINDER_DBPASS}" ]; then
if [ -z "${CINDER_DBPASS}" ]; then
    CINDER_DBPASS=`$PSWDGEN`
    CINDER_PASS=`$PSWDGEN`

    echo "create database cinder" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on cinder.* to 'cinder'@'localhost' identified by '$CINDER_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on cinder.* to 'cinder'@'%' identified by '$CINDER_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    keystone user-create --name cinder --pass $CINDER_PASS
    keystone user-role-add --user cinder --tenant service --role admin
    keystone service-create --name cinder --type volume \
	--description "OpenStack Block Storage Service"
    keystone service-create --name cinderv2 --type volumev2 \
	--description "OpenStack Block Storage Service"

    keystone endpoint-create \
	--service-id `keystone service-list | awk '/ volume / {print $2}'` \
	--publicurl http://controller:8776/v1/%\(tenant_id\)s \
	--internalurl http://controller:8776/v1/%\(tenant_id\)s \
	--adminurl http://controller:8776/v1/%\(tenant_id\)s \
	--region regionOne

    keystone endpoint-create \
	--service-id `keystone service-list | awk '/ volumev2 / {print $2}'` \
	--publicurl http://controller:8776/v2/%\(tenant_id\)s \
	--internalurl http://controller:8776/v2/%\(tenant_id\)s \
	--adminurl http://controller:8776/v2/%\(tenant_id\)s \
	--region regionOne

    apt-get install -y cinder-api cinder-scheduler python-cinderclient

    sed -i -e "s/^\\(.*volume_group.*=.*\\)$/#\1/" /etc/cinder/cinder.conf

    # Just slap these in.
    cat <<EOF >> /etc/cinder/cinder.conf
[database]
connection = mysql://cinder:${CINDER_DBPASS}@$CONTROLLER/cinder

[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER}
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
my_ip = ${MGMTIP}
verbose = True
glance_host = ${CONTROLLER}
volume_group = openstack-volumes

[keystone_authtoken]
auth_uri = http://$CONTROLLER:5000/v2.0
identity_uri = http://$CONTROLLER:35357
admin_tenant_name = service
admin_user = cinder
admin_password = ${CINDER_PASS}
EOF

    sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/cinder/cinder.conf
    sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/cinder/cinder.conf
    sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/cinder/cinder.conf

    su -s /bin/sh -c "/usr/bin/cinder-manage db sync" cinder

    service cinder-scheduler restart
    service cinder-api restart
    service cinder-volume restart
    rm -f /var/lib/cinder/cinder.sqlite

    echo "CINDER_DBPASS=\"${CINDER_DBPASS}\"" >> $SETTINGS
    echo "CINDER_PASS=\"${CINDER_PASS}\"" >> $SETTINGS
fi

if [ -z "${STORAGE_HOST_DONE}" ]; then
    fqdn="$STORAGEHOST.$EEID.$EPID.$OURDOMAIN"

    if [ "${STORAGEHOST}" = "${CONTROLLER}" ]; then
	$DIRNAME/setup-storage.sh
    else
        # Copy the latest settings (passwords, endpoints, whatever) over
	scp -o StrictHostKeyChecking=no $SETTINGS $fqdn:$SETTINGS

	ssh -o StrictHostKeyChecking=no $fqdn $DIRNAME/setup-storage.sh
    fi

    echo "STORAGE_HOST_DONE=\"1\"" >> $SETTINGS
fi

#
# Install some object storage.
#
#if [ 0 -eq 1 -a -z "${SWIFT_DBPASS}" ]; then
if [ -z "${SWIFT_PASS}" ]; then
    SWIFT_PASS=`$PSWDGEN`
    SWIFT_HASH_PATH_PREFIX=`$PSWDGEN`
    SWIFT_HASH_PATH_SUFFIX=`$PSWDGEN`

    keystone user-create --name swift --pass $SWIFT_PASS
    keystone user-role-add --user swift --tenant service --role admin
    keystone service-create --name swift --type object-store \
	--description "OpenStack Object Storage Service"

    keystone endpoint-create \
	--service-id `keystone service-list | awk '/ object-store / {print $2}'` \
	--publicurl http://controller:8080/v1/AUTH_%\(tenant_id\)s \
	--internalurl http://controller:8080/v1/AUTH_%\(tenant_id\)s \
	--adminurl http://controller:8080 \
	--region regionOne

    apt-get install -y swift swift-proxy python-swiftclient \
	python-keystoneclient python-keystonemiddleware memcached

    mkdir -p /etc/swift

    wget -O /etc/swift/proxy-server.conf \
	https://raw.githubusercontent.com/openstack/swift/stable/juno/etc/proxy-server.conf-sample

    # Just slap these in.
    cat <<EOF >> /etc/swift/proxy-server.conf
[DEFAULT]
bind_port = 8080
user = swift
swift_dir = /etc/swift

[pipeline:main]
pipeline = authtoken cache healthcheck keystoneauth proxy-logging proxy-server

[app:proxy-server]
allow_account_management = true
account_autocreate = true

[filter:keystoneauth]
use = egg:swift#keystoneauth
operator_roles = admin,_member_

[filter:authtoken]
paste.filter_factory = keystonemiddleware.auth_token:filter_factory
auth_uri = http://${CONTROLLER}:5000/v2.0
identity_uri = http://${CONTROLLER}:35357
admin_tenant_name = service
admin_user = swift
admin_password = ${SWIFT_PASS}
delay_auth_decision = true

[filter:cache]
memcache_servers = 127.0.0.1:11211
EOF

    sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/swift/proxy-server.conf
    sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/swift/proxy-server.conf
    sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/swift/proxy-server.conf

    wget -O /etc/swift/swift.conf \
	https://raw.githubusercontent.com/openstack/swift/stable/juno/etc/swift.conf-sample

    # Just slap these in.
    cat <<EOF >> /etc/swift/swift.conf
[swift-hash]
swift_hash_path_suffix = ${SWIFT_HASH_PATH_PREFIX}
swift_hash_path_prefix = ${SWIFT_HASH_PATH_SUFFIX}

[storage-policy:0]
name = Policy-0
default = yes
EOF

    chown -R swift:swift /etc/swift

    service memcached restart
    swift-init proxy-server restart

    echo "SWIFT_PASS=\"${SWIFT_PASS}\"" >> $SETTINGS
    echo "SWIFT_HASH_PATH_PREFIX=\"${SWIFT_HASH_PATH_PREFIX}\"" >> $SETTINGS
    echo "SWIFT_HASH_PATH_SUFFIX=\"${SWIFT_HASH_PATH_SUFFIX}\"" >> $SETTINGS
fi

if [ -z "${OBJECT_HOST_DONE}" ]; then
    fqdn="$OBJECTHOST.$EEID.$EPID.$OURDOMAIN"

    if [ "${OBJECTHOST}" = "${CONTROLLER}" ]; then
	$DIRNAME/setup-object-storage.sh
    else
        # Copy the latest settings (passwords, endpoints, whatever) over
	scp -o StrictHostKeyChecking=no $SETTINGS $fqdn:$SETTINGS

	ssh -o StrictHostKeyChecking=no $fqdn $DIRNAME/setup-object-storage.sh
    fi

    echo "OBJECT_HOST_DONE=\"1\"" >> $SETTINGS
fi

if [ -z "${OBJECT_RING_DONE}" ]; then
    cdir=`pwd`
    cd /etc/swift

    objip=`cat $OURDIR/mgmt-hosts | grep $OBJECTHOST | cut -d ' ' -f 1`

    swift-ring-builder account.builder create 10 3 1
    swift-ring-builder account.builder \
	add r1z1-${objip}:6002/pv.objectstore.loop.1 100
    swift-ring-builder account.builder rebalance

    swift-ring-builder container.builder create 10 3 1
    swift-ring-builder container.builder \
	add r1z1-${objip}:6001/pv.objectstore.loop.1 100
    swift-ring-builder container.builder rebalance

    swift-ring-builder object.builder create 10 3 1
    swift-ring-builder object.builder \
	add r1z1-${objip}:6000/pv.objectstore.loop.1 100
    swift-ring-builder object.builder rebalance

    if [ "${OBJECTHOST}" != "${CONTROLLER}" ]; then
        # Copy the latest settings
	scp -o StrictHostKeyChecking=no account.ring.gz container.ring.gz object.ring.gz $OBJECTHOST:/etc/swift
    fi

    cd $cdir

    echo "OBJECT_RING_DONE=\"1\"" >> $SETTINGS
fi

#
# Get Orchestrated
#
if [ -z "${HEAT_DBPASS}" ]; then
    HEAT_DBPASS=`$PSWDGEN`
    HEAT_PASS=`$PSWDGEN`

    echo "create database heat" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on heat.* to 'heat'@'localhost' identified by '$HEAT_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on heat.* to 'heat'@'%' identified by '$HEAT_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    keystone user-create --name heat --pass $HEAT_PASS
    keystone user-role-add --user heat --tenant service --role admin
    keystone role-create --name heat_stack_owner
    #keystone user-role-add --user demo --tenant demo --role heat_stack_owner
    keystone role-create --name heat_stack_user

    keystone service-create --name heat --type orchestration \
	--description "OpenStack Orchestration Service"
    keystone service-create --name heat-cfn --type cloudformation \
	--description "OpenStack Orchestration Service"

    keystone endpoint-create \
	--service-id $(keystone service-list | awk '/ orchestration / {print $2}') \
	--publicurl http://${CONTROLLER}:8004/v1/%\(tenant_id\)s \
	--internalurl http://${CONTROLLER}:8004/v1/%\(tenant_id\)s \
	--adminurl http://${CONTROLLER}:8004/v1/%\(tenant_id\)s \
	--region regionOne
    keystone endpoint-create \
	--service-id $(keystone service-list | awk '/ cloudformation / {print $2}') \
	--publicurl http://${CONTROLLER}:8000/v1 \
	--internalurl http://${CONTROLLER}:8000/v1 \
	--adminurl http://${CONTROLLER}:8000/v1 \
	--region regionOne

    apt-get install -y heat-api heat-api-cfn heat-engine python-heatclient

    sed -i -e "s/^.*connection.*=.*$/connection = mysql:\\/\\/heat:${HEAT_DBPASS}@$CONTROLLER\\/heat/" /etc/heat/heat.conf
    # Just slap these in.
    cat <<EOF >> /etc/heat/heat.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER}
rabbit_password = ${RABBIT_PASS}
heat_metadata_server_url = http://${CONTROLLER}:8000
heat_waitcondition_server_url = http://${CONTROLLER}:8000/v1/waitcondition
verbose = True
auth_strategy = keystone

[keystone_authtoken]
auth_uri = http://$CONTROLLER:5000/v2.0
identity_uri = http://$CONTROLLER:35357
admin_tenant_name = service
admin_user = heat
admin_password = ${HEAT_PASS}

[ec2authtoken]
auth_uri = http://${CONTROLLER}:5000/v2.0
EOF

    sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/heat/heat.conf
    sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/heat/heat.conf
    sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/heat/heat.conf


    su -s /bin/sh -c "/usr/bin/heat-manage db_sync" heat

    service heat-api restart
    service heat-api-cfn restart
    service heat-engine restart

    rm -f /var/lib/heat/heat.sqlite

    echo "HEAT_DBPASS=\"${HEAT_DBPASS}\"" >> $SETTINGS
    echo "HEAT_PASS=\"${HEAT_PASS}\"" >> $SETTINGS
fi

#
# Get Telemeterized
#
if [ -z "${CEILOMETER_DBPASS}" ]; then
    CEILOMETER_DBPASS=`$PSWDGEN`
    CEILOMETER_PASS=`$PSWDGEN`
    CEILOMETER_SECRET=`$PSWDGEN`

    if [ "${CEILOMETER_USE_MONGODB}" = "1" ]; then
	apt-get install -y mongodb-server

	sed -i -e "s/^.*bind_ip.*=.*$/bind_ip = ${MGMTIP}/" /etc/mongodb.conf

	echo "smallfiles = true" >> /etc/mongodb.conf
	service mongodb stop
	rm /var/lib/mongodb/journal/prealloc.*
	service mongodb start

	mongo --host controller --eval "
            db = db.getSiblingDB(\"ceilometer\");
            db.addUser({user: \"ceilometer\",
            pwd: \"${CEILOMETER_DBPASS}\",
            roles: [ \"readWrite\", \"dbAdmin\" ]})"
    else
	apt-get install -y mariadb-server python-mysqldb < /dev/null

	echo "create database ceilometer" | mysql -u root --password="$DB_ROOT_PASS"
	echo "grant all privileges on ceilometer.* to 'ceilometer'@'localhost' identified by '$CEILOMETER_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
	echo "grant all privileges on ceilometer.* to 'ceilometer'@'%' identified by '$CEILOMETER_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    fi

    keystone user-create --name ceilometer --pass $CEILOMETER_PASS
    keystone user-role-add --user ceilometer --tenant service --role admin
    keystone service-create --name ceilometer --type metering \
	--description "OpenStack Telemetry Service"

    keystone endpoint-create \
	--service-id $(keystone service-list | awk '/ metering / {print $2}') \
	--publicurl http://${CONTROLLER}:8777 \
	--internalurl http://${CONTROLLER}:8777 \
	--adminurl http://${CONTROLLER}:8777 \
	--region regionOne

    apt-get install -y ceilometer-api ceilometer-collector \
	ceilometer-agent-central ceilometer-agent-notification \
	ceilometer-alarm-evaluator ceilometer-alarm-notifier \
	python-ceilometerclient python-pymongo python-bson

    if [ "${CEILOMETER_USE_MONGODB}" = "1" ]; then
	sed -i -e "s/^.*connection.*=.*$/connection = mongodb:\\/\\/ceilometer:${CEILOMETER_DBPASS}@$CONTROLLER:27017\\/ceilometer/" /etc/ceilometer/ceilometer.conf
    else
	sed -i -e "s/^.*connection.*=.*$/connection = mysql:\\/\\/ceilometer:${CEILOMETER_DBPASS}@$CONTROLLER\\/ceilometer\\?charset=utf8/" /etc/ceilometer/ceilometer.conf
    fi

    # Just slap these in.
    cat <<EOF >> /etc/ceilometer/ceilometer.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER}
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
verbose = True
log_dir = /var/log/ceilometer

[keystone_authtoken]
auth_uri = http://$CONTROLLER:5000/v2.0
identity_uri = http://$CONTROLLER:35357
admin_tenant_name = service
admin_user = ceilometer
admin_password = ${CEILOMETER_PASS}

[service_credentials]
os_auth_url = http://${CONTROLLER}:5000/v2.0
os_username = ceilometer
os_tenant_name = service
os_password = ${CEILOMETER_PASS}

[publisher]
metering_secret = ${CEILOMETER_SECRET}

EOF

    sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/ceilometer/ceilometer.conf
    sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/ceilometer/ceilometer.conf
    sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/ceilometer/ceilometer.conf

    su -s /bin/sh -c "ceilometer-dbsync" ceilometer

    service ceilometer-agent-central restart
    service ceilometer-agent-notification restart
    service ceilometer-api restart
    service ceilometer-collector restart
    service ceilometer-alarm-evaluator restart
    service ceilometer-alarm-notifier restart

    echo "CEILOMETER_DBPASS=\"${CEILOMETER_DBPASS}\"" >> $SETTINGS
    echo "CEILOMETER_PASS=\"${CEILOMETER_PASS}\"" >> $SETTINGS
    echo "CEILOMETER_SECRET=\"${CEILOMETER_SECRET}\"" >> $SETTINGS
fi

#
# Install the Telemetry service on the compute nodes
#
if [ -z "${TELEMETRY_COMPUTENODES_DONE}" ]; then
    TELEMETRY_COMPUTENODES_DONE=1

    for node in $COMPUTENODES
    do
	fqdn="$node.$EEID.$EPID.$OURDOMAIN"

	# Copy the latest settings (passwords, endpoints, whatever) over
	scp -o StrictHostKeyChecking=no $SETTINGS $fqdn:$SETTINGS

	ssh -o StrictHostKeyChecking=no $fqdn $DIRNAME/setup-compute-telemetry.sh
    done

    echo "TELEMETRY_COMPUTENODES_DONE=\"${TELEMETRY_COMPUTENODES_DONE}\"" >> $SETTINGS
fi

#
# Install the Telemetry service for Glance
#
if [ -z "${TELEMETRY_GLANCE_DONE}" ]; then
    TELEMETRY_GLANCE_DONE=1

    cat <<EOF >> /etc/glance/glance-api.conf
[DEFAULT]
notification_driver = messaging
rpc_backend = rabbit
rabbit_host = ${CONTROLLER}
rabbit_password = ${RABBIT_PASS}
EOF

    service glance-registry restart
    service glance-api restart

    echo "TELEMETRY_GLANCE_DONE=\"${TELEMETRY_GLANCE_DONE}\"" >> $SETTINGS
fi

#
# Install the Telemetry service for Cinder
#
if [ -z "${TELEMETRY_CINDER_DONE}" ]; then
    TELEMETRY_CINDER_DONE=1

    cat <<EOF >> /etc/cinder/cinder.conf
[DEFAULT]
control_exchange = cinder
notification_driver = cinder.openstack.common.notifier.rpc_notifier
EOF

    service cinder-api restart
    service cinder-scheduler restart

    fqdn="$STORAGEHOST.$EEID.$EPID.$OURDOMAIN"

    if [ "${STORAGEHOST}" = "${CONTROLLER}" ]; then
	$DIRNAME/setup-storage-telemetry.sh
    else
        # Copy the latest settings (passwords, endpoints, whatever) over
	scp -o StrictHostKeyChecking=no $SETTINGS $fqdn:$SETTINGS

	ssh -o StrictHostKeyChecking=no $fqdn $DIRNAME/setup-storage-telemetry.sh
    fi

    echo "TELEMETRY_CINDER_DONE=\"${TELEMETRY_CINDER_DONE}\"" >> $SETTINGS
fi

#
# Install the Telemetry service for Swift
#
if [ -z "${TELEMETRY_SWIFT_DONE}" ]; then
    TELEMETRY_SWIFT_DONE=1

    chmod g+w /var/log/ceilometer

    apt-get install -y python-ceilometerclient

    keystone role-create --name ResellerAdmin
    keystone user-role-add --tenant service --user ceilometer \
	--role $(keystone role-list | awk '/ ResellerAdmin / {print $2}')

    cat <<EOF >> /etc/swift/proxy-server.conf
[filter:ceilometer]
use = egg:ceilometer#swift
EOF

    usermod -a -G ceilometer swift

    sed -i -e 's/^\(pipeline.*=\)\(.*\)$/\1 ceilometer \2/' /etc/swift/proxy-server.conf
    sed -i -e 's/^\(operator_roles.*=.*\)$/\1,ResellerAdmin/' /etc/swift/proxy-server.conf

    swift-init proxy-server restart

    echo "TELEMETRY_SWIFT_DONE=\"${TELEMETRY_SWIFT_DONE}\"" >> $SETTINGS
fi

#
# Get Us Some Databases!
#
if [ -z "${TROVE_DBPASS}" ]; then
    TROVE_DBPASS=`$PSWDGEN`
    TROVE_PASS=`$PSWDGEN`

    apt-get install -y python-trove python-troveclient python-glanceclient \
	trove-common trove-api trove-taskmanager

    echo "create database trove" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on trove.* to 'trove'@'localhost' identified by '$TROVE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on trove.* to 'trove'@'%' identified by '$TROVE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    keystone user-create --name trove --pass $TROVE_PASS
    keystone user-role-add --user trove --tenant service --role admin

    keystone service-create --name trove --type database \
	--description "OpenStack Database Service"

    keystone endpoint-create \
	--service-id $(keystone service-list | awk '/ trove / {print $2}') \
	--publicurl http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s \
	--internalurl http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s \
	--adminurl http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s \
	--region regionOne

    # Just slap these in.
    cat <<EOF >> /etc/trove/trove.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER}
rabbit_password = ${RABBIT_PASS}
verbose = True
log_dir = /var/log/trove
trove_auth_url = http://${CONTROLLER}:5000/v2.0
nova_compute_url = http://${CONTROLLER}:8774/v2
cinder_url = http://${CONTROLLER}:8776/v1
swift_url = http://${CONTROLLER}:8080/v1/AUTH_
sql_connection = mysql://trove:${TROVE_DBPASS}@${CONTROLLER}/trove
notifier_queue_hostname = ${CONTROLLER}
default_datastore = mysql
# Config option for showing the IP address that nova doles out
add_addresses = True
network_label_regex = ^NETWORK_LABEL$
api_paste_config = /etc/trove/api-paste.ini
EOF
    cat <<EOF >> /etc/trove/trove-taskmanager.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER}
rabbit_password = ${RABBIT_PASS}
verbose = True
log_dir = /var/log/trove
trove_auth_url = http://${CONTROLLER}:5000/v2.0
nova_compute_url = http://${CONTROLLER}:8774/v2
cinder_url = http://${CONTROLLER}:8776/v1
swift_url = http://${CONTROLLER}:8080/v1/AUTH_
sql_connection = mysql://trove:${TROVE_DBPASS}@${CONTROLLER}/trove
notifier_queue_hostname = ${CONTROLLER}
# Configuration options for talking to nova via the novaclient.
# These options are for an admin user in your keystone config.
# It proxy's the token received from the user to send to nova via this admin users creds,
# basically acting like the client via that proxy token.
nova_proxy_admin_user = admin
nova_proxy_admin_pass = ${ADMIN_PASS}
nova_proxy_admin_tenant_name = service
taskmanager_manager = trove.taskmanager.manager.Manager
EOF
    cat <<EOF >> /etc/trove/trove-conductor.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER}
rabbit_password = ${RABBIT_PASS}
verbose = True
log_dir = /var/log/trove
trove_auth_url = http://${CONTROLLER}:5000/v2.0
nova_compute_url = http://${CONTROLLER}:8774/v2
cinder_url = http://${CONTROLLER}:8776/v1
swift_url = http://${CONTROLLER}:8080/v1/AUTH_
sql_connection = mysql://trove:${TROVE_DBPASS}@${CONTROLLER}/trove
notifier_queue_hostname = ${CONTROLLER}
EOF
cat <<EOF >> /etc/trove/api-paste.ini
[filter:authtoken]
auth_uri = http://${CONTROLLER}:5000/v2.0
identity_uri = http://${CONTROLLER}:35357
admin_user = trove
admin_password = ${TROVE_PASS}
admin_tenant_name = service
signing_dir = /var/cache/trove
EOF

    sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/trove/api-paste.ini
    sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/trove/api-paste.ini
    sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/trove/api-paste.ini

    mkdir -p /var/cache/trove
    chown -R trove:trove /var/cache/trove

    su -s /bin/sh -c "/usr/bin/trove-manage db_sync" trove

    su -s /bin/sh -c "trove-manage datastore_update mysql ''" trove

    # XXX: Create a trove image!

    # trove-manage --config-file /etc/trove/trove.conf datastore_version_update \
    #    mysql mysql-5.5 mysql $glance_image_ID mysql-server-5.5 1

    service trove-api restart
    service trove-taskmanager restart
    service trove-conductor restart

    echo "TROVE_DBPASS=\"${TROVE_DBPASS}\"" >> $SETTINGS
    echo "TROVE_PASS=\"${TROVE_PASS}\"" >> $SETTINGS
fi

#
# Get some Data Processors!
#
if [ -z "${SAHARA_DBPASS}" ]; then
    SAHARA_DBPASS=`$PSWDGEN`
    SAHARA_PASS=`$PSWDGEN`

    echo "create database sahara" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on sahara.* to 'sahara'@'localhost' identified by '$SAHARA_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on sahara.* to 'sahara'@'%' identified by '$SAHARA_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    keystone user-create --name sahara --pass $SAHARA_PASS
    keystone user-role-add --user sahara --tenant service --role admin

    keystone service-create --name sahara --type data_processing \
	--description "OpenStack Data Processing Service"
    keystone endpoint-create \
	--service-id $(keystone service-list | awk '/ sahara / {print $2}') \
	--publicurl http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s \
	--internalurl http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s \
	--adminurl http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s \
	--region regionOne


    # XXX: http://askubuntu.com/questions/555093/openstack-juno-sahara-data-processing-on-14-04
    apt-get install -y python-pip
    # sahara deps
    apt-get install -y python-eventlet python-flask python-oslo.serialization
    pip install sahara

    mkdir -p /etc/sahara
    sed -i -e "s/^.*connection.*=.*$/connection = mysql:\\/\\/sahara:${SAHARA_DBPASS}@$CONTROLLER\\/sahara/" /etc/sahara/sahara.conf
    # Just slap these in.
    cat <<EOF >> /etc/sahara/sahara.conf
[DEFAULT]
verbose = True
auth_strategy = keystone
use_neutron=true

[keystone_authtoken]
auth_uri = http://$CONTROLLER:5000/v2.0
identity_uri = http://$CONTROLLER:35357
admin_tenant_name = service
admin_user = sahara
admin_password = ${SAHARA_PASS}

[ec2authtoken]
auth_uri = http://${CONTROLLER}:5000/v2.0
EOF

    sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/sahara/sahara.conf
    sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/sahara/sahara.conf
    sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/sahara/sahara.conf

    sahara-db-manage --config-file /etc/sahara/sahara.conf upgrade head

    mkdir -p /var/log/sahara

    #pkill sahara-all
    pkill sahara-engine
    pkill sahara-api

    sahara-api >>/var/log/sahara/sahara-api.log 2>&1 &
    sahara-engine >>/var/log/sahara/sahara-engine.log 2>&1 &
    #sahara-all >>/var/log/sahara/sahara-all.log 2>&1 &

    echo "SAHARA_DBPASS=\"${SAHARA_DBPASS}\"" >> $SETTINGS
    echo "SAHARA_PASS=\"${SAHARA_PASS}\"" >> $SETTINGS
fi

#
# Setup some basic images and networks
#
if [ -z "${SETUP_BASIC_DONE}" ]; then
    $DIRNAME/setup-basic.sh
    echo "SETUP_BASIC_DONE=\"1\"" >> $SETTINGS
fi

echo "***"
echo "*** Done with OpenStack Setup!"
echo "***"
echo "*** Login to your shiny new cloud at "
echo "  http://$CONTROLLER.$EEID.$EPID.${OURDOMAIN}/horizon/auth/login/?next=/horizon/project/instances/ !"
echo "***"

echo "Your OpenStack instance has completed setup!  Browse to http://$CONTROLLER.$EEID.$EPID.${OURDOMAIN}/horizon/auth/login/?next=/horizon/project/instances/ ." \
    |  mail -s "OpenStack Instance Finished Setting Up" ${SWAPPER_EMAIL}

exit 0
