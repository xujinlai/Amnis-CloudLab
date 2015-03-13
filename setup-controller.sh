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

HOSTNAME=`hostname -s`
if [ "$HOSTNAME" != "$CONTROLLER" ]; then
    exit 0;
fi

#
# Give the controller a root login on all the machines
#
$DIRNAME/setup-root-ssh.sh

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

# Make sure our repos are setup.
#apt-get install ubuntu-cloud-keyring
#echo "deb http://ubuntu-cloud.archive.canonical.com/ubuntu" \
#    "trusty-updates/juno main" > /etc/apt/sources.list.d/cloudarchive-juno.list

#sudo add-apt-repository ppa:ubuntu-cloud-archive/juno-staging 

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
    echo "bind-address = 192.168.0.3" >> /etc/mysql/my.cnf
    echo "default-storage-engine = innodb" >> /etc/mysql/my.cnf
    echo "innodb_file_per_table" >> /etc/mysql/my.cnf
    echo "collation-server = utf8_general_ci" >> /etc/mysql/my.cnf
    echo "init-connect = 'SET NAMES utf8'" >> /etc/mysql/my.cnf
    echo "character-set-server = utf8" >> /etc/mysql/my.cnf
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
my_ip = 192.168.0.3
vncserver_listen = 192.168.0.3
vncserver_proxyclient_address = 192.168.0.3
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
my_ip = 192.168.0.3
vncserver_listen = 192.168.0.3
vncserver_proxyclient_address = 192.168.0.3
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
    mynet=`ip route show dev ${EXTERNAL_NETWORK_INTERFACE} | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\/[0-9]*\) .*$/\1/p'`

    neutron subnet-create ext-net --name ext-subnet \
	--allocation-pool start=${EXT_FLOAT_IP_START},end=${EXT_FLOAT_IP_END} \
	--disable-dhcp --gateway $mygw $mynet

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
# Setup some basic images and networks
#
$DIRNAME/setup-basic.sh

exit 0
