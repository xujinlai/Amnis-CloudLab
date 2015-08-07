#!/bin/sh

##
## Setup a OpenStack compute node for Nova.
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ "$HOSTNAME" = "$CONTROLLER" -o "$HOSTNAME" = "$NETWORKMANAGER" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-compute-network-done ]; then
    exit 0
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

# Grab the neutron configuration we computed in setup-lib.sh
. $OURDIR/info.neutron

cat <<EOF >> /etc/sysctl.conf
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF

sysctl -p

$APTGETINSTALL neutron-plugin-ml2 neutron-plugin-openvswitch-agent

sed -i -e "s/^\\(.*connection.*=.*\\)$/#\1/" /etc/neutron/neutron.conf
sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/neutron/neutron.conf
sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/neutron/neutron.conf
sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/neutron/neutron.conf

# Just slap these in.
cat <<EOF >> /etc/neutron/neutron.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = $CONTROLLER
rabbit_userid = ${RABBIT_USER}
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
core_plugin = ml2
service_plugins = router,metering
allow_overlapping_ips = True
verbose = True

[keystone_authtoken]
auth_uri = http://$CONTROLLER:5000/v2.0
identity_uri = http://$CONTROLLER:35357
admin_tenant_name = service
admin_user = neutron
admin_password = ${NEUTRON_PASS}
EOF

fwdriver="neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver"
if [ ${DISABLE_SECURITY_GROUPS} -eq 1 ]; then
    fwdriver="neutron.agent.firewall.NoopFirewallDriver"
fi

# Just slap these in.
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

[securitygroup]
enable_security_group = True
enable_ipset = True
firewall_driver = $fwdriver

[ovs]
${gre_local_ip}
${enable_tunneling}
${bridge_mappings}

[agent]
${tunnel_types}
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
EOF

service openvswitch-switch restart
service nova-compute restart
service neutron-plugin-openvswitch-agent restart

touch $OURDIR/setup-compute-network-done

exit 0
