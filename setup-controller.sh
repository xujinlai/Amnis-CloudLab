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
$APTGETINSTALL dma
echo "Your OpenStack instance is setting up on `hostname` ." \
    |  mail -s "OpenStack Instance Setting Up" ${SWAPPER_EMAIL} &

#
# Install the database
#
if [ -z "${DB_ROOT_PASS}" ]; then
    $APTGETINSTALL mariadb-server python-mysqldb
    service_stop mysql
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
    service_restart mysql
    service_enable mysql
    # Save the passwd
    echo "DB_ROOT_PASS=\"${DB_ROOT_PASS}\"" >> $SETTINGS
fi

#
# Install a message broker
#
if [ -z "${RABBIT_PASS}" ]; then
    $APTGETINSTALL rabbitmq-server

    service_restart rabbitmq-server
    service_enable rabbitmq-server
    rabbitmqctl start_app
    while [ ! $? -eq 0 ]; do
	sleep 1
	rabbitmqctl start_app
    done

    cat <<EOF > /etc/rabbitmq/rabbitmq.config
[
 {rabbit,
  [
   {loopback_users, []}
  ]}
]
.
EOF

    if [ ${OSCODENAME} = "juno" ]; then
	RABBIT_USER="guest"
    else
	RABBIT_USER="openstack"
	rabbitmqctl add_vhost /
    fi
    RABBIT_PASS=`$PSWDGEN`
    rabbitmqctl change_password $RABBIT_USER $RABBIT_PASS
    if [ ! $? -eq 0 ]; then
	rabbitmqctl add_user ${RABBIT_USER} ${RABBIT_PASS}
	rabbitmqctl set_permissions ${RABBIT_USER} ".*" ".*" ".*"
    fi
    # Save the passwd
    echo "RABBIT_USER=\"${RABBIT_USER}\"" >> $SETTINGS
    echo "RABBIT_PASS=\"${RABBIT_PASS}\"" >> $SETTINGS

    rabbitmqctl stop_app
    service_restart rabbitmq-server
    rabbitmqctl start_app
    while [ ! $? -eq 0 ]; do
	sleep 1
	rabbitmqctl start_app
    done
fi

#
# Install the Identity Service
#
if [ -z "${KEYSTONE_DBPASS}" ]; then
    KEYSTONE_DBPASS=`$PSWDGEN`
    echo "create database keystone" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on keystone.* to 'keystone'@'localhost' identified by '$KEYSTONE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on keystone.* to 'keystone'@'%' identified by '$KEYSTONE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    $APTGETINSTALL keystone python-keystoneclient

    ADMIN_TOKEN=`$PSWDGEN`

    sed -i -e "s/^.*admin_token.*=.*$/admin_token=$ADMIN_TOKEN/" /etc/keystone/keystone.conf
    sed -i -e "s/^.*connection.*=.*$/connection=mysql:\\/\\/keystone:${KEYSTONE_DBPASS}@$CONTROLLER\\/keystone/" /etc/keystone/keystone.conf
    sed -i -e "s/^.*provider=.*$/provider=keystone.token.providers.uuid.Provider/" /etc/keystone/keystone.conf
    sed -i -e "s/^.*driver=keystone.token.*$/driver=keystone.token.persistence.backends.sql.Token/" /etc/keystone/keystone.conf

    crudini --set /etc/keystone/keystone.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/keystone/keystone.conf DEFAULT debug ${DEBUG_LOGGING}

    su -s /bin/sh -c "/usr/bin/keystone-manage db_sync" keystone

    service_restart keystone
    service_enable keystone
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

    if [ "x${ADMIN_PASS}" = "x" ]; then
        # Create the admin user -- temporarily use the random one for
	# ${ADMIN_API}; we change it right away below manually via sql
	keystone user-create --name admin --pass ${ADMIN_API_PASS} \
	    --email "${SWAPPER_EMAIL}"
    else
	keystone user-create --name admin --pass ${ADMIN_PASS} \
	    --email "${SWAPPER_EMAIL}"
    fi
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


    if [ "x${ADMIN_PASS}" = "x" ]; then
        #
        # Update the admin user with the passwd hash from our config
        #
	echo "update user set password='${ADMIN_PASS_HASH}' where name='admin'" \
	    | mysql -u root --password=${DB_ROOT_PASS} keystone
    fi

    # Create the adminapi user
    keystone user-create --name ${ADMIN_API} --pass ${ADMIN_API_PASS} \
	--email "${SWAPPER_EMAIL}"
    keystone user-role-add --tenant admin --user ${ADMIN_API} --role admin
    keystone user-role-add --tenant admin --user ${ADMIN_API} --role _member_

    unset OS_SERVICE_TOKEN OS_SERVICE_ENDPOINT

    sed -i -e "s/^.*admin_token.*$/#admin_token =/" /etc/keystone/keystone.conf

    # Save the passwd
    echo "ADMIN_API=\"${ADMIN_API}\"" >> $SETTINGS
    echo "ADMIN_API_PASS=\"${ADMIN_API_PASS}\"" >> $SETTINGS
    echo "KEYSTONE_DBPASS=\"${KEYSTONE_DBPASS}\"" >> $SETTINGS
fi

#
# From here on out, we need to be the adminapi user.
#
export OS_TENANT_NAME=admin
export OS_USERNAME=${ADMIN_API}
export OS_PASSWORD=${ADMIN_API_PASS}
export OS_AUTH_URL=http://$CONTROLLER:35357/v2.0

echo "export OS_TENANT_NAME=admin" > $OURDIR/admin-openrc.sh
echo "export OS_USERNAME=${ADMIN_API}" >> $OURDIR/admin-openrc.sh
echo "export OS_PASSWORD=${ADMIN_API_PASS}" >> $OURDIR/admin-openrc.sh
echo "export OS_AUTH_URL=http://$CONTROLLER:35357/v2.0" >> $OURDIR/admin-openrc.sh

echo "OS_TENANT_NAME=\"admin\"" > $OURDIR/admin-openrc.py
echo "OS_USERNAME=\"${ADMIN_API}\"" >> $OURDIR/admin-openrc.py
echo "OS_PASSWORD=\"${ADMIN_API_PASS}\"" >> $OURDIR/admin-openrc.py
echo "OS_AUTH_URL=\"http://$CONTROLLER:35357/v2.0\"" >> $OURDIR/admin-openrc.py

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

    $APTGETINSTALL glance python-glanceclient

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
    crudini --set /etc/glance/glance-api.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/glance/glance-api.conf DEFAULT debug ${DEBUG_LOGGING}

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
    crudini --set /etc/glance/glance-registry.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/glance/glance-registry.conf DEFAULT debug ${DEBUG_LOGGING}

    su -s /bin/sh -c "/usr/bin/glance-manage db_sync" glance

    service_restart glance-registry
    service_enable glance-registry
    service_restart glance-api
    service_enable glance-api
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
    $APTGETINSTALL nova-api

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

    $APTGETINSTALL nova-api nova-cert nova-conductor nova-consoleauth \
	nova-novncproxy nova-scheduler python-novaclient

    if [ ${ENABLE_NEW_SERIAL_SUPPORT} = 1 ]; then
	$APTGETINSTALL nova-serialproxy
	mkdir -p $OURDIR/src
	( cd $OURDIR/src && git clone https://github.com/larsks/novaconsole )
	( cd $OURDIR/src && git clone https://github.com/liris/websocket-client )
	cat <<EOF > $OURDIR/novaconsole.sh
#!/bin/sh
source $OURDIR/admin-openrc.sh
export PYTHONPATH=$OURDIR/src/websocket-client:$OURDIR/src/novaconsole
exec $OURDIR/src/novaconsole/novaconsole/main.py $@
EOF
	chmod ug+x $OURDIR/novaconsole.sh
    fi

    # Just slap these in.
    cat <<EOF >> /etc/nova/nova.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = $CONTROLLER
rabbit_userid = ${RABBIT_USER}
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
my_ip = ${MGMTIP}
vncserver_listen = ${MGMTIP}
vncserver_proxyclient_address = ${MGMTIP}
verbose = ${VERBOSE_LOGGING}
debug = ${DEBUG_LOGGING}

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

    if [ ${ENABLE_NEW_SERIAL_SUPPORT} = 1 ]; then
	cat <<EOF >> /etc/nova/nova.conf
[serial_console]
enabled = true
EOF
    fi

    su -s /bin/sh -c "nova-manage db sync" nova

    service_restart nova-api
    service_enable nova-api
    service_restart nova-cert
    service_enable nova-cert
    service_restart nova-consoleauth
    service_enable nova-consoleauth
    service_restart nova-scheduler
    service_enable nova-scheduler
    service_restart nova-conductor
    service_enable nova-conductor
    service_restart nova-novncproxy
    service_enable nova-novncproxy
    service_restart nova-serialproxy
    service_enable nova-serialproxy

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
	fqdn=`getfqdn $node`

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

    . $OURDIR/info.neutron

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

    $APTGETINSTALL neutron-server neutron-plugin-ml2 python-neutronclient

    #
    # Install a patch to make manual router interfaces less likely to hijack
    # public addresses.  Ok, forget it, this patch would just have to set the
    # gateway, not create an "internal" interface.
    #
    #if [ ${OSCODENAME} = "kilo" ]; then
    #	patch -d / -p0 < $DIRNAME/etc/neutron-interface-add.patch.patch
    #fi

    service_tenant_id=`keystone tenant-get service | grep id | cut -d '|' -f 3`

sed -i -e "s/^\\(.*connection.*=.*\\)$/#\1/" /etc/neutron/neutron.conf
sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/neutron/neutron.conf
sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/neutron/neutron.conf
sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/neutron/neutron.conf

    cat <<EOF >> /etc/neutron/neutron.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = $CONTROLLER
rabbit_userid = ${RABBIT_USER}
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
my_ip = ${MGMTIP}
vncserver_listen = ${MGMTIP}
vncserver_proxyclient_address = ${MGMTIP}
verbose = ${VERBOSE_LOGGING}
debug = ${DEBUG_LOGGING}
core_plugin = ml2
service_plugins = router,metering
allow_overlapping_ips = True
notify_nova_on_port_status_changes = True
notify_nova_on_port_data_changes = True
nova_url = http://$CONTROLLER:8774/v2
nova_admin_auth_url = http://$CONTROLLER:35357/v2.0
nova_region_name = regionOne
nova_admin_username = nova
nova_admin_tenant_id = ${service_tenant_id}
nova_admin_password = ${NOVA_PASS}
notification_driver = messagingv2

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

fwdriver="neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver"
if [ ${DISABLE_SECURITY_GROUPS} -eq 1 ]; then
    fwdriver="neutron.agent.firewall.NoopFirewallDriver"
fi

    cat <<EOF >> /etc/neutron/plugins/ml2/ml2_conf.ini
[ml2]
type_drivers = ${network_types}
tenant_network_types = ${network_types}
mechanism_drivers = openvswitch

[ml2_type_flat]
flat_networks = ${flat_networks}

[ml2_type_gre]
tunnel_id_ranges = 1:1000

[ml2_type_vlan]
${network_vlan_ranges}

[ml2_type_vxlan]
vni_ranges = 3000:4000
#vxlan_group = 224.0.0.1

[securitygroup]
enable_security_group = True
enable_ipset = True
firewall_driver = $fwdriver
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

    su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade ${OSCODENAME}" neutron

    service_restart nova-api
    service_restart nova-scheduler
    service_restart nova-conductor
    service_restart neutron-server
    service_enable neutron-server

    echo "NEUTRON_DBPASS=\"${NEUTRON_DBPASS}\"" >> $SETTINGS
    echo "NEUTRON_PASS=\"${NEUTRON_PASS}\"" >> $SETTINGS
    echo "NEUTRON_METADATA_SECRET=\"${NEUTRON_METADATA_SECRET}\"" >> $SETTINGS
fi

#
# Install the Network service on the networkmanager
#
if [ -z "${NEUTRON_NETWORKMANAGER_DONE}" ]; then
    NEUTRON_NETWORKMANAGER_DONE=1

    fqdn=`getfqdn $NETWORKMANAGER`

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
	fqdn=`getfqdn $node`

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

    if [ "$OSCODENAME" = "kilo" ]; then
	neutron net-create ext-net --shared --router:external \
	    --provider:physical_network external --provider:network_type flat
    else
	neutron net-create ext-net --shared --router:external True \
	    --provider:physical_network external --provider:network_type flat
    fi

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

    $APTGETINSTALL openstack-dashboard apache2 libapache2-mod-wsgi memcached python-memcache

    sed -i -e "s/OPENSTACK_HOST.*=.*\$/OPENSTACK_HOST = \"${CONTROLLER}\"/" \
	/etc/openstack-dashboard/local_settings.py
    sed -i -e 's/^.*ALLOWED_HOSTS = \[.*$/ALLOWED_HOSTS = \["*"\]/' \
	/etc/openstack-dashboard/local_settings.py

    service_restart apache2
    service_enable apache2
    service_restart memcached
    service_enable memcached

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

#    if [ $OSCODENAME = 'juno' ]; then
	keystone endpoint-create \
	    --service-id `keystone service-list | awk '/ volume / {print $2}'` \
	    --publicurl http://${CONTROLLER}:8776/v1/%\(tenant_id\)s \
	    --internalurl http://${CONTROLLER}:8776/v1/%\(tenant_id\)s \
	    --adminurl http://${CONTROLLER}:8776/v1/%\(tenant_id\)s \
	    --region regionOne
#    else
#	# Kilo uses the v2 endpoint even for v1 service
#	keystone endpoint-create \
#	    --service-id `keystone service-list | awk '/ volume / {print $2}'` \
#	    --publicurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
#	    --internalurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
#	    --adminurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
#	    --region regionOne
 #   fi

    keystone endpoint-create \
	--service-id `keystone service-list | awk '/ volumev2 / {print $2}'` \
	--publicurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
	--internalurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
	--adminurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
	--region regionOne

    $APTGETINSTALL cinder-api cinder-scheduler python-cinderclient

    sed -i -e "s/^\\(.*volume_group.*=.*\\)$/#\1/" /etc/cinder/cinder.conf

    # Just slap these in.
    cat <<EOF >> /etc/cinder/cinder.conf
[database]
connection = mysql://cinder:${CINDER_DBPASS}@$CONTROLLER/cinder

[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER}
rabbit_userid = ${RABBIT_USER}
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
my_ip = ${MGMTIP}
verbose = ${VERBOSE_LOGGING}
debug = ${DEBUG_LOGGING}
glance_host = ${CONTROLLER}
volume_group = openstack-volumes
EOF

    if [ $OSCODENAME = 'juno' ] ; then
	cat <<EOF >> /etc/cinder/cinder.conf
[keystone_authtoken]
auth_uri = http://$CONTROLLER:5000/v2.0
identity_uri = http://$CONTROLLER:35357
admin_tenant_name = service
admin_user = cinder
admin_password = ${CINDER_PASS}
EOF
    else
	cat <<EOF >> /etc/cinder/cinder.conf
[keystone_authtoken]
auth_uri = http://$CONTROLLER:5000
auth_url = http://$CONTROLLER:35357
auth_plugin = password
project_domain_id = default
user_domain_id = default
project_name = service
username = cinder
password = ${CINDER_PASS}
EOF
    fi

    sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/cinder/cinder.conf
    sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/cinder/cinder.conf
    sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/cinder/cinder.conf

    su -s /bin/sh -c "/usr/bin/cinder-manage db sync" cinder

    service_restart cinder-scheduler
    service_enable cinder-scheduler
    service_restart cinder-api
    service_enable cinder-api
    service_restart cinder-volume
    service_enable cinder-volume
    rm -f /var/lib/cinder/cinder.sqlite

    echo "CINDER_DBPASS=\"${CINDER_DBPASS}\"" >> $SETTINGS
    echo "CINDER_PASS=\"${CINDER_PASS}\"" >> $SETTINGS
fi

if [ -z "${STORAGE_HOST_DONE}" ]; then
    fqdn=`getfqdn $STORAGEHOST`

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
	--publicurl http://${CONTROLLER}:8080/v1/AUTH_%\(tenant_id\)s \
	--internalurl http://${CONTROLLER}:8080/v1/AUTH_%\(tenant_id\)s \
	--adminurl http://${CONTROLLER}:8080 \
	--region regionOne

    $APTGETINSTALL swift swift-proxy python-swiftclient \
	python-keystoneclient python-keystonemiddleware memcached

    mkdir -p /etc/swift

    wget -O /etc/swift/proxy-server.conf \
	"https://git.openstack.org/cgit/openstack/swift/plain/etc/proxy-server.conf-sample?h=stable/${OSCODENAME}"

    # Just slap these in.
    crudini --set /etc/swift/proxy-server.conf DEFAULT bind_port 8080
    crudini --set /etc/swift/proxy-server.conf DEFAULT user swift
    crudini --set /etc/swift/proxy-server.conf DEFAULT swift_dir /etc/swift

    pipeline=`crudini --get /etc/swift/proxy-server.conf pipeline:main pipeline`
    if [ "$OSCODENAME" = "juno" ]; then
	crudini --set /etc/swift/proxy-server.conf pipeline:main pipeline \
	    'cache authtoken healthcheck keystoneauth proxy-logging proxy-server'
    else
	crudini --set /etc/swift/proxy-server.conf pipeline:main pipeline \
	    'catch_errors gatekeeper healthcheck proxy-logging cache container_sync bulk ratelimit authtoken keystoneauth container-quotas account-quotas slo dlo proxy-logging proxy-server'
    fi

    crudini --set /etc/swift/proxy-server.conf \
	app:proxy-server allow_account_management true
    crudini --set /etc/swift/proxy-server.conf \
	app:proxy-server account_autocreate true

    crudini --set /etc/swift/proxy-server.conf \
	filter:keystoneauth use 'egg:swift#keystoneauth'
    if [ "$OSCODENAME" = "juno" ]; then
	crudini --set /etc/swift/proxy-server.conf \
	    filter:keystoneauth operator_roles 'admin,_member_'
    else
	crudini --set /etc/swift/proxy-server.conf \
	    filter:keystoneauth operator_roles 'admin,user'
    fi

    crudini --set /etc/swift/proxy-server.conf \
	filter:authtoken paste.filter_factory keystonemiddleware.auth_token:filter_factory
    if [ "$OSCODENAME" = "juno" ]; then
	crudini --set /etc/swift/proxy-server.conf \
	    auth_uri "http://${CONTROLLER}:5000/v2.0"
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken identity_url "http://${CONTROLLER}:35357"
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken admin_tenant_name service
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken admin_user swift
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken admin_password "${SWIFT_PASS}"
    else
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken auth_uri "http://${CONTROLLER}:5000"
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken auth_url "http://${CONTROLLER}:35357"
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken auth_plugin password
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken project_domain_id default
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken user_domain_id default
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken project_name service
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken username swift
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken password "${SWIFT_PASS}"
    fi
    crudini --set /etc/swift/proxy-server.conf \
	filter:authtoken delay_auth_decision true

    crudini --set /etc/swift/proxy-server.conf \
	filter:cache memcache_servers 127.0.0.1:11211

    sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/swift/proxy-server.conf
    sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/swift/proxy-server.conf
    sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/swift/proxy-server.conf

    mkdir -p /var/log/swift
    chown -R syslog.adm /var/log/swift

    crudini --set /etc/swift/proxy-server.conf DEFAULT log_facility LOG_LOCAL1
    crudini --set /etc/swift/proxy-server.conf DEFAULT log_level INFO
    crudini --set /etc/swift/proxy-server.conf DEFAULT log_name swift-proxy

    echo 'if $programname == "swift-proxy" then { action(type="omfile" file="/var/log/swift/swift-proxy.log") }' >> /etc/rsyslog.d/99-swift.conf

    wget -O /etc/swift/swift.conf \
	"https://git.openstack.org/cgit/openstack/swift/plain/etc/swift.conf-sample?h=stable/${OSCODENAME}"

    crudini --set /etc/swift/swift.conf \
	swift-hash swift_hash_path_suffix "${SWIFT_HASH_PATH_PREFIX}"
    crudini --set /etc/swift/swift.conf \
	swift-hash swift_hash_path_prefix "${SWIFT_HASH_PATH_SUFFIX}"
    crudini --set /etc/swift/swift.conf \
	storage-policy:0 name "Policy-0"
    crudini --set /etc/swift/swift.conf \
	storage-policy:0 default yes

    chown -R swift:swift /etc/swift

    service_restart memcached
    service_restart rsyslog
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	swift-init proxy-server restart
    else
	systemctl restart swift-proxy.service
    fi
    service_enable swift-proxy

    echo "SWIFT_PASS=\"${SWIFT_PASS}\"" >> $SETTINGS
    echo "SWIFT_HASH_PATH_PREFIX=\"${SWIFT_HASH_PATH_PREFIX}\"" >> $SETTINGS
    echo "SWIFT_HASH_PATH_SUFFIX=\"${SWIFT_HASH_PATH_SUFFIX}\"" >> $SETTINGS
fi

if [ -z "${OBJECT_HOST_DONE}" ]; then
    fqdn=`getfqdn $OBJECTHOST`

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
	add r1z1-${objip}:6002/swiftv1 100
    swift-ring-builder account.builder rebalance

    swift-ring-builder container.builder create 10 3 1
    swift-ring-builder container.builder \
	add r1z1-${objip}:6001/swiftv1 100
    swift-ring-builder container.builder rebalance

    swift-ring-builder object.builder create 10 3 1
    swift-ring-builder object.builder \
	add r1z1-${objip}:6000/swiftv1 100
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

    $APTGETINSTALL heat-api heat-api-cfn heat-engine python-heatclient

    sed -i -e "s/^.*connection.*=.*$/connection = mysql:\\/\\/heat:${HEAT_DBPASS}@$CONTROLLER\\/heat/" /etc/heat/heat.conf
    # Just slap these in.
    cat <<EOF >> /etc/heat/heat.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER}
rabbit_userid = ${RABBIT_USER}
rabbit_password = ${RABBIT_PASS}
heat_metadata_server_url = http://${CONTROLLER}:8000
heat_waitcondition_server_url = http://${CONTROLLER}:8000/v1/waitcondition
verbose = ${VERBOSE_LOGGING}
debug = ${DEBUG_LOGGING}
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

    service_restart heat-api
    service_enable heat-api
    service_restart heat-api-cfn
    service_enable heat-api-cfn
    service_restart heat-engine
    service_enable heat-engine

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
	$APTGETINSTALL mongodb-server python-pymongo

	sed -i -e "s/^.*bind_ip.*=.*$/bind_ip = ${MGMTIP}/" /etc/mongodb.conf

	echo "smallfiles = true" >> /etc/mongodb.conf
	service_stop mongodb
	rm /var/lib/mongodb/journal/prealloc.*
	service_start mongodb
	service_enable mongodb

	MDONE=1
	while [ $MDONE -ne 0 ]; do 
	    sleep 1
	    mongo --host ${CONTROLLER} --eval "db = db.getSiblingDB(\"ceilometer\"); db.addUser({user: \"ceilometer\", pwd: \"${CEILOMETER_DBPASS}\", roles: [ \"readWrite\", \"dbAdmin\" ]})"
	    MDONE=$?
	done
    else
	$APTGETINSTALL mariadb-server python-mysqldb

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

    $APTGETINSTALL ceilometer-api ceilometer-collector \
	ceilometer-agent-central ceilometer-agent-notification \
	ceilometer-alarm-evaluator ceilometer-alarm-notifier \
	python-ceilometerclient python-bson

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
rabbit_userid = ${RABBIT_USER}
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
verbose = ${VERBOSE_LOGGING}
debug = ${DEBUG_LOGGING}
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

[notification]
store_events = true
disable_non_metric_meters = false
EOF

    if [ "${OSCODENAME}" = "juno" ]; then
	cat <<EOF >> /etc/ceilometer/ceilometer.conf

[publisher]
metering_secret = ${CEILOMETER_SECRET}
EOF
    else
	cat <<EOF >> /etc/ceilometer/ceilometer.conf

[service_credentials]
os_endpoint_type = internalURL
os_region_name = regionOne

[publisher]
telemetry_secret = ${CEILOMETER_SECRET}
EOF
    fi

    sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/ceilometer/ceilometer.conf
    sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/ceilometer/ceilometer.conf
    sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/ceilometer/ceilometer.conf

    if [ ! -e /etc/ceilometer/event_pipeline.yaml ]; then
	cat <<EOF > /etc/ceilometer/event_pipeline.yaml
sources:
    - name: event_source
      events:
          - "*"
      sinks:
          - event_sink
sinks:
    - name: event_sink
      transformers:
      triggers:
      publishers:
          - notifier://
EOF
    fi

    su -s /bin/sh -c "ceilometer-dbsync" ceilometer

    service_restart ceilometer-agent-central
    service_enable ceilometer-agent-central
    service_restart ceilometer-agent-notification
    service_enable ceilometer-agent-notification
    service_restart ceilometer-api
    service_enable ceilometer-api
    service_restart ceilometer-collector
    service_enable ceilometer-collector
    service_restart ceilometer-alarm-evaluator
    service_enable ceilometer-alarm-evaluator
    service_restart ceilometer-alarm-notifier
    service_enable ceilometer-alarm-notifier

    # NB: restart the neutron ceilometer agent too
    fqdn=`getfqdn $NETWORKMANAGER`
    ssh -o StrictHostKeyChecking=no $fqdn service neutron-metering-agent restart

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
	fqdn=`getfqdn $node`

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
notification_driver = messagingv2
rpc_backend = rabbit
rabbit_host = ${CONTROLLER}
rabbit_userid = ${RABBIT_USER}
rabbit_password = ${RABBIT_PASS}
EOF

    cat <<EOF >> /etc/glance/glance-registry.conf
[DEFAULT]
notification_driver = messagingv2
rpc_backend = rabbit
rabbit_host = ${CONTROLLER}
rabbit_userid = ${RABBIT_USER}
rabbit_password = ${RABBIT_PASS}
EOF

    service_restart glance-registry
    service_restart glance-api

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
notification_driver = messagingv2
EOF

    service_restart cinder-api
    service_restart cinder-scheduler

    fqdn=`getfqdn $STORAGEHOST`

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

    $APTGETINSTALL python-ceilometerclient

    keystone role-create --name ResellerAdmin
    keystone user-role-add --tenant service --user ceilometer \
	--role $(keystone role-list | awk '/ ResellerAdmin / {print $2}')

    cat <<EOF >> /etc/swift/proxy-server.conf
[filter:ceilometer]
use = egg:ceilometer#swift
EOF

    if [ "${OSCODENAME}" = "kilo" ]; then
	cat <<EOF >> /etc/swift/proxy-server.conf
[filter:ceilometer]
paste.filter_factory = ceilometermiddleware.swift:filter_factory
control_exchange = swift
url = rabbit://${RABBIT_USER}:${RABBIT_PASS}@${CONTROLLER}:5672/
driver = messagingv2
topic = notifications
log_level = WARN
EOF
    fi

    usermod -a -G ceilometer swift

    sed -i -e 's/^\(pipeline.*=\)\(.*\)$/\1 ceilometer \2/' /etc/swift/proxy-server.conf
    sed -i -e 's/^\(operator_roles.*=.*\)$/\1,ResellerAdmin/' /etc/swift/proxy-server.conf

    service_restart swift-proxy
    #swift-init proxy-server restart

    echo "TELEMETRY_SWIFT_DONE=\"${TELEMETRY_SWIFT_DONE}\"" >> $SETTINGS
fi

#
# Get Us Some Databases!
#
if [ -z "${TROVE_DBPASS}" ]; then
    TROVE_DBPASS=`$PSWDGEN`
    TROVE_PASS=`$PSWDGEN`

    # trove on Ubuntu Vivid was broken at the time this was done...
    $APTGETINSTALL trove-common
    if [ ! $? -eq 0 ]; then
	touch /var/lib/trove/trove_test.sqlite
	chown trove:trove /var/lib/trove/trove_test.sqlite
	crudini --set /etc/trove/trove.conf database connection sqlite:////var/lib/trove/trove_test.sqlite
	$APTGETINSTALL trove-common
    fi

    $APTGETINSTALL python-trove python-troveclient python-glanceclient \
	trove-api trove-taskmanager trove-conductor

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
rabbit_userid = ${RABBIT_USER}
rabbit_password = ${RABBIT_PASS}
verbose = ${VERBOSE_LOGGING}
debug = ${DEBUG_LOGGING}
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
taskmanager_manager = trove.taskmanager.manager.Manager
EOF
    cat <<EOF >> /etc/trove/trove-taskmanager.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER}
rabbit_userid = ${RABBIT_USER}
rabbit_password = ${RABBIT_PASS}
verbose = ${VERBOSE_LOGGING}
debug = ${DEBUG_LOGGING}
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
nova_proxy_admin_user = ${ADMIN_API}
nova_proxy_admin_pass = ${ADMIN_API_PASS}
nova_proxy_admin_tenant_name = service
taskmanager_manager = trove.taskmanager.manager.Manager
EOF
    cat <<EOF >> /etc/trove/trove-conductor.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER}
rabbit_userid = ${RABBIT_USER}
rabbit_password = ${RABBIT_PASS}
verbose = ${VERBOSE_LOGGING}
debug = ${DEBUG_LOGGING}
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

    crudini --set /etc/trove/trove.conf \
	database connection mysql://trove:${TROVE_DBPASS}@${CONTROLLER}/trove
    crudini --set /etc/trove/trove-taskmanager.conf \
	database connection mysql://trove:${TROVE_DBPASS}@${CONTROLLER}/trove
    crudini --set /etc/trove/trove-conductor.conf \
	database connection mysql://trove:${TROVE_DBPASS}@${CONTROLLER}/trove

    sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/trove/api-paste.ini
    sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/trove/api-paste.ini
    sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/trove/api-paste.ini

    mkdir -p /var/cache/trove
    chown -R trove:trove /var/cache/trove

    su -s /bin/sh -c "/usr/bin/trove-manage db_sync" trove
    if [ ! $? -eq 0 ]; then
	#
        # Try disabling foreign_key_checks, sigh
        #
	echo "set global foreign_key_checks=0;" | mysql -u root --password="$DB_ROOT_PASS" trove
	su -s /bin/sh -c "/usr/bin/trove-manage db_sync" trove
	echo "set global foreign_key_checks=1;" | mysql -u root --password="$DB_ROOT_PASS" trove
    fi

    su -s /bin/sh -c "trove-manage datastore_update mysql ''" trove

    # XXX: Create a trove image!

    # trove-manage --config-file /etc/trove/trove.conf datastore_version_update \
    #    mysql mysql-5.5 mysql $glance_image_ID mysql-server-5.5 1

    service_restart trove-api
    service_enable trove-api
    service_restart trove-taskmanager
    service_enable trove-taskmanager
    service_restart trove-conductor
    service_enable trove-conductor

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

    aserr=0
    apt-cache search ^sahara\$ | grep -q ^sahara\$
    APT_HAS_SAHARA=$?

    if [ ${APT_HAS_SAHARA} -eq 0 ]; then
        # XXX: http://askubuntu.com/questions/555093/openstack-juno-sahara-data-processing-on-14-04
	$APTGETINSTALL python-pip
        # sahara deps
	$APTGETINSTALL python-eventlet python-flask python-oslo.serialization
	pip install sahara
    else
	# This may fail because sahara's migration scripts use ALTER TABLE,
        # which sqlite doesn't support
	$APTGETINSTALL sahara-common 
	aserr=$?
	$APTGETINSTALL sahara-api sahara-engine
    fi

    mkdir -p /etc/sahara
    touch /etc/sahara/sahara.conf
    chown -R sahara /etc/sahara
    crudini --set /etc/sahara/sahara.conf \
	database connection mysql://sahara:${SAHARA_DBPASS}@$CONTROLLER/sahara
    # Just slap these in.
    cat <<EOF >> /etc/sahara/sahara.conf
[DEFAULT]
verbose = ${VERBOSE_LOGGING}
debug = ${DEBUG_LOGGING}
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

    # If the apt-get install had failed, do it again so that the configure
    # step can succeed ;)
    if [ ! $aserr -eq 0 ]; then
	$APTGETINSTALL sahara-common sahara-api sahara-engine
    fi

    sahara-db-manage --config-file /etc/sahara/sahara.conf upgrade head

    mkdir -p /var/log/sahara

    if [ ${APT_HAS_SAHARA} -eq 0 ]; then
        #pkill sahara-all
	pkill sahara-engine
	pkill sahara-api

	sahara-api >>/var/log/sahara/sahara-api.log 2>&1 &
	sahara-engine >>/var/log/sahara/sahara-engine.log 2>&1 &
        #sahara-all >>/var/log/sahara/sahara-all.log 2>&1 &
    else
	service_restart sahara-api
	service_enable sahara-api
	service_restart sahara-engine
	service_enable sahara-engine
    fi

    echo "SAHARA_DBPASS=\"${SAHARA_DBPASS}\"" >> $SETTINGS
    echo "SAHARA_PASS=\"${SAHARA_PASS}\"" >> $SETTINGS
fi

#
# (Maybe) Install Ironic
#
if [ 0 = 1 -a "$OSCODENAME" = "kilo" -a -n "$BAREMETALNODES" -a -z "${IRONIC_DBPASS}" ]; then
    IRONIC_DBPASS=`$PSWDGEN`
    IRONIC_PASS=`$PSWDGEN`

    echo "create database ironic character set utf8" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on ironic.* to 'ironic'@'localhost' identified by '$IRONIC_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on ironic.* to 'ironic'@'%' identified by '$IRONIC_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    keystone user-create --name ironic --pass $IRONIC_PASS
    keystone user-role-add --user ironic --tenant service --role admin

    keystone service-create --name ironic --type baremetal \
	--description "OpenStack Bare Metal Provisioning Service"
    keystone endpoint-create \
	--service-id $(keystone service-list | awk '/ ironic / {print $2}') \
	--publicurl http://${CONTROLLER}:6385 \
	--internalurl http://${CONTROLLER}:6385 \
	--adminurl http://${CONTROLLER}:6385 \
	--region regionOne

    $APTGETINSTALL ironic-api ironic-conductor python-ironicclient python-ironic

    crudini --set /etc/ironic/ironic.conf \
	database connection "mysql://ironic:${IRONIC_DBPASS}@$CONTROLLER/ironic?charset=utf8"

    crudini --set /etc/ironic/ironic.conf DEFAULT rabbit_host $CONTROLLER
    crudini --set /etc/ironic/ironic.conf DEFAULT rabbit_userid ${RABBIT_USER}
    crudini --set /etc/ironic/ironic.conf DEFAULT rabbit_password ${RABBIT_PASS}

    crudini --set /etc/ironic/ironic.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/ironic/ironic.conf DEFAULT debug ${DEBUG_LOGGING}

    crudini --set /etc/ironic/ironic.conf DEFAULT auth_strategy keystone
    crudini --set /etc/ironic/ironic.conf \
	keystone_authtoken auth_uri "http://$CONTROLLER:5000/"
    crudini --set /etc/ironic/ironic.conf \
	keystone_authtoken identity_uri "http://$CONTROLLER:35357"
    crudini --set /etc/ironic/ironic.conf \
	keystone_authtoken admin_user ironic
    crudini --set /etc/ironic/ironic.conf \
	keystone_authtoken admin_password ${IRONIC_PASS}
    crudini --set /etc/ironic/ironic.conf \
	keystone_authtoken admin_tenant_name service

    crudini --del /etc/ironic/ironic.conf keystone_authtoken auth_host
    crudini --del /etc/ironic/ironic.conf keystone_authtoken auth_port
    crudini --del /etc/ironic/ironic.conf keystone_authtoken auth_protocol

    crudini --set /etc/ironic/ironic.conf neutron url "http://$CONTROLLER:9696"

    crudini --set /etc/ironic/ironic.conf glance glance_host $CONTROLLER

    su -s /bin/sh -c "ironic-dbsync --config-file /etc/ironic/ironic.conf create_schema" ironic

    service_restart ironic-api
    service_enable ironic-api
    service_restart ironic-conductor
    service_enable ironic-conductor

    echo "IRONIC_DBPASS=\"${IRONIC_DBPASS}\"" >> $SETTINGS
    echo "IRONIC_PASS=\"${IRONIC_PASS}\"" >> $SETTINGS
fi

#
# Setup some basic images and networks
#
if [ -z "${SETUP_BASIC_DONE}" ]; then
    $DIRNAME/setup-basic.sh
    echo "SETUP_BASIC_DONE=\"1\"" >> $SETTINGS
fi

RANDPASSSTRING=""
if [ -e $OURDIR/rand_admin_pass ]; then
    RANDPASSSTRING="We generated a random OpenStack admin and instance VM password for you, since one wasn't supplied.  The password is '${ADMIN_PASS}'"
fi

echo "***"
echo "*** Done with OpenStack Setup!"
echo "***"
echo "*** Login to your shiny new cloud at "
echo "  http://$CONTROLLER.$EEID.$EPID.${OURDOMAIN}/horizon/auth/login/?next=/horizon/project/instances/ !  ${RANDPASSSTRING}"
echo "***"



echo "Your OpenStack instance has completed setup!  Browse to http://$CONTROLLER.$EEID.$EPID.${OURDOMAIN}/horizon/auth/login/?next=/horizon/project/instances/ .  ${RANDPASSSTRING}" \
    |  mail -s "OpenStack Instance Finished Setting Up" ${SWAPPER_EMAIL}

exit 0
