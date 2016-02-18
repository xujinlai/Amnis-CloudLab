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

#
# openstack CLI commands seem flakey sometimes on Kilo and Liberty.
# Don't know if it's WSGI, mysql dropping connections, an NTP
# thing... but until it gets solved more permanently, have to retry :(.
#
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

# Make sure our repos are setup.
#apt-get install ubuntu-cloud-keyring
#echo "deb http://ubuntu-cloud.archive.canonical.com/ubuntu" \
#    "trusty-updates/juno main" > /etc/apt/sources.list.d/cloudarchive-juno.list

#sudo add-apt-repository ppa:ubuntu-cloud-archive/juno-staging 

#
# Setup mail to users
#
maybe_install_packages dma
echo "$PFQDN" > /etc/mailname
sleep 2
echo "Your OpenStack instance is setting up on `hostname` ." \
    |  mail -s "OpenStack Instance Setting Up" ${SWAPPER_EMAIL} &

#
# If we're >= Kilo, we might need the openstack CLI command.
#
if [ $OSVERSION -ge $OSKILO ]; then
    maybe_install_packages python-openstackclient
fi

#
# This is a nasty bug in oslo_service; see 
# https://review.openstack.org/#/c/256267/
#
if [ $OSVERSION -ge $OSKILO ]; then
    maybe_install_packages python-oslo.service
    patch -d / -p0 < $DIRNAME/etc/oslo_service-liberty-sig-MAINLOOP.patch
fi

#
# Install the database
#
if [ -z "${DB_ROOT_PASS}" ]; then
    maybe_install_packages mariadb-server python-mysqldb
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
    maybe_install_packages rabbitmq-server

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
# If Keystone API Version v3, we have to supply a --domain sometimes.
#
DOMARG=""
#if [ $OSVERSION -gt $OSKILO ]; then
if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
    DOMARG="--domain default"
fi

#
# Install the Identity Service
#
if [ -z "${KEYSTONE_DBPASS}" ]; then
    KEYSTONE_DBPASS=`$PSWDGEN`
    echo "create database keystone" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on keystone.* to 'keystone'@'localhost' identified by '$KEYSTONE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on keystone.* to 'keystone'@'%' identified by '$KEYSTONE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    maybe_install_packages keystone python-keystoneclient
    if [ $OSVERSION -ge $OSKILO ]; then
	maybe_install_packages memcached python-memcache apache2
    fi

    ADMIN_TOKEN=`$PSWDGEN`

    crudini --set /etc/keystone/keystone.conf DEFAULT admin_token "$ADMIN_TOKEN"
    crudini --set /etc/keystone/keystone.conf database connection \
	"mysql://keystone:${KEYSTONE_DBPASS}@$CONTROLLER/keystone"

    crudini --set /etc/keystone/keystone.conf token expiration ${TOKENTIMEOUT}

    if [ $OSVERSION -le $OSJUNO ]; then
	crudini --set /etc/keystone/keystone.conf token provider \
	    'keystone.token.providers.uuid.Provider'
	crudini --set /etc/keystone/keystone.conf token driver \
	    'keystone.token.persistence.backends.sql.Token'
    elif [ $OSVERSION -le $OSKILO ]; then
	crudini --set /etc/keystone/keystone.conf token provider \
	    'keystone.token.providers.uuid.Provider'
	crudini --set /etc/keystone/keystone.conf revoke driver \
	    'keystone.contrib.revoke.backends.sql.Revoke'
	if [ $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	    crudini --set /etc/keystone/keystone.conf token driver \
		'keystone.token.persistence.backends.memcache.Token'
	    crudini --set /etc/keystone/keystone.conf memcache servers \
		'localhost:11211'
	else
	    crudini --set /etc/keystone/keystone.conf token driver \
		'keystone.token.persistence.backends.sql.Token'
	fi
    else
	crudini --set /etc/keystone/keystone.conf token provider 'uuid'
	crudini --set /etc/keystone/keystone.conf revoke driver 'sql'
	if [ $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	    crudini --set /etc/keystone/keystone.conf token driver 'memcache'
	    crudini --set /etc/keystone/keystone.conf memcache servers \
		'localhost:11211'
	else
	    crudini --set /etc/keystone/keystone.conf token driver 'sql'
	fi
    fi

    crudini --set /etc/keystone/keystone.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/keystone/keystone.conf DEFAULT debug ${DEBUG_LOGGING}

    su -s /bin/sh -c "/usr/bin/keystone-manage db_sync" keystone

    if [ $OSVERSION -eq $OSKILO ]; then
	cat <<EOF >/etc/apache2/sites-available/wsgi-keystone.conf
Listen 5000
Listen 35357

<VirtualHost *:5000>
    WSGIDaemonProcess keystone-public processes=5 threads=1 user=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-public
    WSGIScriptAlias / /var/www/cgi-bin/keystone/main
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
      ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    LogLevel info
    ErrorLog /var/log/apache2/keystone-error.log
    CustomLog /var/log/apache2/keystone-access.log combined
</VirtualHost>

<VirtualHost *:35357>
    WSGIDaemonProcess keystone-admin processes=5 threads=1 user=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-admin
    WSGIScriptAlias / /var/www/cgi-bin/keystone/admin
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
      ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    LogLevel info
    ErrorLog /var/log/apache2/keystone-error.log
    CustomLog /var/log/apache2/keystone-access.log combined
</VirtualHost>
EOF

	ln -s /etc/apache2/sites-available/wsgi-keystone.conf \
	    /etc/apache2/sites-enabled

	mkdir -p /var/www/cgi-bin/keystone
	wget -O /var/www/cgi-bin/keystone/admin "http://git.openstack.org/cgit/openstack/keystone/plain/httpd/keystone.py?h=stable/${OSCODENAME}"
	cp -p /var/www/cgi-bin/keystone/admin /var/www/cgi-bin/keystone/main 
	chown -R keystone:keystone /var/www/cgi-bin/keystone
	chmod 755 /var/www/cgi-bin/keystone/*
    elif [ $OSVERSION -ge $OSLIBERTY ]; then
	cat <<EOF >/etc/apache2/sites-available/wsgi-keystone.conf
Listen 5000
Listen 35357

<VirtualHost *:5000>
    WSGIDaemonProcess keystone-public processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-public
    WSGIScriptAlias / /usr/bin/keystone-wsgi-public
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
      ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    ErrorLog /var/log/apache2/keystone.log
    CustomLog /var/log/apache2/keystone_access.log combined

    <Directory /usr/bin>
        <IfVersion >= 2.4>
            Require all granted
        </IfVersion>
        <IfVersion < 2.4>
            Order allow,deny
            Allow from all
        </IfVersion>
    </Directory>
</VirtualHost>

<VirtualHost *:35357>
    WSGIDaemonProcess keystone-admin processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-admin
    WSGIScriptAlias / /usr/bin/keystone-wsgi-admin
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
      ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    ErrorLog /var/log/apache2/keystone.log
    CustomLog /var/log/apache2/keystone_access.log combined

    <Directory /usr/bin>
        <IfVersion >= 2.4>
            Require all granted
        </IfVersion>
        <IfVersion < 2.4>
            Order allow,deny
            Allow from all
        </IfVersion>
    </Directory>
</VirtualHost>
EOF

	ln -s /etc/apache2/sites-available/wsgi-keystone.conf \
	    /etc/apache2/sites-enabled
    fi

    if [ $OSVERSION -le $OSJUNO ]; then
	service_restart keystone
	service_enable keystone
    else
	service_stop keystone
	service_disable keystone

	service_restart apache2
	service_enable apache2
    fi
    rm -f /var/lib/keystone/keystone.db

    sleep 8

    # optional of course
    (crontab -l -u keystone 2>&1 | grep -q token_flush) || \
        echo '@hourly /usr/bin/keystone-manage token_flush >/var/log/keystone/keystone-tokenflush.log 2>&1' \
        >> /var/spool/cron/crontabs/keystone

    # Create admin token
    if [ $OSVERSION -lt $OSKILO ]; then
	export OS_SERVICE_TOKEN=$ADMIN_TOKEN
	export OS_SERVICE_ENDPOINT=http://$CONTROLLER:35357/$KAPISTR
    else
	export OS_TOKEN=$ADMIN_TOKEN
	export OS_URL=http://$CONTROLLER:35357/$KAPISTR

	if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
	    export OS_IDENTITY_API_VERSION=3
	else
	    export OS_IDENTITY_API_VERSION=2.0
	fi
    fi

    if [ $OSVERSION -lt $OSKILO ]; then
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
            --region $REGION
    else
	__openstack service create \
	    --name keystone --description "OpenStack Identity" identity

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://${CONTROLLER}:5000/${KAPISTR} \
		--internalurl http://${CONTROLLER}:5000/${KAPISTR} \
		--adminurl http://${CONTROLLER}:35357/${KAPISTR} \
		--region $REGION identity
	else
	    __openstack endpoint create --region $REGION \
		identity public http://${CONTROLLER}:5000/${KAPISTR}
	    __openstack endpoint create --region $REGION \
		identity internal http://${CONTROLLER}:5000/${KAPISTR}
	    __openstack endpoint create --region $REGION \
		identity admin http://${CONTROLLER}:35357/${KAPISTR}
	fi
    fi

    if [ "x${ADMIN_PASS}" = "x" ]; then
        # Create the admin user -- temporarily use the random one for
        # ${ADMIN_API}; we change it right away below manually via sql
	APSWD="${ADMIN_API_PASS}"
    else
	APSWD="${ADMIN_PASS}"
    fi

    if [ $OSVERSION -eq $OSJUNO ]; then
        # Create the admin tenant
	keystone tenant-create --name admin --description "Admin Tenant"
	keystone user-create --name admin --pass "${APSWD}" \
	    --email "${SWAPPER_EMAIL}"
        # Create the admin role
	keystone role-create --name admin
        # Add the admin tenant and user to the admin role:
	keystone user-role-add --tenant admin --user admin --role admin
        # Create the _member_ role:
	keystone role-create --name _member_
        # Add the admin tenant and user to the _member_ role:
	keystone user-role-add --tenant admin --user admin --role _member_

        # Create the adminapi user
	keystone user-create --name ${ADMIN_API} --pass ${ADMIN_API_PASS} \
	    --email "${SWAPPER_EMAIL}"
	keystone user-role-add --tenant admin --user ${ADMIN_API} --role admin
	keystone user-role-add --tenant admin --user ${ADMIN_API} --role _member_
    else
	__openstack project create $DOMARG --description "Admin Project" admin
	__openstack user create $DOMARG --password "${APSWD}" \
	    --email "${SWAPPER_EMAIL}" admin
	__openstack role create admin
	__openstack role add --project admin --user admin admin

	__openstack role create user
	__openstack role add --project admin --user admin user

	__openstack project create $DOMARG --description "Service Project" service

        # Create the adminapi user
	__openstack user create $DOMARG --password ${ADMIN_API_PASS} \
	    --email "${SWAPPER_EMAIL}" ${ADMIN_API}
	__openstack role add --project admin --user ${ADMIN_API} admin
	__openstack role add --project admin --user ${ADMIN_API} user
    fi


    if [ "x${ADMIN_PASS}" = "x" ]; then
        #
        # Update the admin user with the passwd hash from our config
        #
	echo "update user set password='${ADMIN_PASS_HASH}' where name='admin'" \
	    | mysql -u root --password=${DB_ROOT_PASS} keystone
    fi

    if [ $OSVERSION -lt $OSKILO ]; then
	unset OS_SERVICE_TOKEN OS_SERVICE_ENDPOINT
    else
	unset OS_TOKEN OS_URL
	unset OS_IDENTITY_API_VERSION
    fi

    crudini --del /etc/keystone/keystone.conf DEFAULT admin_token

    # Save the passwd
    echo "ADMIN_API=\"${ADMIN_API}\"" >> $SETTINGS
    echo "ADMIN_API_PASS=\"${ADMIN_API_PASS}\"" >> $SETTINGS
    echo "KEYSTONE_DBPASS=\"${KEYSTONE_DBPASS}\"" >> $SETTINGS
fi

#
# Create the admin-openrc.{sh,py} files.
#
echo "export OS_TENANT_NAME=admin" > $OURDIR/admin-openrc-oldcli.sh
echo "export OS_USERNAME=${ADMIN_API}" >> $OURDIR/admin-openrc-oldcli.sh
echo "export OS_PASSWORD=${ADMIN_API_PASS}" >> $OURDIR/admin-openrc-oldcli.sh
echo "export OS_AUTH_URL=http://$CONTROLLER:35357/v2.0" >> $OURDIR/admin-openrc-oldcli.sh

echo "OS_TENANT_NAME=\"admin\"" > $OURDIR/admin-openrc-oldcli.py
echo "OS_USERNAME=\"${ADMIN_API}\"" >> $OURDIR/admin-openrc-oldcli.py
echo "OS_PASSWORD=\"${ADMIN_API_PASS}\"" >> $OURDIR/admin-openrc-oldcli.py
echo "OS_AUTH_URL=\"http://$CONTROLLER:35357/v2.0\"" >> $OURDIR/admin-openrc-oldcli.py
if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
    echo "OS_IDENTITY_API_VERSION=3" >> $OURDIR/admin-openrc-oldcli.py
else
    echo "OS_IDENTITY_API_VERSION=2.0" >> $OURDIR/admin-openrc-oldcli.py
fi

#
# These trigger a bug with the openstack client -- it doesn't choose v2.0
# if they're set.
#
if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
    echo "export OS_PROJECT_DOMAIN_ID=default" > $OURDIR/admin-openrc-newcli.sh
    echo "export OS_USER_DOMAIN_ID=default" >> $OURDIR/admin-openrc-newcli.sh
fi
echo "export OS_PROJECT_NAME=admin" >> $OURDIR/admin-openrc-newcli.sh
echo "export OS_TENANT_NAME=admin" >> $OURDIR/admin-openrc-newcli.sh
echo "export OS_USERNAME=${ADMIN_API}" >> $OURDIR/admin-openrc-newcli.sh
echo "export OS_PASSWORD=${ADMIN_API_PASS}" >> $OURDIR/admin-openrc-newcli.sh
echo "export OS_AUTH_URL=http://$CONTROLLER:35357/${KAPISTR}" >> $OURDIR/admin-openrc-newcli.sh
if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
    echo "export OS_IDENTITY_API_VERSION=3" >> $OURDIR/admin-openrc-newcli.sh
else
    echo "export OS_IDENTITY_API_VERSION=2.0" >> $OURDIR/admin-openrc-newcli.sh
fi
if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
    echo "OS_PROJECT_DOMAIN_ID=\"default\"" > $OURDIR/admin-openrc-newcli.py
    echo "OS_USER_DOMAIN_ID=\"default\"" >> $OURDIR/admin-openrc-newcli.py
fi
echo "OS_PROJECT_NAME=\"admin\"" >> $OURDIR/admin-openrc-newcli.py
echo "OS_TENANT_NAME=\"admin\"" >> $OURDIR/admin-openrc-newcli.py
echo "OS_USERNAME=\"${ADMIN_API}\"" >> $OURDIR/admin-openrc-newcli.py
echo "OS_PASSWORD=\"${ADMIN_API_PASS}\"" >> $OURDIR/admin-openrc-newcli.py
echo "OS_AUTH_URL=\"http://$CONTROLLER:35357/${KAPISTR}\"" >> $OURDIR/admin-openrc-newcli.py
if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
    echo "OS_IDENTITY_API_VERSION=3" >> $OURDIR/admin-openrc-newcli.py
else
    echo "OS_IDENTITY_API_VERSION=2.0" >> $OURDIR/admin-openrc-newcli.py
fi

#
# From here on out, we need to be the adminapi user.
#
if [ $OSVERSION -eq $OSJUNO ]; then
    export OS_TENANT_NAME=admin
    export OS_USERNAME=${ADMIN_API}
    export OS_PASSWORD=${ADMIN_API_PASS}
    export OS_AUTH_URL=http://$CONTROLLER:35357/${KAPISTR}

    ln -sf $OURDIR/admin-openrc-oldcli.sh $OURDIR/admin-openrc.sh
    ln -sf $OURDIR/admin-openrc-oldcli.py $OURDIR/admin-openrc.py
else
    if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
	export OS_PROJECT_DOMAIN_ID=default
	export OS_USER_DOMAIN_ID=default
    fi
    export OS_PROJECT_NAME=admin
    export OS_TENANT_NAME=admin
    export OS_USERNAME=${ADMIN_API}
    export OS_PASSWORD=${ADMIN_API_PASS}
    export OS_AUTH_URL=http://${CONTROLLER}:35357/${KAPISTR}
    if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
	export OS_IDENTITY_API_VERSION=3
    else
	export OS_IDENTITY_API_VERSION=2.0
    fi

    ln -sf $OURDIR/admin-openrc-newcli.sh $OURDIR/admin-openrc.sh
    ln -sf $OURDIR/admin-openrc-newcli.py $OURDIR/admin-openrc.py
fi

#
# Install the Image service
#
if [ -z "${GLANCE_DBPASS}" ]; then
    GLANCE_DBPASS=`$PSWDGEN`
    GLANCE_PASS=`$PSWDGEN`

    echo "create database glance" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on glance.* to 'glance'@'localhost' identified by '$GLANCE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on glance.* to 'glance'@'%' identified by '$GLANCE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    if [ $OSVERSION -lt $OSKILO ]; then
	keystone user-create --name glance --pass $GLANCE_PASS
	keystone user-role-add --user glance --tenant service --role admin
	keystone service-create --name glance --type image \
	    --description "OpenStack Image Service"

	keystone endpoint-create \
	    --service-id `keystone service-list | awk '/ image / {print $2}'` \
	    --publicurl http://$CONTROLLER:9292 \
	    --internalurl http://$CONTROLLER:9292 \
	    --adminurl http://$CONTROLLER:9292 \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $GLANCE_PASS glance
	__openstack role add --user glance --project service admin
	__openstack service create --name glance \
	    --description "OpenStack Image Service" image

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://$CONTROLLER:9292 \
		--internalurl http://$CONTROLLER:9292 \
		--adminurl http://$CONTROLLER:9292 \
		--region $REGION image
	else
	    __openstack endpoint create --region $REGION \
		image public http://$CONTROLLER:9292
	    __openstack endpoint create --region $REGION \
		image internal http://$CONTROLLER:9292
	    __openstack endpoint create --region $REGION \
		image admin http://$CONTROLLER:9292
	fi
    fi

    maybe_install_packages glance python-glanceclient

    crudini --set /etc/glance/glance-api.conf database connection \
	"mysql://glance:${GLANCE_DBPASS}@$CONTROLLER/glance"
    #crudini --set /etc/glance/glance-api.conf DEFAULT rpc_backend rabbit
    crudini --set /etc/glance/glance-api.conf DEFAULT auth_strategy keystone
    crudini --set /etc/glance/glance-api.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/glance/glance-api.conf DEFAULT debug ${DEBUG_LOGGING}
    crudini --set /etc/glance/glance-api.conf paste_deploy flavor keystone

    if [ $OSVERSION -eq $OSJUNO ]; then
	#crudini --set /etc/glance/glance-api.conf DEFAULT rabbit_host $CONTROLLER
	#crudini --set /etc/glance/glance-api.conf DEFAULT rabbit_userid ${RABBIT_USER}
	#crudini --set /etc/glance/glance-api.conf DEFAULT rabbit_password "${RABBIT_PASS}"

	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    identity_uri http://${CONTROLLER}:35357
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    admin_tenant_name service
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    admin_user glance
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    admin_password "${GLANCE_PASS}"
    else
	#crudini --set /etc/glance/glance-api.conf oslo_messaging_rabbit \
	#    rabbit_host $CONTROLLER
	#crudini --set /etc/glance/glance-api.conf oslo_messaging_rabbit \
	#    rabbit_userid ${RABBIT_USER}
	#crudini --set /etc/glance/glance-api.conf oslo_messaging_rabbit \
	#    rabbit_password "${RABBIT_PASS}"

	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    auth_plugin password
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    project_domain_id default
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    user_domain_id default
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    project_name service
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    username glance
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    password "${GLANCE_PASS}"
	crudini --set /etc/glance/glance-api.conf glance_store default_store file
	crudini --set /etc/glance/glance-api.conf glance_store \
	    filesystem_store_datadir /var/lib/glance/images/
	crudini --set /etc/glance/glance-api.conf DEFAULT notification_driver noop
    fi

    crudini --set /etc/glance/glance-registry.conf database \
	connection "mysql://glance:${GLANCE_DBPASS}@$CONTROLLER/glance"
    #crudini --set /etc/glance/glance-registry.conf DEFAULT rpc_backend rabbit
    crudini --set /etc/glance/glance-registry.conf DEFAULT auth_strategy keystone
    crudini --set /etc/glance/glance-registry.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/glance/glance-registry.conf DEFAULT debug ${DEBUG_LOGGING}
    crudini --set /etc/glance/glance-registry.conf paste_deploy flavor keystone

    if [ $OSVERSION -eq $OSJUNO ]; then
	#crudini --set /etc/glance/glance-registry.conf DEFAULT rabbit_host $CONTROLLER
	#crudini --set /etc/glance/glance-registry.conf DEFAULT rabbit_userid ${RABBIT_USER}
	#crudini --set /etc/glance/glance-registry.conf DEFAULT rabbit_password "${RABBIT_PASS}"

	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    identity_uri http://${CONTROLLER}:35357
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    admin_tenant_name service
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    admin_user glance
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    admin_password "${GLANCE_PASS}"
    else
	#crudini --set /etc/glance/glance-registry.conf oslo_messaging_rabbit \
	#    rabbit_host $CONTROLLER
	#crudini --set /etc/glance/glance-registry.conf oslo_messaging_rabbit \
	#    rabbit_userid ${RABBIT_USER}
	#crudini --set /etc/glance/glance-registry.conf oslo_messaging_rabbit \
	#    rabbit_password "${RABBIT_PASS}"

	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    auth_plugin password
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    project_domain_id default
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    user_domain_id default
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    project_name service
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    username glance
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    password "${GLANCE_PASS}"
	crudini --set /etc/glance/glance-registry.conf DEFAULT notification_driver noop
    fi

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
    maybe_install_packages nova-api

    echo "create database nova" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on nova.* to 'nova'@'localhost' identified by '$NOVA_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on nova.* to 'nova'@'%' identified by '$NOVA_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    if [ $OSVERSION -eq $OSJUNO ]; then
	keystone user-create --name nova --pass $NOVA_PASS
	keystone user-role-add --user nova --tenant service --role admin
	keystone service-create --name nova --type compute \
	    --description "OpenStack Compute Service"
	keystone endpoint-create \
	    --service-id `keystone service-list | awk '/ compute / {print $2}'` \
	    --publicurl http://$CONTROLLER:8774/v2/%\(tenant_id\)s \
	    --internalurl http://$CONTROLLER:8774/v2/%\(tenant_id\)s \
	    --adminurl http://$CONTROLLER:8774/v2/%\(tenant_id\)s \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $NOVA_PASS nova
	__openstack role add --user nova --project service admin
	__openstack service create --name nova \
	    --description "OpenStack Compute Service" compute

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://$CONTROLLER:8774/v2/%\(tenant_id\)s \
		--internalurl http://$CONTROLLER:8774/v2/%\(tenant_id\)s \
		--adminurl http://$CONTROLLER:8774/v2/%\(tenant_id\)s \
		--region $REGION compute
	else
	    __openstack endpoint create --region $REGION \
		compute public http://${CONTROLLER}:8774/v2/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		compute internal http://${CONTROLLER}:8774/v2/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		compute admin http://${CONTROLLER}:8774/v2/%\(tenant_id\)s
	fi
    fi

    maybe_install_packages nova-api nova-cert nova-conductor nova-consoleauth \
	nova-novncproxy nova-scheduler python-novaclient

    if [ ${ENABLE_NEW_SERIAL_SUPPORT} = 1 ]; then
	maybe_install_packages nova-serialproxy
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

    crudini --set /etc/nova/nova.conf database connection \
	"mysql://nova:$NOVA_DBPASS@$CONTROLLER/nova"
    crudini --set /etc/nova/nova.conf DEFAULT rpc_backend rabbit
    crudini --set /etc/nova/nova.conf DEFAULT auth_strategy keystone
    crudini --set /etc/nova/nova.conf DEFAULT my_ip ${MGMTIP}
    crudini --set /etc/nova/nova.conf glance host $CONTROLLER
    crudini --set /etc/nova/nova.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/nova/nova.conf DEFAULT debug ${DEBUG_LOGGING}

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/nova/nova.conf DEFAULT rabbit_host $CONTROLLER
	crudini --set /etc/nova/nova.conf DEFAULT rabbit_userid ${RABBIT_USER}
	crudini --set /etc/nova/nova.conf DEFAULT rabbit_password "${RABBIT_PASS}"

	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    identity_uri http://${CONTROLLER}:35357
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    admin_tenant_name service
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    admin_user nova
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    admin_password "${NOVA_PASS}"
    else
	crudini --set /etc/nova/nova.conf oslo_messaging_rabbit \
	    rabbit_host $CONTROLLER
	crudini --set /etc/nova/nova.conf oslo_messaging_rabbit \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/nova/nova.conf oslo_messaging_rabbit \
	    rabbit_password "${RABBIT_PASS}"

	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    auth_plugin password
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    project_domain_id default
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    user_domain_id default
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    project_name service
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    username nova
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    password "${NOVA_PASS}"
    fi

    if [ $OSVERSION -lt $OSLIBERTY ]; then
	crudini --set /etc/nova/nova.conf DEFAULT vncserver_listen ${MGMTIP}
	crudini --set /etc/nova/nova.conf DEFAULT vncserver_proxyclient_address ${MGMTIP}
    else
	crudini --set /etc/nova/nova.conf vnc vncserver_listen ${MGMTIP}
	crudini --set /etc/nova/nova.conf vnc vncserver_proxyclient_address ${MGMTIP}
    fi

    #
    # Apparently on Kilo and before, the default filters did not include
    # DiskFilter, but in Liberty it does.  This causes us problems for
    # our small root partition :).
    #
    if [ $OSVERSION -eq $OSKILO ]; then
	crudini --set /etc/nova/nova.conf DEFAULT scheduler_available_filters \
	    nova.scheduler.filters.all_filters
	crudini --set /etc/nova/nova.conf DEFAULT scheduler_default_filters \
	    'RetryFilter, AvailabilityZoneFilter, RamFilter, ComputeFilter, ComputeCapabilitiesFilter, ImagePropertiesFilter, ServerGroupAntiAffinityFilter, ServerGroupAffinityFilter'
    elif [ $OSVERSION -ge $OSLIBERTY ]; then
	crudini --set /etc/nova/nova.conf DEFAULT scheduler_available_filters \
	    nova.scheduler.filters.all_filters
	crudini --set /etc/nova/nova.conf DEFAULT scheduler_default_filters \
	    'RetryFilter, AvailabilityZoneFilter, RamFilter, ComputeFilter, ComputeCapabilitiesFilter, ImagePropertiesFilter, ServerGroupAntiAffinityFilter, ServerGroupAffinityFilter'
    fi

    if [ $OSVERSION -ge $OSKILO ]; then
	crudini --set /etc/nova/nova.conf oslo_concurrency \
	    lock_path /var/lib/nova/tmp
    fi

    if [ ${ENABLE_NEW_SERIAL_SUPPORT} = 1 ]; then
	crudini --set /etc/nova/nova.conf serial_console enabled true
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

	touch $OURDIR/compute-done-${node}
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

    . $OURDIR/neutron.vars

    echo "create database neutron" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on neutron.* to 'neutron'@'localhost' identified by '$NEUTRON_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on neutron.* to 'neutron'@'%' identified by '$NEUTRON_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    if [ $OSVERSION -eq $OSJUNO ]; then
	keystone user-create --name neutron --pass ${NEUTRON_PASS}
	keystone user-role-add --user neutron --tenant service --role admin

	keystone service-create --name neutron --type network \
	    --description "OpenStack Networking Service"

	keystone endpoint-create \
	    --service-id `keystone service-list | awk '/ network / {print $2}'` \
	    --publicurl http://$CONTROLLER:9696 \
	    --adminurl http://$CONTROLLER:9696 \
	    --internalurl http://$CONTROLLER:9696 \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $NEUTRON_PASS neutron
	__openstack role add --user neutron --project service admin
	__openstack service create --name neutron \
	    --description "OpenStack Networking Service" network

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://${CONTROLLER}:9696 \
		--adminurl http://${CONTROLLER}:9696 \
		--internalurl http://${CONTROLLER}:9696 \
		--region $REGION network
	else
	    __openstack endpoint create --region $REGION \
		network public http://${CONTROLLER}:9696
	    __openstack endpoint create --region $REGION \
		network internal http://${CONTROLLER}:9696
	    __openstack endpoint create --region $REGION \
		network admin http://${CONTROLLER}:9696
	fi
    fi

    maybe_install_packages neutron-server neutron-plugin-ml2 python-neutronclient

    #
    # Install a patch to make manual router interfaces less likely to hijack
    # public addresses.  Ok, forget it, this patch would just have to set the
    # gateway, not create an "internal" interface.
    #
    #if [ ${OSCODENAME} = "kilo" ]; then
    #	patch -d / -p0 < $DIRNAME/etc/neutron-interface-add.patch.patch
    #fi

    crudini --set /etc/neutron/neutron.conf \
	database connection "mysql://neutron:$NEUTRON_DBPASS@$CONTROLLER/neutron"

    crudini --del /etc/neutron/neutron.conf keystone_authtoken auth_host
    crudini --del /etc/neutron/neutron.conf keystone_authtoken auth_port
    crudini --del /etc/neutron/neutron.conf keystone_authtoken auth_protocol

    crudini --set /etc/neutron/neutron.conf DEFAULT rpc_backend rabbit
    crudini --set /etc/neutron/neutron.conf DEFAULT auth_strategy keystone
    crudini --set /etc/neutron/neutron.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/neutron/neutron.conf DEFAULT debug ${DEBUG_LOGGING}
    crudini --set /etc/neutron/neutron.conf DEFAULT core_plugin ml2
    crudini --set /etc/neutron/neutron.conf DEFAULT service_plugins 'router,metering'
    crudini --set /etc/neutron/neutron.conf DEFAULT allow_overlapping_ips True

    if [ $OSVERSION -le $OSKILO ]; then
	crudini --set /etc/neutron/neutron.conf DEFAULT my_ip ${MGMTIP}
    fi

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/neutron/neutron.conf DEFAULT rabbit_host $CONTROLLER
	crudini --set /etc/neutron/neutron.conf DEFAULT rabbit_userid ${RABBIT_USER}
	crudini --set /etc/neutron/neutron.conf DEFAULT rabbit_password "${RABBIT_PASS}"

	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    identity_uri http://${CONTROLLER}:35357
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    admin_tenant_name service
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    admin_user neutron
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    admin_password "${NEUTRON_PASS}"
    else
	crudini --set /etc/neutron/neutron.conf oslo_messaging_rabbit \
	    rabbit_host $CONTROLLER
	crudini --set /etc/neutron/neutron.conf oslo_messaging_rabbit \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/neutron/neutron.conf oslo_messaging_rabbit \
	    rabbit_password "${RABBIT_PASS}"

	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    auth_plugin password
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    project_domain_id default
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    user_domain_id default
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    project_name service
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    username neutron
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    password "${NEUTRON_PASS}"
    fi

    crudini --set /etc/neutron/neutron.conf DEFAULT \
	notify_nova_on_port_status_changes True
    crudini --set /etc/neutron/neutron.conf DEFAULT \
	notify_nova_on_port_data_changes True
    crudini --set /etc/neutron/neutron.conf DEFAULT \
	nova_url http://$CONTROLLER:8774/v2

    if [ $OSVERSION -eq $OSJUNO ]; then
	service_tenant_id=`keystone tenant-get service | grep id | cut -d '|' -f 3`

	crudini --set /etc/neutron/neutron.conf DEFAULT \
	    nova_admin_auth_url http://$CONTROLLER:35357/${KAPISTR}
	crudini --set /etc/neutron/neutron.conf DEFAULT nova_region_name $REGION
	crudini --set /etc/neutron/neutron.conf DEFAULT nova_admin_username nova
	crudini --set /etc/neutron/neutron.conf DEFAULT \
	    nova_admin_tenant_id ${service_tenant_id}
	crudini --set /etc/neutron/neutron.conf DEFAULT \
	    nova_admin_password ${NOVA_PASS}
	crudini --set /etc/neutron/neutron.conf DEFAULT \
	    notification_driver = messagingv2
    else
	crudini --set /etc/neutron/neutron.conf nova \
	    auth_url http://$CONTROLLER:35357
	crudini --set /etc/neutron/neutron.conf nova auth_plugin password
	crudini --set /etc/neutron/neutron.conf nova project_domain_id default
	crudini --set /etc/neutron/neutron.conf nova user_domain_id default
	crudini --set /etc/neutron/neutron.conf nova region_name $REGION
	crudini --set /etc/neutron/neutron.conf nova project_name service
	crudini --set /etc/neutron/neutron.conf nova username nova
	crudini --set /etc/neutron/neutron.conf nova password ${NOVA_PASS}
    fi

    fwdriver="neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver"
    if [ ${DISABLE_SECURITY_GROUPS} -eq 1 ]; then
	fwdriver="neutron.agent.firewall.NoopFirewallDriver"
    fi

    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 \
	type_drivers ${network_types}
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 \
	tenant_network_types ${network_types}
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 \
	mechanism_drivers openvswitch
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_flat \
	flat_networks ${flat_networks}
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_gre \
	tunnel_id_ranges 1:1000
cat <<EOF >>/etc/neutron/plugins/ml2/ml2_conf.ini
[ml2_type_vlan]
${network_vlan_ranges}
EOF
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vxlan \
	vni_ranges 3000:4000
#    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vxlan \
#	vxlan_group 224.0.0.1
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup \
	enable_security_group True
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup \
	enable_ipset True
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup \
	firewall_driver $fwdriver

    crudini --set /etc/nova/nova.conf DEFAULT \
	network_api_class nova.network.neutronv2.api.API
    crudini --set /etc/nova/nova.conf DEFAULT \
	security_group_api neutron
    crudini --set /etc/nova/nova.conf DEFAULT \
	linuxnet_interface_driver nova.network.linux_net.LinuxOVSInterfaceDriver
    crudini --set /etc/nova/nova.conf DEFAULT \
	firewall_driver nova.virt.firewall.NoopFirewallDriver

    crudini --set /etc/nova/nova.conf neutron \
	url http://$CONTROLLER:9696
    crudini --set /etc/nova/nova.conf neutron \
	auth_strategy keystone
    if [ $OSVERSION -le $OSKILO ]; then
	crudini --set /etc/nova/nova.conf neutron \
	    admin_auth_url http://$CONTROLLER:35357/${KAPISTR}
    else
	crudini --set /etc/nova/nova.conf neutron \
	    auth_url http://$CONTROLLER:35357
    fi
    crudini --set /etc/nova/nova.conf neutron \
	admin_tenant_name service
    crudini --set /etc/nova/nova.conf neutron \
	admin_username neutron
    crudini --set /etc/nova/nova.conf neutron \
	admin_password ${NEUTRON_PASS}
    crudini --set /etc/nova/nova.conf neutron \
	service_metadata_proxy True
    crudini --set /etc/nova/nova.conf neutron \
	metadata_proxy_shared_secret ${NEUTRON_METADATA_SECRET}

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
if [ -z "${NEUTRON_NETWORKMANAGER_DONE}" -a ! "$CONTROLLER" = "$NETWORKMANAGER" ]; then
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

	touch $OURDIR/compute-network-done-${node}
    done

    echo "NEUTRON_COMPUTENODES_DONE=\"${NEUTRON_COMPUTENODES_DONE}\"" >> $SETTINGS
fi

#
# Configure the networks on the controller
#
if [ -z "${NEUTRON_NETWORKS_DONE}" ]; then
    NEUTRON_NETWORKS_DONE=1

    if [ "$OSCODENAME" = "kilo" -o "$OSCODENAME" = "liberty" ]; then
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

    maybe_install_packages openstack-dashboard apache2 libapache2-mod-wsgi memcached python-memcache

    sed -i -e "s/OPENSTACK_HOST.*=.*\$/OPENSTACK_HOST = \"${CONTROLLER}\"/" \
	/etc/openstack-dashboard/local_settings.py
    sed -i -e 's/^.*ALLOWED_HOSTS = \[.*$/ALLOWED_HOSTS = \["*"\]/' \
	/etc/openstack-dashboard/local_settings.py
    grep -q SESSION_TIMEOUT /etc/openstack-dashboard/local_settings.py
    if [ $? -eq 0 ]; then
	sed -i -e "s/^.*SESSION_TIMEOUT.*=.*\$/SESSION_TIMEOUT = ${SESSIONTIMEOUT}/" \
	    /etc/openstack-dashboard/local_settings.py
    else
	echo "SESSION_TIMEOUT = ${SESSIONTIMEOUT}" \
	    >> /etc/openstack-dashboard/local_settings.py
    fi
    grep -q OPENSTACK_KEYSTONE_DEFAULT_ROLE /etc/openstack-dashboard/local_settings.py
    if [ $? -eq 0 ]; then
	sed -i -e "s/^.*OPENSTACK_KEYSTONE_DEFAULT_ROLE.*=.*\$/OPENSTACK_KEYSTONE_DEFAULT_ROLE = \"user\"/" \
	    /etc/openstack-dashboard/local_settings.py
    else
	echo "OPENSTACK_KEYSTONE_DEFAULT_ROLE = \"user\"" \
	    >> /etc/openstack-dashboard/local_settings.py
    fi

    if [ $OSVERSION -ge $OSKILO ]; then
	cat <<EOF >> /etc/openstack-dashboard/local_settings.py
CACHES = {
    'default': {
         'BACKEND': 'django.core.cache.backends.memcached.MemcachedCache',
         'LOCATION': '127.0.0.1:11211',
    }
}
EOF
    fi

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

    if [ $OSVERSION -eq $OSJUNO ]; then
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
	    --region $REGION
#    else
#	# Kilo uses the v2 endpoint even for v1 service
#	keystone endpoint-create \
#	    --service-id `keystone service-list | awk '/ volume / {print $2}'` \
#	    --publicurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
#	    --internalurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
#	    --adminurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
#	    --region $REGION
 #   fi

        keystone endpoint-create \
	    --service-id `keystone service-list | awk '/ volumev2 / {print $2}'` \
	    --publicurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
	    --internalurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
	    --adminurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $CINDER_PASS cinder
	__openstack role add --user cinder --project service admin
	__openstack service create --name cinder \
	    --description "OpenStack Block Storage Service" volume
	__openstack service create --name cinderv2 \
	    --description "OpenStack Block Storage Service" volumev2

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
		--internalurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
		--adminurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
		--region $REGION \
		volume
	    __openstack endpoint create \
		--publicurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
		--internalurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
		--adminurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
		--region $REGION \
		volumev2
	else
	    __openstack endpoint create --region $REGION \
		volume public http://${CONTROLLER}:8776/v1/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		volume internal http://${CONTROLLER}:8776/v1/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		volume admin http://${CONTROLLER}:8776/v1/%\(tenant_id\)s

	    __openstack endpoint create --region $REGION \
		volumev2 public http://${CONTROLLER}:8776/v2/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		volumev2 internal http://${CONTROLLER}:8776/v2/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		volumev2 admin http://${CONTROLLER}:8776/v2/%\(tenant_id\)s
	fi
    fi

    maybe_install_packages cinder-api cinder-scheduler python-cinderclient

    crudini --set /etc/cinder/cinder.conf \
	database connection "mysql://cinder:$CINDER_DBPASS@$CONTROLLER/cinder"

    crudini --del /etc/cinder/cinder.conf keystone_authtoken auth_host
    crudini --del /etc/cinder/cinder.conf keystone_authtoken auth_port
    crudini --del /etc/cinder/cinder.conf keystone_authtoken auth_protocol

    crudini --set /etc/cinder/cinder.conf DEFAULT rpc_backend rabbit
    crudini --set /etc/cinder/cinder.conf DEFAULT auth_strategy keystone
    crudini --set /etc/cinder/cinder.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/cinder/cinder.conf DEFAULT debug ${DEBUG_LOGGING}
    crudini --set /etc/cinder/cinder.conf DEFAULT my_ip ${MGMTIP}

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/cinder/cinder.conf DEFAULT rabbit_host $CONTROLLER
	crudini --set /etc/cinder/cinder.conf DEFAULT rabbit_userid ${RABBIT_USER}
	crudini --set /etc/cinder/cinder.conf DEFAULT rabbit_password "${RABBIT_PASS}"

	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    identity_uri http://${CONTROLLER}:35357
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    admin_tenant_name service
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    admin_user cinder
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    admin_password "${CINDER_PASS}"
    else
	crudini --set /etc/cinder/cinder.conf oslo_messaging_rabbit \
	    rabbit_host $CONTROLLER
	crudini --set /etc/cinder/cinder.conf oslo_messaging_rabbit \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/cinder/cinder.conf oslo_messaging_rabbit \
	    rabbit_password "${RABBIT_PASS}"

	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    auth_plugin password
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    project_domain_id default
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    user_domain_id default
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    project_name service
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    username cinder
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    password "${CINDER_PASS}"
    fi

    crudini --set /etc/cinder/cinder.conf DEFAULT glance_host ${CONTROLLER}

    if [ $OSVERSION -eq $OSKILO ]; then
	crudini --set /etc/cinder/cinder.conf oslo_concurrency \
	    lock_path /var/lock/cinder
    elif [ $OSVERSION -ge $OSLIBERTY ]; then
	crudini --set /etc/cinder/cinder.conf oslo_concurrency \
	    lock_path /var/lib/cinder/tmp
    fi

    if [ $OSVERSION -ge $OSLIBERTY ]; then
	crudini --set /etc/nova/nova.conf cinder os_region_name $REGION
    fi

    sed -i -e "s/^\\(.*volume_group.*=.*\\)$/#\1/" /etc/cinder/cinder.conf

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

    if [ $OSVERSION -eq $OSJUNO ]; then
	keystone user-create --name swift --pass $SWIFT_PASS
	keystone user-role-add --user swift --tenant service --role admin
	keystone service-create --name swift --type object-store \
	    --description "OpenStack Object Storage Service"

	keystone endpoint-create \
	    --service-id `keystone service-list | awk '/ object-store / {print $2}'` \
	    --publicurl http://${CONTROLLER}:8080/v1/AUTH_%\(tenant_id\)s \
	    --internalurl http://${CONTROLLER}:8080/v1/AUTH_%\(tenant_id\)s \
	    --adminurl http://${CONTROLLER}:8080 \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $SWIFT_PASS swift
	__openstack role add --user swift --project service admin
	__openstack service create --name swift \
	    --description "OpenStack Object Storage Service" object-store

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://${CONTROLLER}:8080/v1/AUTH_%\(tenant_id\)s \
		--internalurl http://${CONTROLLER}:8080/v1/AUTH_%\(tenant_id\)s \
		--adminurl http://${CONTROLLER}:8080 \
		--region $REGION \
		object-store
	else
	    __openstack endpoint create --region $REGION \
		object-store public http://${CONTROLLER}:8080/v1/AUTH_%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		object-store internal http://${CONTROLLER}:8080/v1/AUTH_%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		object-store admin http://${CONTROLLER}:8080/v1
	fi
    fi

    maybe_install_packages swift swift-proxy python-swiftclient \
	python-keystoneclient python-keystonemiddleware memcached

    mkdir -p /etc/swift

    wget -O /etc/swift/proxy-server.conf \
	"https://git.openstack.org/cgit/openstack/swift/plain/etc/proxy-server.conf-sample?h=stable/${OSCODENAME}"
    if [ ! $? -eq 0 ]; then
	# Try the EOL version...
	wget -O /etc/swift/proxy-server.conf \
	    "https://git.openstack.org/cgit/openstack/swift/plain/etc/proxy-server.conf-sample?h=${OSCODENAME}-eol"
    fi

    # Just slap these in.
    crudini --set /etc/swift/proxy-server.conf DEFAULT bind_port 8080
    crudini --set /etc/swift/proxy-server.conf DEFAULT user swift
    crudini --set /etc/swift/proxy-server.conf DEFAULT swift_dir /etc/swift

    pipeline=`crudini --get /etc/swift/proxy-server.conf pipeline:main pipeline`
    if [ "$OSCODENAME" = "juno" ]; then
	crudini --set /etc/swift/proxy-server.conf pipeline:main pipeline \
	    'cache authtoken healthcheck keystoneauth proxy-logging proxy-server'
    elif [ $OSVERSION -eq $OSKILO ]; then
	crudini --set /etc/swift/proxy-server.conf pipeline:main pipeline \
	    'catch_errors gatekeeper healthcheck proxy-logging cache container_sync bulk ratelimit authtoken keystoneauth container-quotas account-quotas slo dlo proxy-logging proxy-server'
    else
	crudini --set /etc/swift/proxy-server.conf pipeline:main pipeline \
	    'catch_errors gatekeeper healthcheck proxy-logging cache container_sync bulk ratelimit authtoken keystoneauth container-quotas account-quotas slo dlo versioned_writes proxy-logging proxy-server'
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
	    auth_uri "http://${CONTROLLER}:5000/${KAPISTR}"
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
	filter:cache use 'egg:swift#memcache'
    crudini --set /etc/swift/proxy-server.conf \
	filter:cache memcache_servers 127.0.0.1:11211

    crudini --del /etc/swift/proxy-server.conf keystone_authtoken auth_host
    crudini --del /etc/swift/proxy-server.conf keystone_authtoken auth_port
    crudini --del /etc/swift/proxy-server.conf keystone_authtoken auth_protocol

    mkdir -p /var/log/swift
    chown -R syslog.adm /var/log/swift

    crudini --set /etc/swift/proxy-server.conf DEFAULT log_facility LOG_LOCAL1
    crudini --set /etc/swift/proxy-server.conf DEFAULT log_level INFO
    crudini --set /etc/swift/proxy-server.conf DEFAULT log_name swift-proxy

    echo 'if $programname == "swift-proxy" then { action(type="omfile" file="/var/log/swift/swift-proxy.log") }' >> /etc/rsyslog.d/99-swift.conf

    wget -O /etc/swift/swift.conf \
	"https://git.openstack.org/cgit/openstack/swift/plain/etc/swift.conf-sample?h=stable/${OSCODENAME}"
    if [ ! $? -eq 0 ]; then
	# Try the EOL version...
	wget -O /etc/swift/swift.conf \
	    "https://git.openstack.org/cgit/openstack/swift/plain/etc/swift.conf-sample?h=${OSCODENAME}-eol"
    fi

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
	service_restart swift-proxy
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
    HEAT_DOMAIN_PASS=`$PSWDGEN`

    echo "create database heat" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on heat.* to 'heat'@'localhost' identified by '$HEAT_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on heat.* to 'heat'@'%' identified by '$HEAT_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    if [ $OSVERSION -eq $OSJUNO ]; then
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
	    --region $REGION
	keystone endpoint-create \
	    --service-id $(keystone service-list | awk '/ cloudformation / {print $2}') \
	    --publicurl http://${CONTROLLER}:8000/v1 \
	    --internalurl http://${CONTROLLER}:8000/v1 \
	    --adminurl http://${CONTROLLER}:8000/v1 \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $HEAT_PASS heat
	__openstack role add --user heat --project service admin
	__openstack role create heat_stack_owner
	__openstack role create heat_stack_user
	__openstack service create --name heat \
	    --description "OpenStack Orchestration Service" orchestration
	__openstack service create --name heat-cfn \
	    --description "OpenStack Orchestration Service" cloudformation

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://$CONTROLLER:8004/v1/%\(tenant_id\)s \
		--internalurl http://$CONTROLLER:8004/v1/%\(tenant_id\)s \
		--adminurl http://$CONTROLLER:8004/v1/%\(tenant_id\)s \
		--region $REGION orchestration
	    __openstack endpoint create \
		--publicurl http://$CONTROLLER:8000/v1 \
		--internalurl http://$CONTROLLER:8000/v1 \
		--adminurl http://$CONTROLLER:8000/v1 \
		--region RegionOne \
		cloudformation
	else
	    __openstack endpoint create --region $REGION \
		orchestration public http://${CONTROLLER}:8004/v1/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		orchestration internal http://${CONTROLLER}:8004/v1/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		orchestration admin http://${CONTROLLER}:8004/v1/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		cloudformation public http://${CONTROLLER}:8000/v1
	    __openstack endpoint create --region $REGION \
		cloudformation internal http://${CONTROLLER}:8000/v1
	    __openstack endpoint create --region $REGION \
		cloudformation admin http://${CONTROLLER}:8000/v1

	    __openstack domain create --description "Stack projects and users" heat
	    __openstack user create --domain heat \
		--password $HEAT_DOMAIN_PASS heat_domain_admin
	    __openstack role add --domain heat --user heat_domain_admin admin
	    # Do this for admin, not demo, for now
	    __openstack role add --project admin --user admin heat_stack_owner
	fi
    fi

    maybe_install_packages heat-api heat-api-cfn heat-engine python-heatclient

    crudini --set /etc/heat/heat.conf database \
	connection "mysql://heat:${HEAT_DBPASS}@$CONTROLLER/heat"
    crudini --set /etc/heat/heat.conf DEFAULT rpc_backend rabbit
    crudini --set /etc/heat/heat.conf DEFAULT auth_strategy keystone
    crudini --set /etc/heat/heat.conf DEFAULT my_ip ${MGMTIP}
    crudini --set /etc/heat/heat.conf glance host $CONTROLLER
    crudini --set /etc/heat/heat.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/heat/heat.conf DEFAULT debug ${DEBUG_LOGGING}

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/heat/heat.conf DEFAULT rabbit_host $CONTROLLER
	crudini --set /etc/heat/heat.conf DEFAULT rabbit_userid ${RABBIT_USER}
	crudini --set /etc/heat/heat.conf DEFAULT rabbit_password "${RABBIT_PASS}"

	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    identity_uri http://${CONTROLLER}:35357
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    admin_tenant_name service
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    admin_user heat
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    admin_password "${HEAT_PASS}"
    else
	crudini --set /etc/heat/heat.conf oslo_messaging_rabbit \
	    rabbit_host $CONTROLLER
	crudini --set /etc/heat/heat.conf oslo_messaging_rabbit \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/heat/heat.conf oslo_messaging_rabbit \
	    rabbit_password "${RABBIT_PASS}"

	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    auth_plugin password
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    project_domain_id default
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    user_domain_id default
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    project_name service
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    username heat
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    password "${HEAT_PASS}"
    fi

    if [ $OSVERSION -ge $OSLIBERTY ]; then
	crudini --set /etc/heat/heat.conf trustee \
	    auth_plugin password
	crudini --set /etc/heat/heat.conf trustee \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/heat/heat.conf trustee \
	    username heat
	crudini --set /etc/heat/heat.conf trustee \
	    password ${HEAT_PASS}
	crudini --set /etc/heat/heat.conf trustee \
	    user_domain_id default

	crudini --set /etc/heat/heat.conf clients_keystone \
	    auth_uri http://${CONTROLLER}:5000
    fi

    crudini --set /etc/heat/heat.conf DEFAULT \
	heat_metadata_server_url http://$CONTROLLER:8000
    crudini --set /etc/heat/heat.conf DEFAULT \
	heat_waitcondition_server_url http://$CONTROLLER:8000/v1/waitcondition

    if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
	crudini --set /etc/heat/heat.conf ec2authtoken \
		auth_uri http://${CONTROLLER}:5000
    else
	crudini --set /etc/heat/heat.conf ec2authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
    fi

    if [ $OSVERSION -ge $OSKILO ]; then
	crudini --set /etc/heat/heat.conf DEFAULT \
	    stack_domain_admin heat_domain_admin
	crudini --set /etc/heat/heat.conf DEFAULT \
	    stack_domain_admin_password $HEAT_DOMAIN_PASS
	crudini --set /etc/heat/heat.conf DEFAULT \
	    stack_user_domain_name heat_user_domain
    fi

    crudini --del /etc/heat/heat.conf DEFAULT auth_host
    crudini --del /etc/heat/heat.conf DEFAULT auth_port
    crudini --del /etc/heat/heat.conf DEFAULT auth_protocol

    if [ $OSVERSION -eq $OSKILO ]; then
	heat-keystone-setup-domain \
	    --stack-user-domain-name heat_user_domain \
	    --stack-domain-admin heat_domain_admin \
	    --stack-domain-admin-password ${HEAT_DOMAIN_PASS}
    fi

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
    echo "HEAT_DOMAIN_PASS=\"${HEAT_DOMAIN_PASS}\"" >> $SETTINGS
fi

#
# Get Telemeterized
#
if [ -z "${CEILOMETER_DBPASS}" ]; then
    CEILOMETER_DBPASS=`$PSWDGEN`
    CEILOMETER_PASS=`$PSWDGEN`
    CEILOMETER_SECRET=`$PSWDGEN`

    if [ "${CEILOMETER_USE_MONGODB}" = "1" ]; then
	maybe_install_packages mongodb-server python-pymongo
	maybe_install_packages mongodb-clients

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
	maybe_install_packages mariadb-server python-mysqldb

	echo "create database ceilometer" | mysql -u root --password="$DB_ROOT_PASS"
	echo "grant all privileges on ceilometer.* to 'ceilometer'@'localhost' identified by '$CEILOMETER_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
	echo "grant all privileges on ceilometer.* to 'ceilometer'@'%' identified by '$CEILOMETER_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    fi

    if [ $OSVERSION -eq $OSJUNO ]; then
	keystone user-create --name ceilometer --pass $CEILOMETER_PASS
	keystone user-role-add --user ceilometer --tenant service --role admin
	keystone service-create --name ceilometer --type metering \
	    --description "OpenStack Telemetry Service"

	keystone endpoint-create \
	    --service-id $(keystone service-list | awk '/ metering / {print $2}') \
	    --publicurl http://${CONTROLLER}:8777 \
	    --internalurl http://${CONTROLLER}:8777 \
	    --adminurl http://${CONTROLLER}:8777 \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $CEILOMETER_PASS ceilometer
	__openstack role add --user ceilometer --project service admin
	__openstack service create --name ceilometer \
	    --description "OpenStack Telemetry Service" metering

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://$CONTROLLER:8777 \
		--internalurl http://$CONTROLLER:8777 \
		--adminurl http://$CONTROLLER:8777 \
		--region $REGION metering
	else
	    __openstack endpoint create --region $REGION \
		metering public http://${CONTROLLER}:8777
	    __openstack endpoint create --region $REGION \
		metering internal http://${CONTROLLER}:8777
	    __openstack endpoint create --region $REGION \
		metering admin http://${CONTROLLER}:8777
	fi
    fi

    maybe_install_packages ceilometer-api ceilometer-collector \
	ceilometer-agent-central ceilometer-agent-notification \
	ceilometer-alarm-evaluator ceilometer-alarm-notifier \
	python-ceilometerclient python-bson

    if [ "${CEILOMETER_USE_MONGODB}" = "1" ]; then
	crudini --set /etc/ceilometer/ceilometer.conf database \
	    connection "mongodb://ceilometer:${CEILOMETER_DBPASS}@$CONTROLLER:27017/ceilometer" 
    else
	crudini --set /etc/ceilometer/ceilometer.conf database \
	    connection "mysql://ceilometer:${CEILOMETER_DBPASS}@$CONTROLLER/ceilometer?charset=utf8"
    fi

    crudini --set /etc/ceilometer/ceilometer.conf DEFAULT rpc_backend rabbit
    crudini --set /etc/ceilometer/ceilometer.conf DEFAULT auth_strategy keystone
    crudini --set /etc/ceilometer/ceilometer.conf glance host $CONTROLLER
    crudini --set /etc/ceilometer/ceilometer.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/ceilometer/ceilometer.conf DEFAULT debug ${DEBUG_LOGGING}
    crudini --set /etc/ceilometer/ceilometer.conf DEFAULT \
	log_dir /var/log/ceilometer

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/ceilometer/ceilometer.conf DEFAULT rabbit_host $CONTROLLER
	crudini --set /etc/ceilometer/ceilometer.conf DEFAULT rabbit_userid ${RABBIT_USER}
	crudini --set /etc/ceilometer/ceilometer.conf DEFAULT rabbit_password "${RABBIT_PASS}"

	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    identity_uri http://${CONTROLLER}:35357
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    admin_tenant_name service
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    admin_user ceilometer
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    admin_password "${CEILOMETER_PASS}"
    else
	crudini --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit \
	    rabbit_host $CONTROLLER
	crudini --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit \
	    rabbit_password "${RABBIT_PASS}"

	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    auth_plugin password
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    project_domain_id default
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    user_domain_id default
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    project_name service
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    username ceilometer
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    password "${CEILOMETER_PASS}"
    fi

    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	os_auth_url http://${CONTROLLER}:5000/v2.0
    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	os_username ceilometer
    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	os_tenant_name service
    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	os_password ${CEILOMETER_PASS}
    if [ $OSVERSION -ge $OSKILO ]; then
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    os_endpoint_type internalURL
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
		os_region_name $REGION
    fi

    crudini --set /etc/ceilometer/ceilometer.conf notification \
	store_events true
    crudini --set /etc/ceilometer/ceilometer.conf notification \
	disable_non_metric_meters false

    if [ $OSVERSION -le $OSJUNO ]; then
	crudini --set /etc/ceilometer/ceilometer.conf publisher \
	    metering_secret ${CEILOMETER_SECRET}
    else
	crudini --set /etc/ceilometer/ceilometer.conf publisher \
	    telemetry_secret ${CEILOMETER_SECRET}
    fi

    crudini --del /etc/ceilometer/ceilometer.conf DEFAULT auth_host
    crudini --del /etc/ceilometer/ceilometer.conf DEFAULT auth_port
    crudini --del /etc/ceilometer/ceilometer.conf DEFAULT auth_protocol

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

    if [ $CEILOMETER_USE_WSGI -eq 1 ]; then
	cat <<EOF > /etc/apache2/sites-available/wsgi-ceilometer.conf
Listen 8777

<VirtualHost *:8777>
    WSGIDaemonProcess ceilometer-api processes=2 threads=10 user=ceilometer display-name=%{GROUP}
    WSGIProcessGroup ceilometer-api
    WSGIScriptAlias / /usr/bin/ceilometer-wsgi-app
    WSGIApplicationGroup %{GLOBAL}
#    WSGIPassAuthorization On
    <IfVersion >= 2.4>
       ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    ErrorLog /var/log/apache2/ceilometer_error.log
    CustomLog /var/log/apache2/ceilometer_access.log combined
    <Directory /usr/bin>
        <IfVersion >= 2.4>
            Require all granted
        </IfVersion>
        <IfVersion < 2.4>
            Order allow,deny
            Allow from all
        </IfVersion>
    </Directory>
</VirtualHost>
EOF

	a2ensite wsgi-ceilometer
	wget -O /usr/bin/ceilometer-wsgi-app https://raw.githubusercontent.com/openstack/ceilometer/stable/${OSCODENAME}/ceilometer/api/app.wsgi
	
	service apache2 reload
    else
	service_restart ceilometer-api
	service_enable ceilometer-api
    fi

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

	touch $OURDIR/compute-telemetry-done-${node}
    done

    echo "TELEMETRY_COMPUTENODES_DONE=\"${TELEMETRY_COMPUTENODES_DONE}\"" >> $SETTINGS
fi

#
# Install the Telemetry service for Glance
#
if [ -z "${TELEMETRY_GLANCE_DONE}" ]; then
    TELEMETRY_GLANCE_DONE=1

    if [ $OSVERSION -ge $OSLIBERTY ]; then
	RIS=oslo_messaging_rabbit
    else
	RIS=DEFAULT
    fi

    crudini --set /etc/glance/glance-api.conf DEFAULT \
	notification_driver messagingv2
    crudini --set /etc/glance/glance-api.conf DEFAULT \
	rpc_backend rabbit
    crudini --set /etc/glance/glance-api.conf $RIS \
	rabbit_host ${CONTROLLER}
    crudini --set /etc/glance/glance-api.conf $RIS \
	rabbit_userid ${RABBIT_USER}
    crudini --set /etc/glance/glance-api.conf $RIS \
	rabbit_password ${RABBIT_PASS}

    crudini --set /etc/glance/glance-registry.conf DEFAULT \
	notification_driver messagingv2
    crudini --set /etc/glance/glance-registry.conf DEFAULT \
	rpc_backend rabbit
    crudini --set /etc/glance/glance-registry.conf $RIS \
	rabbit_host ${CONTROLLER}
    crudini --set /etc/glance/glance-registry.conf $RIS \
	rabbit_userid ${RABBIT_USER}
    crudini --set /etc/glance/glance-registry.conf $RIS \
	rabbit_password ${RABBIT_PASS}

    service_restart glance-registry
    service_restart glance-api

    echo "TELEMETRY_GLANCE_DONE=\"${TELEMETRY_GLANCE_DONE}\"" >> $SETTINGS
fi

#
# Install the Telemetry service for Cinder
#
if [ -z "${TELEMETRY_CINDER_DONE}" ]; then
    TELEMETRY_CINDER_DONE=1

    crudini --set /etc/cinder/cinder.conf DEFAULT control_exchange cinder
    crudini --set /etc/cinder/cinder.conf DEFAULT notification_driver messagingv2

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

    maybe_install_packages python-ceilometerclient python-ceilometermiddleware

    if [ $OSVERSION -le $OSJUNO ]; then
	keystone role-create --name ResellerAdmin
	keystone user-role-add --tenant service --user ceilometer \
		 --role $(keystone role-list | awk '/ ResellerAdmin / {print $2}')
    else
	__openstack role create ResellerAdmin
	__openstack role add --project service --user ceilometer ResellerAdmin
    fi

    if [ $OSVERSION -le $OSKILO ]; then
	crudini --set /etc/swift/proxy-server.conf filter:ceilometer \
		use 'egg:ceilometer#swift'
    fi

    if [ $OSVERSION -ge $OSKILO ]; then
	crudini --set /etc/swift/proxy-server.conf filter:keystoneauth \
	    operator_roles 'admin, user, ResellerAdmin'

	crudini --set /etc/swift/proxy-server.conf filter:ceilometer \
	    paste.filter_factory ceilometermiddleware.swift:filter_factory
	crudini --set /etc/swift/proxy-server.conf filter:ceilometer \
	    control_exchange swift
	crudini --set /etc/swift/proxy-server.conf filter:ceilometer \
	    url rabbit://${RABBIT_USER}:${RABBIT_PASS}@${CONTROLLER}:5672/
	crudini --set /etc/swift/proxy-server.conf filter:ceilometer \
	    driver messagingv2
	crudini --set /etc/swift/proxy-server.conf filter:ceilometer \
	    topic notifications
	crudini --set /etc/swift/proxy-server.conf filter:ceilometer \
	    log_level WARN
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
    maybe_install_packages trove-common
    if [ ! $? -eq 0 ]; then
	touch /var/lib/trove/trove_test.sqlite
	chown trove:trove /var/lib/trove/trove_test.sqlite
	crudini --set /etc/trove/trove.conf database connection sqlite:////var/lib/trove/trove_test.sqlite
	maybe_install_packages trove-common
    fi

    maybe_install_packages python-trove python-troveclient python-glanceclient \
	trove-api trove-taskmanager trove-conductor

    echo "create database trove" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on trove.* to 'trove'@'localhost' identified by '$TROVE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on trove.* to 'trove'@'%' identified by '$TROVE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    if [ $OSVERSION -eq $OSJUNO ]; then
	keystone user-create --name trove --pass $TROVE_PASS
	keystone user-role-add --user trove --tenant service --role admin

	keystone service-create --name trove --type database \
	    --description "OpenStack Database Service"

	keystone endpoint-create \
	    --service-id $(keystone service-list | awk '/ trove / {print $2}') \
	    --publicurl http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s \
	    --internalurl http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s \
	    --adminurl http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $TROVE_PASS trove
	__openstack role add --user trove --project service admin
	__openstack service create --name trove \
	    --description "OpenStack Database Service" database

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s \
		--internalurl http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s \
		--adminurl http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s \
		--region $REGION \
		database
	else
	    __openstack endpoint create --region $REGION \
		database public http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		database internal http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		database admin http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s
	fi
    fi

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
trove_auth_url = http://${CONTROLLER}:5000/${KAPISTR}
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
trove_auth_url = http://${CONTROLLER}:5000/${KAPISTR}
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
trove_auth_url = http://${CONTROLLER}:5000/${KAPISTR}
nova_compute_url = http://${CONTROLLER}:8774/v2
cinder_url = http://${CONTROLLER}:8776/v1
swift_url = http://${CONTROLLER}:8080/v1/AUTH_
sql_connection = mysql://trove:${TROVE_DBPASS}@${CONTROLLER}/trove
notifier_queue_hostname = ${CONTROLLER}
EOF
    cat <<EOF >> /etc/trove/api-paste.ini
[filter:authtoken]
auth_uri = http://${CONTROLLER}:5000/${KAPISTR}
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

    if [ $OSVERSION -eq $OSJUNO ]; then
	keystone user-create --name sahara --pass $SAHARA_PASS
	keystone user-role-add --user sahara --tenant service --role admin

	keystone service-create --name sahara --type data_processing \
	    --description "OpenStack Data Processing Service"
	keystone endpoint-create \
	    --service-id $(keystone service-list | awk '/ sahara / {print $2}') \
	    --publicurl http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s \
	    --internalurl http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s \
	    --adminurl http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $SAHARA_PASS sahara
	__openstack role add --user sahara --project service admin
	__openstack service create --name sahara \
	    --description "OpenStack Data Processing Service" data_processing

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s \
		--internalurl http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s \
		--adminurl http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s \
		--region $REGION \
		data_processing
	else
	    __openstack endpoint create --region $REGION \
		data_processing public http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		data_processing internal http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		data_processing admin http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s
	fi
    fi

    aserr=0
    apt-cache search ^sahara\$ | grep -q sahara
    if [ $? -eq 0 ] ; then
	APT_HAS_SAHARA=1
    else
	APT_HAS_SAHARA=0
    fi

    if [ ${APT_HAS_SAHARA} -eq 0 ]; then
        # XXX: http://askubuntu.com/questions/555093/openstack-juno-sahara-data-processing-on-14-04
	maybe_install_packages python-pip
        # sahara deps
	maybe_install_packages python-eventlet python-flask python-oslo.serialization
	pip install sahara
    else
	# This may fail because sahara's migration scripts use ALTER TABLE,
        # which sqlite doesn't support
	maybe_install_packages sahara-common 
	aserr=$?
	maybe_install_packages sahara-api sahara-engine
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
auth_uri = http://$CONTROLLER:5000/${KAPISTR}
identity_uri = http://$CONTROLLER:35357
admin_tenant_name = service
admin_user = sahara
admin_password = ${SAHARA_PASS}

[ec2authtoken]
auth_uri = http://${CONTROLLER}:5000/${KAPISTR}
EOF

    sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/sahara/sahara.conf
    sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/sahara/sahara.conf
    sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/sahara/sahara.conf

    # If the apt-get install had failed, do it again so that the configure
    # step can succeed ;)
    if [ ! $aserr -eq 0 ]; then
	maybe_install_packages sahara-common sahara-api sahara-engine
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
	--region $REGION

    maybe_install_packages ironic-api ironic-conductor python-ironicclient python-ironic

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
if [ -e $OURDIR/random_admin_pass ]; then
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
