#!/bin/bash
set -ex
#### Define repository variable
REPO="http://pkgmaster.devuan.org/merged"
if [[ "$1" != "" ]] ; then
    REPO="$1"
fi
#### install required packages if host debian
if [[ -d /var/lib/apt/ ]] ; then
    apt update
    apt install qemu-user-static binfmt-support debootstrap wget unzip qemu-utils -y
fi
mkdir -p work
cd work
#### fetch device firmware (prebuilt)
[[ -f firmware.zip ]] || wget -c https://github.com/raspberrypi/firmware/archive/refs/heads/master.zip -O firmware.zip
yes "A" | unzip firmware.zip
cd ..
mkdir -p rootfs/boot
cp -rvf work/firmware-master/boot/* rootfs/boot/
cat > rootfs/boot/cmdline.txt << EOF
console=ttyS1,115200 console=tty0 root=/dev/mmcblk0p2 rootfstype=ext4 rw net.ifnames=0 rootwait
EOF
cat > rootfs/boot/config.txt << EOF
# Switch the CPU from ARMv7 into ARMv8 (aarch64) mode
arm_64bit=1

enable_uart=1
upstream_kernel=1

## memory shared with the GPU
gpu_mem=128

## always audio
dtparam=audio=on

## maximum amps on usb ports
max_usb_current=1

## enable hardware-accelerated graphics
dtoverlay=vc4-kms-v3d

## kernel
kernel=kernel8.img

## overclock
arm_freq=2300
gpu_freq=750
over_voltage=8
force_turbo=1

EOF
##### create rootfs
[[ -f work/rootfs/etc/os-release ]] || debootstrap --foreign --no-check-gpg --no-merged-usr --variant=minbase --arch=arm64 stable work/rootfs "$REPO"
##### copy qemu-aarch64-static
cp $(which qemu-aarch64-static) work/rootfs/usr/bin/qemu-aarch64-static
if which service ; then
    service binfmt-support start
fi
#### Configure system
echo "nameserver 1.1.1.1" > work/rootfs/etc/resolv.conf
echo "APT::Sandbox::User root;" > work/rootfs/etc/apt/apt.conf.d/99sandboxroot
cat > work/rootfs/etc/apt/apt.conf.d/01norecommend << EOF
APT::Install-Recommends "0";
APT::Install-Suggests "0";
EOF
[[ ! -f work/rootfs/debootstrap/debootstrap ]] || chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/bash /debootstrap/debootstrap --second-stage
chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/bash -c "apt install devuan-keyring kmod -y"
##### install firmware and packages
mkdir -p work/rootfs/lib/modules/
cp -rvf work/firmware-master/modules/* work/rootfs/lib/modules/
echo "deb $REPO stable main contrib non-free" > work/rootfs/etc/apt/sources.list
chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/bash -c "apt update"
chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/bash -c "apt install network-manager openssh-server -y"
chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/bash -c "apt install firmware-linux -y"
chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/bash -c "apt clean"
for i in $(ls work/rootfs/lib/modules) ; do
    chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/bash -c "depmod -a $i"
done
#### create image and partitons
size=$(du -s "work/rootfs" | cut -f 1)
qemu-img create "devuan.img" $(($size*1500+300*1024*1024))
parted "devuan.img" mklabel msdos
echo Ignore | parted "devuan.img" mkpart primary fat32 0 300M 
echo Ignore | parted "devuan.img" mkpart primary ext2 301M 100%
#### format image
losetup -d /dev/loop0 || true
loop=$(losetup --partscan --find --show "devuan.img" | grep "/dev/loop")
mkfs.vfat ${loop}p1
yes | mkfs.ext4 ${loop}p2 -L "ROOTFS"
#### copy boot partition
mount ${loop}p1 /mnt
cp -prfv rootfs/boot/* /mnt/
sync
umount -f /mnt
#### copy rootfs partition
mount ${loop}p2 /mnt
cp -prfv work/rootfs/* /mnt/
sync
umount /mnt
xz devuan.img
#### done
