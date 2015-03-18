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

dataip=`cat $OURDIR/data-hosts | grep $HOSTNAME | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`

cat <<EOF >> /etc/sysctl.conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF

sysctl -p

apt-get install -y neutron-plugin-ml2 neutron-plugin-openvswitch-agent \
    neutron-l3-agent neutron-dhcp-agent conntrack

sed -i -e "s/^\\(.*connection.*=.*\\)$/#\1/" /etc/neutron/neutron.conf
sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/neutron/neutron.conf
sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/neutron/neutron.conf
sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/neutron/neutron.conf

# Just slap these in.
cat <<EOF >> /etc/neutron/neutron.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = $CONTROLLER
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
core_plugin = ml2
service_plugins = router
allow_overlapping_ips = True
verbose = True

[keystone_authtoken]
auth_uri = http://$CONTROLLER:5000/v2.0
identity_uri = http://$CONTROLLER:35357
admin_tenant_name = service
admin_user = neutron
admin_password = ${NEUTRON_PASS}
EOF

# enable_security_group = False
# firewall_driver = neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver

# Just slap these in.
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

[ovs]
local_ip = $dataip
enable_tunneling = True
bridge_mappings = external:br-ex,data:br-data

[agent]
tunnel_types = gre
EOF

# Just slap these in.
cat <<EOF >> /etc/neutron/l3_agent.ini
[DEFAULT]
interface_driver = neutron.agent.linux.interface.OVSInterfaceDriver
use_namespaces = True
external_network_bridge = br-ex
verbose = True
EOF

# Just slap these in.
cat <<EOF >> /etc/neutron/dhcp_agent.ini
[DEFAULT]
interface_driver = neutron.agent.linux.interface.OVSInterfaceDriver
dhcp_driver = neutron.agent.linux.dhcp.Dnsmasq
use_namespaces = True
verbose = True
EOF

# Uncomment if dhcp has trouble due to MTU
#cat <<EOF >> /etc/neutron/dhcp_agent.ini
#[DEFAULT]
#dnsmasq_config_file = /etc/neutron/dnsmasq-neutron.conf
#EOF
#cat <<EOF >> /etc/neutron/dnsmasq-neutron.conf
#dhcp-option-force=26,1454
#EOF
#pkill dnsmasq

sed -i -e "s/^.*auth_url.*=.*$/auth_url = http:\\/\\/$CONTROLLER:5000\\/v2.0/" /etc/neutron/metadata_agent.ini
sed -i -e "s/^.*auth_region.*=.*$/auth_region = regionOne/" /etc/neutron/metadata_agent.ini
sed -i -e "s/^.*admin_tenant_name.*=.*$/admin_tenant_name = service/" /etc/neutron/metadata_agent.ini
sed -i -e "s/^.*admin_user.*=.*$/admin_user = neutron/" /etc/neutron/metadata_agent.ini
sed -i -e "s/^.*admin_password.*=.*$/admin_password = ${NEUTRON_PASS}/" /etc/neutron/metadata_agent.ini

sed -i -e "s/^.*nova_metadata_ip.*=.*$/nova_metadata_ip = $CONTROLLER/" /etc/neutron/metadata_agent.ini
sed -i -e "s/^.*metadata_proxy_shared_secret.*=.*$/metadata_proxy_shared_secret = $NEUTRON_METADATA_SECRET/" /etc/neutron/metadata_agent.ini
cat <<EOF >> /etc/neutron/metadata_agent.ini
[DEFAULT]
verbose = True
EOF

service openvswitch-switch restart
service neutron-plugin-openvswitch-agent restart
service neutron-l3-agent restart
service neutron-dhcp-agent restart
service neutron-metadata-agent restart

touch $OURDIR/setup-networkmanager-done

exit 0
