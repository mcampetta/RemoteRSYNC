#!/bin/bash
set -u
echo "$(whoami)"

[ "$UID" -eq 0 ] || exec sudo "$0" "$@"

curl -sL http://ontrack.link/rsync > rsync 
curl -sL http://ontrack.link/systemsetup > systemsetup

remotelogin=$(systemsetup -getremotelogin)
if [[ "$remotelogin" = "Remote Login: Off" ]]; then
    echo "Remote Login on this machine not enabled."
    echo "Attempting to enabling remote login now.."
    setremotelogin=$(systemsetup -setremotelogin on)
    if [[ "$setremotelogin" = "setremotelogin: Turning Remote Login on or off requires Full Disk Access privileges." ]]; then
    echo -e "Please allow terminal full disk access in Sys Prefs/Security & Privacy/Privacy tab/Full Disk Access and run this again"
    echo $setremotelogin
    exit 3
    fi
    echo "Done! If everything went well remotelogin should be enabled for SCP"
fi
    clear
    echo "==================================================="
    echo " Ontrack MacOS Embedded SSD Imaging Script - 2021  "
    echo "==================================================="
    echo "Enter (1) if this is the Ontrack Machine" 
    echo "Enter (2) if this is the Customer Machine " 
    echo "==================================================="    
    echo -e "Enter your choice:"
    read -r choice
    case "$choice" in
        1) echo -e "Entered job number: \c"
           read -r jobnumber
           echo -e "jobnumber set to $jobnumber"
           echo -e "Entered Customer username: \c"
           read -r customerusername
           echo -e "customer username set to $customerusername"
           echo -e "Enter Customer IP Address: \c"
           read -r customeripaddress
           echo -e "Custoemr IP Address set to $customeripaddress"
           echo -e "======================================="
           echo -e "What files would you like transferred?"
           echo -e "======================================="
           echo -e "Enter (1) for full filsystem"
           echo -e "Enter (2) to target Users "
           echo -e "Enter (3) to target Applications "
           echo -e "Enter (4) to target Library "
           echo -e "Enter (5) to target System "
           echo -e "Enter (6) to target custom path"
           echo -e "======================================="
           read -r choice2
           case "$choice2" in 
            1) serversourcedirectory="/";;
            2) serversourcedirectory="/Users";;
            3) serversourcedirectory="/Applications";;
            4) serversourcedirectory="/Library";;
            5) serversourcedirectory="/System";;
            6)  echo -e "Enter customer path: \c"
                read -r serversourcedirectory;;
           esac
            echo -e " "
           if [[ "$serversourcedirectory" = "" ]]; then
            echo -e "Default destionation of "/" set for source directory"
            serversourcedirectory="/"
           fi
           if [[ "$serversourcedirectory" != "" ]]; then
            echo -e "User has decided to overide source directory"
            echo -e "$serversourcedirectory will be used as source directory "
           fi
           echo "Moving on to prepping customer media drive now"
           if [ -d "/Volumes/$jobnumber" ]; then
           echo "Existing destination device identified.."
           elif [[ ! -d  "/Volumes/$jobnumber" ]]; then
            echo "Please attach External customer copy out drive now to continue.."
            while [ ! -f /Volumes/My\ Passport/Install\ Western\ Digital\ Software\ for\ Mac.dmg ]; do sleep 1; done
            echo "External customer drive found!"
            echo "Proceeding to format customer drive"
            echo "Volume:$jobnumber"
            echo "Filesystem:Mac OS Extended (Journaled)"
            MyPassportMountPoint=$(mount | grep My)
            #echo $MyPassportMountPoint
            MyPassportDisk=$(echo $MyPassportMountPoint | cut -d'/' -f3 | cut -d ' ' -f1)
            MyPassportDisk=${MyPassportDisk#*/*/}    
            MyPassportDisk=${MyPassportDisk::${#MyPassportDisk}-2}                  
            diskutil eraseDisk JHFS+ $jobnumber $MyPassportDisk
           fi
            echo "Commencing RSYNC copy out with the following parameters"
            echo "rsync -av --progress $customerusername@$customeripaddress:$serversourcedirectory /Volumes/$jobnumber"
            echo "Customer password will be needed. Get ready.."
            rsync -av $customerusername@$customeripaddress:$serversourcedirectory /Volumes/$jobnumber
            read -p "Transfer complete, you may close this script now";;
        2)  user=$(w | awk '{print $1}' | head -3 | tail -1)
            address=$(ifconfig | grep "inet " | grep -Fv 127.0.0.1 | awk '{print $2}')
                echo -e "===================================================" 
                echo -e "Ontrack Data Transfer Server started!"  
                echo -e "===================================================" 
                echo -e "Server Information:" 
                echo -e "Username: $user"   
                echo -e "Customer IP Address: $address"
                echo -e "===================================================" 
                echo -e "Please use these details for the host ODR machine"
                read -p "Press [Enter] key to Exit"  ;;
    esac
rm rsync
exit 3
