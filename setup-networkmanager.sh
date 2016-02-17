#!/bin/sh

##
## Setup the OpenStack networkmanager node for Neutron.
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ "$HOSTNAME" != "$NETWORKMANAGER" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-networkmanager-done ]; then
    exit 0
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

# Grab the neutron configuration we computed in setup-lib.sh
. $OURDIR/neutron.vars

cat <<EOF >> /etc/sysctl.conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF

sysctl -p

maybe_install_packages neutron-plugin-ml2 neutron-plugin-openvswitch-agent \
    neutron-l3-agent neutron-dhcp-agent conntrack neutron-metering-agent

# If not a shared controller, don't want neutron connecting to nonexistent db
if [ ! "$CONTROLLER" = "$NETWORKMANAGER" ]; then
    crudini --del /etc/neutron/neutron.conf database connection
    crudini --del /etc/neutron/neutron.conf keystone_authtoken auth_host
    crudini --del /etc/neutron/neutron.conf keystone_authtoken auth_port
    crudini --del /etc/neutron/neutron.conf keystone_authtoken auth_protocol
fi

crudini --set /etc/neutron/neutron.conf DEFAULT rpc_backend rabbit
crudini --set /etc/neutron/neutron.conf DEFAULT auth_strategy keystone
crudini --set /etc/neutron/neutron.conf DEFAULT core_plugin ml2
crudini --set /etc/neutron/neutron.conf DEFAULT service_plugins 'router,metering'
crudini --set /etc/neutron/neutron.conf DEFAULT allow_overlapping_ips True
crudini --set /etc/neutron/neutron.conf DEFAULT verbose ${VERBOSE_LOGGING}
crudini --set /etc/neutron/neutron.conf DEFAULT debug ${DEBUG_LOGGING}
crudini --set /etc/neutron/neutron.conf DEFAULT notification_driver messagingv2

if [ $OSVERSION -lt $OSKILO ]; then
    crudini --set /etc/neutron/neutron.conf DEFAULT rabbit_host $CONTROLLER
    crudini --set /etc/neutron/neutron.conf DEFAULT rabbit_userid ${RABBIT_USER}
    crudini --set /etc/neutron/neutron.conf DEFAULT rabbit_password "${RABBIT_PASS}"

    crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	auth_uri http://${CONTROLLER}:5000/v2.0
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
#crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vxlan \
#    vxlan_group 224.0.0.1
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup \
    enable_security_group True
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup \
    enable_ipset True
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup \
    firewall_driver $fwdriver

# Just slap these in.
cat <<EOF >> /etc/neutron/plugins/ml2/ml2_conf.ini
[ovs]
${gre_local_ip}
${enable_tunneling}
${bridge_mappings}

[agent]
${tunnel_types}
EOF

# Configure the L3 agent.
crudini --set /etc/neutron/l3_agent.ini DEFAULT \
    interface_driver neutron.agent.linux.interface.OVSInterfaceDriver
crudini --set /etc/neutron/l3_agent.ini DEFAULT use_namespaces True
crudini --set /etc/neutron/l3_agent.ini DEFAULT external_network_bridge br-ex
#crudini --set /etc/neutron/l3_agent.ini DEFAULT router_delete_namespaces True
crudini --set /etc/neutron/l3_agent.ini DEFAULT verbose ${VERBOSE_LOGGING}
crudini --set /etc/neutron/l3_agent.ini DEFAULT debug ${DEBUG_LOGGING}

# Configure the DHCP agent.
crudini --set /etc/neutron/dhcp_agent.ini DEFAULT \
    interface_driver neutron.agent.linux.interface.OVSInterfaceDriver
crudini --set /etc/neutron/dhcp_agent.ini DEFAULT \
    dhcp_driver neutron.agent.linux.dhcp.Dnsmasq
crudini --set /etc/neutron/dhcp_agent.ini DEFAULT use_namespaces True
#crudini --set /etc/neutron/dhcp_agent.ini DEFAULT dhcp_delete_namespaces True
crudini --set /etc/neutron/dhcp_agent.ini DEFAULT verbose ${VERBOSE_LOGGING}
crudini --set /etc/neutron/dhcp_agent.ini DEFAULT debug ${DEBUG_LOGGING}

# Uncomment if dhcp has trouble due to MTU
crudini --set /etc/neutron/dhcp_agent.ini DEFAULT \
    dnsmasq_config_file /etc/neutron/dnsmasq-neutron.conf
cat <<EOF >>/etc/neutron/dnsmasq-neutron.conf
dhcp-option-force=26,1454
log-queries
log-dhcp
no-resolv
server=8.8.8.8
EOF
pkill dnsmasq

# Setup the Metadata agent.
if [ $OSVERSION -lt $OSKILO ]; then
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	auth_url http://$CONTROLLER:5000/v2.0/
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	auth_region $REGION
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	admin_tenant_name service
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	admin_user neutron
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	admin_password ${NEUTRON_PASS}
else
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	auth_uri http://${CONTROLLER}:5000
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	auth_url http://${CONTROLLER}:35357
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	auth_region $REGION
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	auth_plugin password
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	project_domain_id default
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	user_domain_id default
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	project_name service
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	username neutron
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	password "${NEUTRON_PASS}"
fi
crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
    nova_metadata_ip ${CONTROLLER}
crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
    metadata_proxy_shared_secret ${NEUTRON_METADATA_SECRET}
crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
    verbose ${VERBOSE_LOGGING}
crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
    debug ${DEBUG_LOGGING}

# Setup the metering agent.
crudini --set /etc/neutron/metering_agent.ini DEFAULT debug True
crudini --set /etc/neutron/metering_agent.ini DEFAULT \
    driver neutron.services.metering.drivers.iptables.iptables_driver.IptablesMeteringDriver
crudini --set /etc/neutron/metering_agent.ini DEFAULT measure_interval 30
crudini --set /etc/neutron/metering_agent.ini DEFAULT report_interval 300
crudini --set /etc/neutron/metering_agent.ini DEFAULT \
    interface_driver neutron.agent.linux.interface.OVSInterfaceDriver
crudini --set /etc/neutron/metering_agent.ini DEFAULT \
    use_namespaces True

#
# Ok, also put our FQDN into the hosts file so that local applications can
# resolve that pair even if the network happens to be down.  This happens,
# for instance, because of our anti-ARP spoofing "patch" to the openvswitch
# agent (the agent remove_all_flow()s on a switch periodically and inserts a
# default normal forwarding rule, plus anything it needs --- our patch adds some
# anti-ARP spoofing rules after remove_all but BEFORE the default normal rule
# gets added back (this is just the nature of the existing code in Juno and Kilo
# (the situation is easier to patch more nicely on the master branch, but we
# don't have Liberty yet)) --- and because it adds the rules via command line
# using sudo, and sudo tries to lookup the hostname --- this can cause a hang.)
# Argh, what a pain.  For the rest of this hack, see setup-ovs-node.sh, and
# setup-networkmanager.sh and setup-compute-network.sh where we patch the 
# neutron openvswitch agent.
#
echo "$MYIP    $NFQDN $PFQDN" >> /etc/hosts

#
# Patch the neutron openvswitch agent to try to stop inadvertent spoofing on
# the public emulab/cloudlab control net, sigh.
#
patch -d / -p0 < $DIRNAME/etc/neutron-${OSCODENAME}-openvswitch-remove-all-flows-except-system-flows.patch

#
# https://git.openstack.org/cgit/openstack/neutron/commit/?id=51f6b2e1c9c2f5f5106b9ae8316e57750f09d7c9
#
if [ $OSVERSION -ge $OSLIBERTY ]; then
    patch -d / -p0 < $DIRNAME/etc/neutron-liberty-ovs-agent-segmentation-id-None.patch
fi

#
# Neutron depends on bridge module, but it doesn't autoload it.
#
modprobe bridge
echo bridge >> /etc/modules

service_restart openvswitch-switch
service_enable openvswitch-switch
service_restart neutron-plugin-openvswitch-agent
service_enable neutron-plugin-openvswitch-agent
service_restart neutron-l3-agent
service_enable neutron-l3-agent
service_restart neutron-dhcp-agent
service_enable neutron-dhcp-agent
service_restart neutron-metadata-agent
service_enable neutron-metadata-agent
service_restart neutron-metering-agent
service_enable neutron-metering-agent

touch $OURDIR/setup-networkmanager-done

exit 0
