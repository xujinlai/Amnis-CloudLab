#!/bin/sh

##
## Setup an OpenVPN client for the management network.  Just saves
## a couple SSH connections from the server driving the setup.
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

$APTGETINSTALL openvpn

cp -p $OURDIR/$HOSTNAME.crt $OURDIR/$HOSTNAME.key /etc/openvpn/
cp -p $OURDIR/ca.crt /etc/openvpn

cat <<EOF > /etc/openvpn/server.conf
client
dev tun
proto udp
remote ${NETWORKMANAGER}.$EEID.$EPID.$OURDOMAIN 1194
resolv-retry infinite
nobind
persist-key
persist-tun
ca ca.crt
cert $HOSTNAME.crt
key $HOSTNAME.key
ns-cert-type server
comp-lzo
verb 3
EOF

cp -p $OURDIR/mgmt-hosts /etc/hosts

#
# Get the server up
#
if [ ${HAVE_SYSTEMD} -eq 1 ]; then
    systemctl enable openvpn@server.service
    systemctl restart openvpn@server.service
else
    service openvpn restart
fi

exit 0
