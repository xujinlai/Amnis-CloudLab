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

HOSTNAME=`hostname -s`
if [ "$HOSTNAME" != "$CONTROLLER" ]; then
    exit 0;
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

. $OURDIR/admin-openrc.sh

echo "*** Building an ARM64 image ..."

# Grab some files
wget http://boss.utah.cloudlab.us/downloads/vmlinuz-3.13.0-40-arm64-generic
wget http://boss.utah.cloudlab.us/downloads/initrd.img-3.13.0-40-arm64-generic
wget http://boss.utah.cloudlab.us/downloads/ubuntu-core-14.04.1-core-arm64.tar.gz

core=ubuntu-core-14.04.1-core-arm64.tar.gz
out=ubuntu-core-14.04.1-core-arm64.img

dd if=/dev/zero of="$out" bs=1M count=1024
echo "*** making a new ext4 filesystem ..."
echo "y" | mkfs -t ext4 "$out" >/dev/null
mkdir -p mnt
mount -o loop "$out" mnt

echo "*** adding contents of core tarball ..."
tar xzf "$core" -C mnt

echo "*** adding ttyAMA0 ..."
{
    cat - <<EOM
# ttyAMA0 - getty
#
# This service maintains a getty on ttyAMA0 from the point the system is
# started until it is shut down again.
#start on stopped rc RUNLEVEL=[2345] and (
#            not-container or
#            container CONTAINER=lxc or
#            container CONTAINER=lxc-libvirt)
start on started

stop on runlevel [!2345]

respawn
exec /sbin/getty -L ttyAMA0 115200
EOM
} | tee mnt/etc/init/ttyAMA0.conf >/dev/null

echo "*** adding NTP date and time synchronization ..."
{
    cat - <<EOM
#
# This task is run on startup to set the system date and time via NTP

description     "set the date and time via NTP"

start on startup

task
exec ntpdate -u ntp.ubuntu.com
EOM
} | tee mnt/etc/init/ntpdate.conf >/dev/null

#
# NOTE: we reduce the MTU arbitrarily here so that we can (easily) fit
# through a GRE tunnel.
#
echo "*** adding networking for qemu ..."
{
    cat - <<EOM

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
    post-up /sbin/ifconfig eth0 mtu 1300
EOM
} | tee -a mnt/etc/network/interfaces >/dev/null


echo 'Acquire::CompressionTypes::Order { "gz"; "bz2"; }' | tee mnt/etc/apt/apt.conf.d/99gzip >/dev/null

echo "*** fixing root password to root/root ..."
sed -in -e 's@root:\*:@root:$6$pDWQLJGt$813e.4.vXznRlkCpxRtBdUZmHf6DnYg.XM58h6SGLF0Q2tCh5kTF2hCi7fm9NeaSSHeGBaUfpKQ9/wA54mcb51:@' mnt/etc/shadow

echo "*** unmounting ..."
umount mnt
rmdir mnt

echo "*** Importing new image ..."

glance image-create --name vmlinuz-3.13.0-40-arm64-generic --is-public True --progress --file vmlinuz-3.13.0-40-arm64-generic --disk-format aki --container-format aki

KERNEL_ID=`glance image-show vmlinuz-3.13.0-40-arm64-generic | grep id | sed -n -e 's/^.*id.*| \([0-9a-zA-Z-]*\).*$/\1/p'`

glance image-create --name initrd-3.13.0-40-arm64-generic --is-public True --progress --file initrd.img-3.13.0-40-arm64-generic --disk-format ari --container-format ari

RAMDISK_ID=`glance image-show initrd-3.13.0-40-arm64-generic | grep id | sed -n -e 's/^.*id.*| \([0-9a-zA-Z-]*\).*$/\1/p'`

glance image-create --name ubuntu-core-14.04.1-core-arm64 --is-public True --progress --file $out --disk-format ami --container-format ami

glance image-update --property kernel_args="console=ttyAMA0 root=/dev/sda" ubuntu-core-14.04.1-core-arm64
glance image-update --property kernel_id=${KERNEL_ID} ubuntu-core-14.04.1-core-arm64
glance image-update --property ramdisk_id=${RAMDISK_ID} ubuntu-core-14.04.1-core-arm64

echo "*** Creating data network and subnet ..."

neutron net-create ${EPID}-net
neutron subnet-create ${EPID}-net  --name ${EPID}-subnet 172.16/12
neutron router-create ${EPID}-router
neutron router-interface-add ${EPID}-router ${EPID}-subnet
neutron router-gateway-set ${EPID}-router ext-net

#
# Now do another one, with sshd installed
#
mkdir -p mnt
mount -o loop "$out" mnt

echo "*** installing ssh/sshd..."
echo "nameserver 8.8.8.8" > mnt/etc/resolv.conf
chroot mnt /usr/bin/apt-get install -y openssh-server openssh-client
chroot mnt /usr/sbin/update-rc.d ssh defaults
chroot mnt /usr/sbin/update-rc.d ssh enable

cat <<EOF > mnt/etc/ssh/sshd_config
Port 22
#ListenAddress ::
#ListenAddress 0.0.0.0
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_dsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
UsePrivilegeSeparation yes
KeyRegenerationInterval 3600
ServerKeyBits 1024
SyslogFacility AUTH
LogLevel INFO
LoginGraceTime 120
RSAAuthentication yes
PubkeyAuthentication yes
#AuthorizedKeysFile     %h/.ssh/authorized_keys
IgnoreRhosts yes
# For this to work you will also need host keys in /etc/ssh_known_hosts
RhostsRSAAuthentication no
# similar for protocol version 2
HostbasedAuthentication no
# Uncomment if you don't trust ~/.ssh/known_hosts for RhostsRSAAuthentication
IgnoreUserKnownHosts yes
# To enable empty passwords, change to yes (NOT RECOMMENDED)
#PermitEmptyPasswords no
ChallengeResponseAuthentication no
# Change to no to disable tunnelled clear text passwords
PasswordAuthentication yes
X11Forwarding yes
X11DisplayOffset 10
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
#UseLogin no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
UsePAM yes
UseDNS no
StrictModes no
PermitRootLogin yes
PasswordAuthentication yes
EOF

echo "*** unmounting ..."
umount mnt
rmdir mnt

echo "*** Importing new image (with sshd) ..."

glance image-create --name ubuntu-core-14.04.1-core-arm64-sshd --is-public True --progress --file $out --disk-format ami --container-format ami

glance image-update --property kernel_args="console=ttyAMA0 root=/dev/sda" ubuntu-core-14.04.1-core-arm64-sshd
glance image-update --property kernel_id=${KERNEL_ID} ubuntu-core-14.04.1-core-arm64-sshd
glance image-update --property ramdisk_id=${RAMDISK_ID} ubuntu-core-14.04.1-core-arm64-sshd

exit 0
