#!/bin/sh


# Adding colors for output:
    red="\e[0;91m"
    green="\e[0;92m"
    blue="\e[0;94m"
    bold="\e[1m"
    reset="\e[0m"

#
##
###
####
##### 0. pre-checking
    echo -e "${bold}Starting Installer:${reset}"

# Checks if script is run as root
    echo "Checking if command is run as root:"
    ID=$(id -u)
    if [ "$ID" -ne "0" ];
        then
            echo -e "${red}[FAILED]${reset}"
            exit
        else
            echo -e "${green}[OK]${reset}"
    fi

# Checks if networking works
    echo "Checking internet connection:"
    ping -c 3 gentoo.org > /dev/null && echo -e "${green}[OK]${reset}" || echo -e "${red}[FAILED]${reset}"

#
##
###
####
##### 1. Partitioning
 echo -e "${bold}---- Starting Partitioning ----${reset}" &&

  #displays drives over 1GiB to the User
    echo "Starting disk Partitioning"
    echo -e "Following disks are recommendet:"
    echo -e "${bold}"
    sfdisk -l | grep "GiB" &&
    echo -e "${reset}"

  #takes user input and removes existing partitions
    read -p "Please enter the path of the desired Disk for your new System: " DSK &&
    echo -e "${red}This will remove all existing partitions on "$DSK". ${reset}"
    while true; do
        read -p "Are you sure? [y/n]" YN
        case $YN in
            [Yy]* ) dd if=/dev/zero of=$DSK bs=512 count=1 conv=notrunc; break; echo"done";;
            [Nn]* )  echo "you selected no"; exit;;
            * ) echo "Please answer yes or no.";;
        esac
    done

    echo -e "${green}REMOVING EXISTING FILESYSTEMS${reset}" &&

  #checks and prints used bootmode.
    if ls /sys/firmware/efi/efivars ; then
      BOOTMODE=UEFI
    else
      BOOTMODE=BIOS
    fi
    echo bootmode detected: $BOOTMODE &&

  #creating swap partition
    #get RAM size
    RAM=$(free -g | grep Mem: | awk '{print $2}') &&

    #setting swapsize variable to RAMsize+4G
    #SWAPSIZE=$(expr $RAM + 4) &&
    SWAPSIZE=$(expr $RAM - $RAM + 2) &&
    echo "SWAPSIZE = "  $SWAPSIZE &&

  #creating efi, swap, root partition for UEFI systems; creating swap, root partition for BIOS systems
  if [ $BOOTMODE = UEFI ]; then printf "n\np\n \n \n+1G\nn\np\n \n \n+"$SWAPSIZE"G\nn\np\n \n \n \nw\n" | fdisk $DSK; else printf "n\np\n \n \n+"$SWAPSIZE"G\nn\np\n \n \n \nw\n" | fdisk $DSK; fi
  partprobe $DSK &&
  #getting paths of partitions
  PARTITION1=$(fdisk -l $DSK | grep $DSK | sed 1d | awk '{print $1}' | sed -n "1p") &&
  PARTITION2=$(fdisk -l $DSK | grep $DSK | sed 1d | awk '{print $1}' | sed -n "2p") &&
  if [ $BOOTMODE = UEFI ]; then PARTITION3=$(fdisk -l $DSK | grep $DSK | sed 1d | awk '{print $1}' | sed -n "3p"); else echo "No third Partition needet."; fi


  #declaring partition paths as variables
  if [ $BOOTMODE = UEFI ]; then
    EFIPART=$PARTITION1
    SWAPPART=$PARTITION2
    ROOTPART=$PARTITION3
  else
    EFIPART="NOT DEFINED"
    SWAPPART=$PARTITION1
    ROOTPART=$PARTITION2
  fi

#filesystem creation
    #efi partition
     if [ $BOOTMODE = UEFI ]; then mkfs.fat -F32 $EFIPART; fi

     #swap partition
     mkswap $SWAPPART &&



     echo $ROOTPART

     #root partition
     mkfs.ext4 $ROOTPART &&


    #swap partition
    swapon $SWAPPART &&

  #filesystem mounting / enabling swapspace
    #root partition
    mount $ROOTPART /mnt/gentoo &&

    #efi
    if [ $BOOTMODE = UEFI ]; then
      mkdir /mnt/gentoo/boot
      mount $EFIPART /mnt/gentoo/boot;
    fi



  echo -e "${bold}---- Finished Partitioning ----${reset}" &&
  printf "\n\n"

  echo -e "${bold} Downloading latest Stage3 tarball:${reset}" &&


# this function is taken from:
# Written by: https://github.com/jeekkd
# Website: https://daulton.ca
function stage3Download() {
	printf "\n"
	printf "Downloading the stage 3 tarball... \n"	

	ARCH=amd64
	MICROARCH=amd64
	SUFFIX=openrc
	DIST="https://ftp.fau.de/gentoo/releases/${ARCH}/autobuilds"
	STAGE3PATH="$(wget -q -O- "${DIST}/latest-stage3-${MICROARCH}-${SUFFIX}.txt" | tail -n 1 | cut -f 1 -d ' ')"
	wget -q --show-progress "${DIST}/${STAGE3PATH}"
}
stage3Download

tar xpvf stage3-amd64-openrc-*.tar.xz --xattrs-include='*.*' --numeric-owner --directory /mnt/gentoo/

cp configs/make.conf /mnt/gentoo/etc/portage/make.conf

mirrorselect -i -o >> /mnt/gentoo/etc/portage/make.conf

mkdir --parents /mnt/gentoo/etc/portage/repos.conf
cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc/
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

chroot /mnt/gentoo /bin/bash -- << EOCHROOT
    source /etc/profile
    emerge-webrsync
    eselect profile set 1
    emerge --verbose --update --deep --newuse @world
    echo "Europe/Vienna" > /etc/timezone
    emerge --config sys-libs/timezone-data
    emerge vim neofetch
    echo "en_US ISO-8859-1" >> /etc/locale.gen
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen
    eselect locale set 4
    env-update && source /etc/profile
    echo "sys-kernel/linux-firmware @BINARY-REDISTRIBUTABLE" | tee -a /etc/portage/package.license
    emerge sys-kernel/linux-firmware sys-apps/pciutils
    emerge sys-kernel/gentoo-kernel-bin
    emerge net-misc/dhcpcd netifrc
    rc-update add dhcpcd default
    rc-service dhcpcd start
    INTERF=$(ip a | grep "state UP" | awk '{print $2}' | head -n 1 | sed s'/.$//')
    echo 'config_'$INTERF'="dhcp"' > /etc/conf.d/net
    cd /etc/init.d/
    ln -s net.lo net.$INTERF
    rc-update add net.$INTERF default
    emerge sudo
    echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers &&
    echo "%wheel ALL=(ALL) NOPASSWD: /sbin/poweroff, /sbin/reboot, /sbin/shutdown" >> /etc/sudoers &&
    passwd -l root &&
    emerge sys-boot/grub
    grub-install --target=x86_64-efi --efi-directory=/boot
    grub-mkconfig -o /boot/grub/grub.cfg
    sv-update add elogind default

EOCHROOT

echo $SWAPPART " none swap sw 0 0" >> /mnt/gentoo/etc/fstab
echo $ROOTPART " / ext4 noatime 0 1" >> /mnt/gentoo/etc/fstab
if [ $BOOTMODE = UEFI ]; then echo $EFIPART " /boot ext4 noauto,noatime 0 2" >> /mnt/gentoo/etc/fstab ; fi

echo 'keymap="de-latin1"' > /mnt/gentoo/etc/conf.d/keymaps
echo 'windowkeys="YES"' >> /mnt/gentoo/etc/conf.d/keymaps
echo 'dumpkeys_charset=""' >> /mnt/gentoo/etc/conf.d/keymaps
echo 'fix_euro="YES"' >> /mnt/gentoo/etc/conf.d/keymaps

echo "creating new User" &&
read -p "Please enter a valid username: " USRNME &&
chroot /mnt/gentoo useradd -m $USRNME &&
chroot /mnt/gentoo passwd $USRNME &&
chroot /mnt/gentoo usermod -a -G wheel $USRNME &&

echo "setting hostname:" &&
read -p "Please enter a valid Hostname : " CHN &&
echo 'hostname="'$CHN'"' > /mnt/gentoo/etc/conf.d/hostname &&
echo "done!" &&




chroot /mnt/gentoo neofetch
echo "enjoy your new gentoo installation!"
echo "you can reboot now."