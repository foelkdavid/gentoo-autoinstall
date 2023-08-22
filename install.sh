#!/bin/bash

# Variables
LOGFILE=~/gentoo-autoinstall.log
ZFSPOOLNAME=jacuzzi
SWAPSIZE="2G" # TODO: implement lol

# Adding colors for output:
red="\e[0;91m"
green="\e[0;92m"
blue="\e[0;94m"
yellow="\e[0;93m"
bold="\e[1m"
reset="\e[0m"

# convenience:
fail() { echo -e "${red}[FAILED]${reset}"; }

failexit() {
    fail
    exit
}
ok() { echo -e "${green}[OK]${reset}"; }

skipped() { echo -e "${yellow}[SKIPPED]${reset}"; }

# checks if command is run as root / sudo
rootcheck() { [ $(id -u) -eq 0 ] && return 0 || return 1; }

# naive connectivity check
networkcheck() { ping -c 3 www.gentoo.org > $LOGFILE && return 0 || return 1; }

# selects and formats selected drive
select_drive(){
    echo "Starting disk Partitioning"
    echo -e "Found disks: (>1G)"
    echo -e "${bold}"
    sfdisk -l | grep "GiB" &&
    echo -e "${reset}"

    read -p "Please enter the path of the desired Disk for your new System: " SYSTEMDISK &&
    echo -e "${red}This will start the installation on "$SYSTEMDISK". ${reset}"
    while true; do
        read -p "Are you sure? [y/n]" YN
        case $YN in
            [Yy]* )  break; echo"done";;
            [Nn]* )  echo "you selected no"; exit;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}


get_bootmode(){
    #checks and prints used bootmode.
    if ls /sys/firmware/efi/efivars >> $LOGFILE ; then
      BOOTMODE=UEFI
      printf "Bootmode detected: ${blue}$BOOTMODE${reset} " && ok
    else
      BOOTMODE=BIOS
      printf "Bootmode detected: ${blue}$BOOTMODE${reset} " && fail
      printf "This installer only supports UEFI.\n" && exit
    fi
}

# partitions the disk like this:
# Number  Start    End       Size      File system  Name    Flags
#  1      1.00MiB  513MiB    512MiB                 EFI     boot, esp
#  2      513MiB   1537MiB   1024MiB                boot
#  3      1537MiB  3585MiB   2048MiB                swap
#  4      3585MiB  20479MiB  16894MiB               rootfs
format_disk(){
    wipefs -af $SYSTEMDISK >> /dev/null &&
    printf "unit mib\nmklabel gpt\n\nmkpart EFI 1 513\nmkpart boot 513 1537\nmkpart swap 1537 3585\nmkpart rootfs 3585 -1\nset 1 boot on\nprint\nquit" | parted -a optimal /dev/sda >> /dev/null
    EFIPARTITION=$(fdisk -l $SYSTEMDISK | grep $SYSTEMDISK | sed 1d | awk '{print $1}' | sed -n "1p")
    BOOTPARTITION=$(fdisk -l $SYSTEMDISK | grep $SYSTEMDISK | sed 1d | awk '{print $1}' | sed -n "2p")
    SWAPPARTITION=$(fdisk -l $SYSTEMDISK | grep $SYSTEMDISK | sed 1d | awk '{print $1}' | sed -n "3p")
    ROOTPARTITION=$(fdisk -l $SYSTEMDISK | grep $SYSTEMDISK | sed 1d | awk '{print $1}' | sed -n "4p")
mkfs.fat -F32 $EFIPARTITION
  }


setup_zfs(){
    printf "Setting up encrypted ZFS:\n"
    /sbin/modprobe zfs
    zpool create -f -o ashift=12 -o cachefile= -O compression=lz4 -O encryption=on -O keyformat=passphrase -O atime=off -m none -R /mnt/gentoo $ZFSPOOLNAME $ROOTPARTITION
    zfs create $ZFSPOOLNAME/os
    zfs create -o mountpoint=/ $ZFSPOOLNAME/os/main
    zfs create -o mountpoint=/home $ZFSPOOLNAME/home
    zpool create -f -d -o ashift=12 -o cachefile= -m /boot -R /mnt/gentoo boot $BOOTPARTITION
}

create_swap(){
    mkswap -f $SWAPPARTITION
    swapon $SWAPPARTITION
}



# this function is taken from:
# Written by: https://github.com/jeekkd
# Website: https://daulton.ca
stage3Download() {
	printf "\n"
	printf "Downloading the stage 3 tarball... \n"	

	ARCH=amd64
	MICROARCH=amd64
	SUFFIX=desktop-systemd
	DIST="https://ftp.fau.de/gentoo/releases/${ARCH}/autobuilds"
	STAGE3PATH="$(wget -q -O- "${DIST}/latest-stage3-${MICROARCH}-${SUFFIX}.txt" | tail -n 1 | cut -f 1 -d ' ')"
	wget -q --show-progress "${DIST}/${STAGE3PATH}"
}

chroot_preparation_old(){
    cd /mnt/gentoo
    mkdir boot/efi
    mount $EFIPARTITION boot/efi

    stage3Download
    tar xpvf stage3-amd64-$SUFFIX-*.tar.xz --xattrs-include='*.*' --numeric-owner --directory /mnt/gentoo/
    mkdir etc/zfs
    cp /etc/zfs/zpool.cache etc/zfs

    mirrorselect -s3 -b10 -R Europe -D -o >> /mnt/gentoo/etc/portage/make.conf
    mkdir --parents /mnt/gentoo/etc/portage/repos.conf
    cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

    mount --rbind /dev dev
    mount --rbind /proc proc
    mount --rbind /sys sys
    mount --make-rslave dev
    mount --make-rslave proc
    mount --make-rslave sys
}


chroot_preparation(){
    chronyd -q
    cd /mnt/gentoo
    mkdir boot/efi
    mount $EFIPARTITION boot/efi
    stage3Download
    tar xpf stage3-amd64-$SUFFIX-*.tar.xz
    
    # copy zfs pool
    mkdir etc/zfs
    cp /etc/zfs/zpool.cache etc/zfs

    # copy networking settings
    cp /etc/resolv.conf etc/

    # mount devices
    mount --rbind /dev dev
    mount --rbind /proc proc
    mount --rbind /sys sys
    mount --make-rslave dev
    mount --make-rslave proc
    mount --make-rslave sys

}

write_chroot_script(){
    TMPFILE=/mnt/gentoo/tmp/chroot.sh
    echo "#!/bin/bash" > $TMPFILE
    echo "echo '$BOOTPARTITION    /boot/efi    vfat    noauto    1 2' > /etc/fstab" >> $TMPFILE
    echo "echo '$SWAPPARTITION    none         swap    sw        0 0' >> /etc/fstab" >> $TMPFILE

    echo "echo 'EMERGE_DEFAULT_OPTS=\"--with-bdeps=y --keep-going=y --quiet-build=y\"' >> /etc/portage/make.conf" >> $TMPFILE
    echo "echo 'GRUB_PLATFORMS=\"efi-64\"' >> /etc/portage/make.conf" >> $TMPFILE

    echo "cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf" >> $TMPFILE
    echo "emerge --sync --quiet" >> $TMPFILE

    echo "echo 'sys-kernel/gentoo-kernel-bin -initramfs' >> /etc/portage/package.use/gentoo-kernel-bin" >> $TMPFILE
    echo "emerge gentoo-kernel-bin" >> $TMPFILE
    echo "emerge --noreplace =gentoo-kernel-bin-6.1.46 ">> $TMPFILE
    #TODO pin kernel or get autokernelver

    echo "echo 'sys-boot/grub libzfs' >> /etc/portage/package.used" >> $TMPFILE

    echo "emerge bliss-initramfs grub zfs dhcpcd neovim neofetch htop" >> $TMPFILE

    echo "grub-probe /boot" >> $TMPFILE
    echo "grub-probe /boot/efi" >> $TMPFILE

    echo "mount -o remount,rw /sys/firmware/efi/efivars/  " >> $TMPFILE
    echo "grub-install --efi-directory /boot/efi" >> $TMPFILE
    echo "echo 'set default=0' > /boot/grub/grub.cfg " >> $TMPFILE
    echo "echo 'set timeout=1' >> /boot/grub/grub.cfg " >> $TMPFILE
    echo "echo 'insmod part_gpt' >> /boot/grub/grub.cfg" >> $TMPFILE
    echo "echo 'insmod fat' >> /boot/grub/grub.cfg" >> $TMPFILE
    echo "echo 'insmod efi_gop' >> /boot/grub/grub.cfg" >> $TMPFILE
    echo "echo 'insmod efi_uga' >> /boot/grub/grub.cfg" >> $TMPFILE

    echo "echo 'menuentry \"Gentoo 6.1.46\" {' >> /boot/grub/grub.cfg" >> $TMPFILE
    echo "echo 'linux /@/vmlinuz-6.1.46-gentoo-dist root=jacuzzi/os/main by=id elevator=noop quiet logo.nologo refresh' >> /boot/grub/grub.cfg" >> $TMPFILE
    echo "echo 'initrd /@/initrd-6.1.46-gentoo-dist' >> /boot/grub/grub.cfg" >> $TMPFILE

    #TODO include kernel modules here

    echo "bliss-initramfs -k 6.1.46-genoot-dist" >> $TMPFILE
    echo "mv initrd-6.1.46-gentoo-dist /boot" >> $TMPFILE

    echo "systemctl enable zfs.target" >> $TMPFILE
    echo "systemctl enable zfs-import-cache" >> $TMPFILE
    echo "systenctl enable zfs-mount" >> $TMPFILE
    echo "systemctl enable zfs-import.target" >> $TMPFILE

    echo "passwd" >> $TMPFILE

}

chroot(){
    chmod +x /mnt/gentoo/tmp/chroot.sh
    chroot /mnt/gentoo /tmp/chroot.sh
    echo "Done"
}

rootcheck

networkcheck

get_bootmode


select_drive

format_disk

setup_zfs

create_swap

chroot_preparation

write_chroot_script

chroot

# TODO fix cannot change locale error
# TODO set system time? 
