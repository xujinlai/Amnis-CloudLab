#!/bin/sh

##
## Initialize some basic aarch64 stuff.
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

echo "*** Downloading an x86_64 image ..."

#wget https://cloud-images.ubuntu.com/trusty/current/trusty-server-cloudimg-amd64-disk1.img
wget http://boss.apt.emulab.net/downloads/trusty-server-cloudimg-amd64-disk1.img

modprobe nbd max_part=8
qemu-nbd --connect=/dev/nbd0 trusty-server-cloudimg-amd64-disk1.img

mount /dev/nbd0p1 /mnt/

echo "*** Setting up sshd ..."
sed -i -e 's/^.*PermitRootLogin .*$/PermitRootLogin yes/' /mnt/etc/ssh/sshd_config
sed -i -e 's/^.*PasswordAuthentication .*$/PasswordAuthentication yes/' /mnt/etc/ssh/sshd_config

echo "*** Modifying root password..."

echo "*** fixing root password ..."
sed -i -e 's@root:[^:]*:@root:$6$QDmiL4Pp$OxXz9eP112jYY4rljT.1QUFqw.PW9g85VMapJehvRIDrkio1LN.74Tq40XbkvxCXAGEcLi.eZOaCFqgelSzOA/:@' /mnt/etc/shadow

echo "*** fixing ubuntu password ..."
sed -i -e 's@ubuntu:[^:]*:@ubuntu:$6$QDmiL4Pp$OxXz9eP112jYY4rljT.1QUFqw.PW9g85VMapJehvRIDrkio1LN.74Tq40XbkvxCXAGEcLi.eZOaCFqgelSzOA/:@' /mnt/etc/shadow

# permit root login!!
sed -i -e 's/^disable_root: true$/disable_root: false/' /mnt/etc/cloud/cloud.cfg

# don't overwrite the Ubuntu passwd we just hacked in
sed -i -e 's/^.*lock_passwd:.*$/     lock_passwd: False/' /mnt/etc/cloud/cloud.cfg

umount /mnt

echo "*** Importing new image ..."

glance image-create --name trusty-server --is-public True  --disk-format qcow2 --container-format bare --progress --file trusty-server-cloudimg-amd64-disk1.img

mount /dev/nbd0p1 /mnt/

echo "*** Modifying to support up to 8 NICs..."

cat <<EOF > /mnt/etc/network/interfaces
# interfaces(5) file used by ifup(8) and ifdown(8)
# Include files from /etc/network/interfaces.d:
source-directory /etc/network/interfaces.d

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp

auto eth1
iface eth1 inet dhcp

auto eth2
iface eth2 inet dhcp

auto eth3
iface eth3 inet dhcp

auto eth4
iface eth4 inet dhcp

auto eth5
iface eth5 inet dhcp

auto eth6
iface eth6 inet dhcp

auto eth7
iface eth7 inet dhcp
EOF

#
# Ok, there is some delay with local-filesystems not finishing mounting
# until after the cloud-utils have blocked up the system :(.  So, remove
# this dependency.  You can see why the Ubuntu people have it in general,
# but it will never bother us in this VM image!
#
#sed -i -e 's/^start on (local-filesystems$/start on (mounted MOUNTPOINT=\/ and mounted MOUNTPOINT=\/sys and mounted MOUNTPOINT=\/proc and mounted MOUNTPOINT=\/run/' mnt/etc/init/networking.conf
sed -i -e 's/^start on (local-filesystems$/start on (mounted MOUNTPOINT=\//' /mnt/etc/init/networking.conf

#
# Handle ethX devices that aren't actually in the VM instance by faking
# that they are up so that startup doesn't get hung and timeout.  Our hack
# only looks for ^eth\d*$ devices, and skips them if they're not accessible
# via ifconfig.  This should be pretty safe, and it doesn't block things 
# like bridges, ovs devices, tun/tap, etc.
#
cp -p $DIRNAME/etc/if-pre-up-upstart-faker /mnt/etc/network/if-pre-up.d/

umount /mnt

echo "*** Importing new multi-nic image ..."

glance image-create --name trusty-server-multi-nic --is-public True  --disk-format qcow2 --container-format bare --progress --file trusty-server-cloudimg-amd64-disk1.img

qemu-nbd -d /dev/nbd0

exit 0
