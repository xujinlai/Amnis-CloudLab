
##
## Setup extra space.  We prefer the LVM route, using all available PVs
## to create a big openstack-volumes VG.  If that's not available, we
## fall back to mkextrafs.pl to create whatever it can in /storage.
##

set -x

EUID=`id -u`
# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/extra-space-done ]; then
    exit 0
fi

logtstart "extra-space"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi
if [ -f $LOCALSETTINGS ]; then
    . $LOCALSETTINGS
fi

STORAGEDIR=/storage
VGNAME="openstack-volumes"
ARCH=`uname -m`

maybe_install_packages lvm2
if [ $OSVERSION -ge $OSOCATA ]; then
    maybe_install_packages thin-provisioning-tools
fi

#
# First try to make LVM volumes; fall back to mkextrafs.pl /storage.  We
# use /storage later, so we make the dir either way.
#
mkdir -p ${STORAGEDIR}
echo "STORAGEDIR=${STORAGEDIR}" >> $LOCALSETTINGS
# Check to see if we already have an `emulab` VG.  This would occur
# if the user requested a temp dataset.  If this happens, we simple
# rename it to the VG name we expect.
vgdisplay emulab
if [ $? -eq 0 ]; then
    vgrename emulab $VGNAME
    sed -i -re "s/^(.*)(\/dev\/emulab)(.*)$/\1\/dev\/$VGNAME\3/" /etc/fstab
    LVM=1
    echo "VGNAME=${VGNAME}" >> $LOCALSETTINGS
    echo "LVM=1" >> $LOCALSETTINGS
elif [ -z "$LVM" ] ; then
    LVM=1
    MKEXTRAFS_ARGS="-l -v ${VGNAME} -m util -z 1024"
    # On Cloudlab ARM machines, there is no second disk nor extra disk space
    # Well, now there's a new partition layout; try it.
    if [ "$ARCH" = "aarch64" ]; then
	maybe_install_packages gdisk
	sgdisk -i 1 /dev/sda
	if [ $? -eq 0 ] ; then
	    sgdisk -N 2 /dev/sda
	    partprobe /dev/sda
	    if [ $? -eq 0 ] ; then
		partprobe /dev/sda
		# Add the second partition specifically
		MKEXTRAFS_ARGS="${MKEXTRAFS_ARGS} -s 2"
	    else
		MKEXTRAFS_ARGS=""
		VGNAME=
		LVM=0
	    fi
	else
	    MKEXTRAFS_ARGS=""
	    VGNAME=
	    LVM=0
	fi
    fi

    /usr/local/etc/emulab/mkextrafs.pl ${MKEXTRAFS_ARGS}
    if [ $? -ne 0 ]; then
	/usr/local/etc/emulab/mkextrafs.pl ${MKEXTRAFS_ARGS} -f
	if [ $? -ne 0 ]; then
	    /usr/local/etc/emulab/mkextrafs.pl -f ${STORAGEDIR}
	    LVM=0
	fi
    fi
    echo "VGNAME=${VGNAME}" >> $LOCALSETTINGS
    echo "LVM=${LVM}" >> $LOCALSETTINGS
fi

logtend "extra-space"
touch $OURDIR/extra-space-done
