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

echo "*** Building an ARM64 image ..."

# need growpart
maybe_install_packages cloud-guest-utils

# Grab some files
wget http://boss.utah.cloudlab.us/downloads/vmlinuz-3.13.0-40-arm64-generic
wget http://boss.utah.cloudlab.us/downloads/initrd.img-3.13.0-40-arm64-generic
if [ ${BUILD_AARCH64_FROM_CORE} = 1 ]; then
    wget http://boss.utah.cloudlab.us/downloads/ubuntu-core-14.04.1-core-arm64.tar.gz
    core=ubuntu-core-14.04.1-core-arm64.tar.gz
else
    wget http://boss.utah.cloudlab.us/downloads/ubuntu-core-14.04.1-core-arm64-prebuilt.tar.gz
    core=ubuntu-core-14.04.1-core-arm64-prebuilt.tar.gz
fi

echo "*** adding growpart to initrd ***"
initrd=initrd.img-3.13.0-40-arm64-generic
cp -pv $initrd ${initrd}.orig
mkdir -p initrd
cd initrd
gunzip -c ../$initrd | cpio -i -H newc 
#--verbose
cat <<'EOF' > scripts/local-premount/growpart
#/bin/sh -e

set -x

root_dev=`echo ${ROOT} | sed -n -e "s/.*\/\([a-z0-9]*[a-z]\).*/\1/p"`
part_num=`echo ${ROOT} | sed -n -e "s/.*\/[a-z0-9]*[a-z]\(.*\)/\1/p"`
echo "[] linux-rootfs-resize $ROOT ($root_dev and $part_num)..."
growpart -v /dev/${root_dev} ${part_num}
partprobe /dev/${root_dev}${part_num}
sleep 2
e2fsck -p -f /dev/${root_dev}${part_num}
sleep 2
resize2fs -f -p /dev/${root_dev}${part_num}
EOF

chmod ug+x scripts/local-premount/growpart
echo "/scripts/local-premount/growpart" >> scripts/local-premount/ORDER

# copy deps
deps="growpart cat sfdisk grep sed awk partx e2fsck resize2fs partprobe readlink"
for dep in $deps
do
    path=`which $dep`
    dir=`dirname $path`
    mkdir -p ./$dir
    cp -pv $path ./$path
    libs=`ldd $path | cut -d ' ' -f 3 | xargs`
    for lib in $libs
    do
	dir=`dirname $lib`
	mkdir -p ./$dir
	cp -pv $lib ./$lib
    done
done

# rebuild initrd
find . | cpio -o -H newc | gzip > ../$initrd
cd ..

#
# Build a 1GB image file to hold the tarball...
#
out=ubuntu-core-14.04.1-core-arm64.img

dd if=/dev/zero of="$out" bs=1M count=1024
dd conv=notrunc if=$DIRNAME/etc/mbr.img of="$out" bs=2048 count=1
ld=`losetup --show -f "$out"`
partprobe $ld
echo "*** making a new ext4 filesystem ..."
# if we don't pass 1024*1024*1023/4096 (size in blocks), mke2fs will make
# the fs 1024*1024*1024/4096 --- not factoring the offset into the estimated
# automatic size.  This must be a bug...
mke2fs -t ext4 ${ld}p1
mkdir -p mnt
mount ${ld}p1 mnt

echo "*** adding contents of core tarball ..."
tar xzf "$core" -C mnt

echo "*** fixing root password ..."
#sed -i -e "s@root:[^:]*:@root:${ADMIN_PASS_HASH}:@" mnt/etc/shadow
sed -i -e "s@root:[^:]*:@root:!:@" mnt/etc/shadow

echo "*** fixing ubuntu password ..."
grep ^ubuntu /etc/passwd
if [ $? -eq 0 ]; then
    sed -i -e "s@ubuntu:[^:]*:@ubuntu:${ADMIN_PASS_HASH}:@" mnt/etc/shadow
else
    # Have to add the user so that the passwd is actually set...
    echo "ubuntu:x:1000:1000:Ubuntu:/home/ubuntu:/bin/bash" >> mnt/etc/passwd
    echo "ubuntu:!:16731:0:99999:7:::" >> mnt/etc/shadow
    echo "ubuntu:x:1000:" >> mnt/etc/group
    echo "ubuntu:!::" >> mnt/etc/gshadow

    mkdir -p mnt/home/ubuntu
    chown 1000:1000 mnt/home/ubuntu

    sed -i -e "s@ubuntu:[^:]*:@ubuntu:${ADMIN_PASS_HASH}:@" mnt/etc/shadow
fi

umount mnt

#
# If we didn't download it, build it from scratch.
#
if [ ${BUILD_AARCH64_FROM_CORE} = 1 ] ; then
    mount ${ld}p1 mnt

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
    # through a GRE tunnel.  Also, add a second interface because our default
    # config has two interfaces -- a GRE tunnel data net, and a flat data "control"
    # net.
    #
    # NB: actually the MTU is reduced on the server side now.
    #
    cp -p mnt/etc/network/interfaces ./etc.network.interfaces.ORIG
    echo "*** adding networking for qemu ..."
    {
	cat - <<EOM

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOM
    } | tee -a mnt/etc/network/interfaces >/dev/null

    echo 'Acquire::CompressionTypes::Order { "gz"; "bz2"; }' | tee mnt/etc/apt/apt.conf.d/99gzip >/dev/null

    echo "*** unmounting ..."
    umount mnt

    # cp, upload later
    cp -p $out $out.1

    #
    # Now do another one, with sshd installed
    #
    mount ${ld}p1 mnt

    echo "*** installing ssh/sshd..."
    echo "nameserver 8.8.8.8" > mnt/etc/resolv.conf
    chroot mnt /usr/bin/apt-get update
    chroot mnt /usr/bin/apt-get $APTGETINSTALLOPTS openssh-server openssh-client
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

    cp -p $out $out.2

    #
    # Now do another one, with cloud-init installed
    #
    mount ${ld}p1 mnt

    echo "*** installing cloud-init and cloud-guest-utils..."
    chroot mnt /usr/bin/apt-get update
    chroot mnt /usr/bin/apt-get install $APTGETINSTALLOPTS cloud-guest-utils cloud-init

    # permit root login!!
    sed -i -e 's/^disable_root: true$/disable_root: false/' mnt/etc/cloud/cloud.cfg

    # don't overwrite the Ubuntu passwd we just hacked in
    sed -i -e 's/^.*lock_passwd:.*$/     lock_passwd: False/' mnt/etc/cloud/cloud.cfg

    echo "*** unmounting ..."
    umount mnt

    cp -p $out $out.3
fi

GLANCEOPTS=""
if [ "$OSCODENAME" = "juno" -o "$OSCODENAME" = "kilo" ]; then
    GLANCEOPTS="--is-public True"
fi

echo "*** Importing kernel/ramdisk ..."

glance image-create --name vmlinuz-3.13.0-40-arm64-generic ${GLANCEOPTS} --progress --file vmlinuz-3.13.0-40-arm64-generic --disk-format aki --container-format aki

if [ $OSVERSION -ge $OSLIBERTY ]; then
    KERNEL_ID=`glance image-list | awk ' / vmlinuz-3.13.0-40-arm64-generic / { print $2 }'`
else
    KERNEL_ID=`glance image-show vmlinuz-3.13.0-40-arm64-generic | grep id | sed -n -e 's/^.*id.*| \([0-9a-zA-Z-]*\).*$/\1/p'`
fi

glance image-create --name initrd-3.13.0-40-arm64-generic ${GLANCEOPTS} --progress --file initrd.img-3.13.0-40-arm64-generic --disk-format ari --container-format ari

if [ $OSVERSION -ge $OSLIBERTY ]; then
    RAMDISK_ID=`glance image-list | awk ' / initrd-3.13.0-40-arm64-generic / { print $2 }'`
else
    RAMDISK_ID=`glance image-show initrd-3.13.0-40-arm64-generic | grep id | sed -n -e 's/^.*id.*| \([0-9a-zA-Z-]*\).*$/\1/p'`
fi

echo "*** Importing image with cloud-guest-utils  ..."

glance image-create --name trusty-server ${GLANCEOPTS} --progress --file $out --disk-format ami --container-format ami
if [ $OSVERSION -ge $OSLIBERTY ]; then
    TRUSTY_SERVER_ARG=`glance image-list | awk ' / trusty-server / { print $2 }'`
else
    TRUSTY_SERVER_ARG='trusty-server'
fi
glance image-update --property kernel_args="console=ttyAMA0 root=/dev/sda" $TRUSTY_SERVER_ARG
glance image-update --property kernel_id=${KERNEL_ID} $TRUSTY_SERVER_ARG
glance image-update --property ramdisk_id=${RAMDISK_ID} $TRUSTY_SERVER_ARG
glance image-update --property root_device_name=/dev/vda1 $TRUSTY_SERVER_ARG
if [ $OSVERSION -ge $OSLIBERTY ]; then
    glance image-update --property hw_video_model=vga $TRUSTY_SERVER_ARG
fi

echo "*** Creating image with cloud-guest-utils AND multi-nic support ..."

mount ${ld}p1 mnt

#
# Just blow it away -- the cloud guest utils handle this.
# Well, actually, to add extra devices in there, we have to customize
# the upstart config... anyway, give them 8 devices by default!
#
cat <<EOF >mnt/etc/network/interfaces
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
sed -i -e 's/^start on (local-filesystems$/start on (mounted MOUNTPOINT=\//' mnt/etc/init/networking.conf

#
# Handle ethX devices that aren't actually in the VM instance by faking
# that they are up so that startup doesn't get hung and timeout.  Our hack
# only looks for ^eth\d*$ devices, and skips them if they're not accessible
# via ifconfig.  This should be pretty safe, and it doesn't block things 
# like bridges, ovs devices, tun/tap, etc.
#
cp -p $DIRNAME/etc/if-pre-up-upstart-faker mnt/etc/network/if-pre-up.d/

echo "*** umounting..."

umount mnt

echo "*** Importing image with cloud-guest-utils AND multi-nic support ..."

glance image-create --name trusty-server-multi-nic ${GLANCEOPTS} --progress --file $out --disk-format ami --container-format ami
if [ $OSVERSION -ge $OSLIBERTY ]; then
    TRUSTY_SERVER_MN_ARG=`glance image-list | awk ' / trusty-server-multi-nic / { print $2 }'`
else
    TRUSTY_SERVER_MN_ARG='trusty-server-multi-nic'
fi
glance image-update --property kernel_args="console=ttyAMA0 root=/dev/sda" $TRUSTY_SERVER_MN_ARG
glance image-update --property kernel_id=${KERNEL_ID} $TRUSTY_SERVER_MN_ARG
glance image-update --property ramdisk_id=${RAMDISK_ID} $TRUSTY_SERVER_MN_ARG
glance image-update --property root_device_name=/dev/vda1 $TRUSTY_SERVER_MN_ARG
if [ $OSVERSION -ge $OSLIBERTY ]; then
    glance image-update --property hw_video_model=vga $TRUSTY_SERVER_MN_ARG
fi

if [ ${BUILD_AARCH64_FROM_CORE} = 1 ] ; then
    echo "*** Importing non-ssh image ..."

    glance image-create --name ubuntu-core-14.04.1-core-arm64 ${GLANCEOPTS} --progress --file $out.1 --disk-format ami --container-format ami

    if [ $OSVERSION -ge $OSLIBERTY ]; then
	IMAGEARG=`glance image-list | awk ' / ubuntu-core-14.04.1-core-arm64 / { print $2 }'`
    else
	IMAGEARG='ubuntu-core-14.04.1-core-arm64'
    fi

    glance image-update --property kernel_args="console=ttyAMA0 root=/dev/sda" ubuntu-core-14.04.1-core-arm64
    glance image-update --property kernel_id=${KERNEL_ID} $IMAGEARG
    glance image-update --property ramdisk_id=${RAMDISK_ID} $IMAGEARG
    glance image-update --property root_device_name=/dev/vda1 $IMAGEARG
    if [ $OSVERSION -ge $OSLIBERTY ]; then
	glance image-update --property hw_video_model=vga $IMAGEARG
    fi

    echo "*** Importing image with sshd ..."

    glance image-create --name ubuntu-core-14.04.1-core-arm64-sshd ${GLANCEOPTS} --progress --file $out.2 --disk-format ami --container-format ami

    if [ $OSVERSION -ge $OSLIBERTY ]; then
	IMAGEARG=`glance image-list | awk ' / ubuntu-core-14.04.1-core-arm64-sshd / { print $2 }'`
    else
	IMAGEARG='ubuntu-core-14.04.1-core-arm64-sshd'
    fi

    glance image-update --property kernel_args="console=ttyAMA0 root=/dev/sda" ubuntu-core-14.04.1-core-arm64-sshd
    glance image-update --property kernel_id=${KERNEL_ID} $IMAGEARG
    glance image-update --property ramdisk_id=${RAMDISK_ID} $IMAGEARG
    glance image-update --property root_device_name=/dev/vda1 $IMAGEARG
    if [ $OSVERSION -ge $OSLIBERTY ]; then
	glance image-update --property hw_video_model=vga $IMAGEARG
    fi
fi

umount mnt
rmdir mnt
losetup -d ${ld}

exit 0
