#!/bin/bash

# Variables
LOGFILE=~/gentoo-autoinstall.log

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

get_bootmode

select_drive