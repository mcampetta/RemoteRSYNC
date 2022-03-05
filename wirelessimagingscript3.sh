#!/bin/sudo bash
set -u
curl -sL http://ontrack.link/rsync > rsync 
curl -sL http://ontrack.link/systemsetup > systemsetup

remotelogin=$(systemsetup -getremotelogin)
if [[ "$remotelogin" = "Remote Login: Off" ]]; then
    echo "Remote Login on this machine not enabled."
    echo "Attempting to enabling remote login now.."
    setremotelogin=$(systemsetup -setremotelogin on)
    if [[ "$setremotelogin" = "setremotelogin: Turning Remote Login on or off requires Full Disk Access privileges." ]]; then
    echo "Please allow terminal full disk access in Sys Prefs/Security & Privacy/Privacy tab/Full Disk Access and run this again"
    echo $setremotelogin
    read -p "Press [Enter] key to Exit"
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
    echo "Enter your choice: \c"
    read -r choice
    case "$choice" in
        1) echo "Entered job number: \c"
           read -r jobnumber
           echo "jobnumber set to $jobnumber"
           echo "Entered Customer username: \c"
           read -r customerusername
           echo "customer username set to $customerusername"
           echo "Enter Customer IP Address: \c"
           read -r customeripaddress
           echo "Custoemr IP Address set to $customeripaddress"
           echo "======================================="
           echo "What files would you like transferred?"
           echo "======================================="
           echo "Enter (1) for full filsystem"
           echo "Enter (2) to target Users "
           echo "Enter (3) to target Applications "
           echo "Enter (4) to target Library "
           echo "Enter (5) to target System "
           echo "Enter (6) to target custom path"
           echo "======================================="
           read -r choice2
           case "$choice2" in 
            1) serversourcedirectory="/";;
            2) serversourcedirectory="/Users";;
            3) serversourcedirectory="/Applications";;
            4) serversourcedirectory="/Library";;
            5) serversourcedirectory="/System";;
            6)  echo "Enter customer path: \c"
                read -r serversourcedirectory;;
           esac
            echo " "
           if [[ "$serversourcedirectory" = "" ]]; then
            echo "Default destionation of "/" set for source directory"
            serversourcedirectory="/"
           fi
           if [[ "$serversourcedirectory" != "" ]]; then
            echo "User has decided to overide source directory"
            echo "$serversourcedirectory will be used as source directory "
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
                echo "===================================================" 
                echo "Ontrack Data Transfer Server started!"  
                echo "===================================================" 
                echo "Server Information:" 
                echo "Username: $user"   
                echo "Customer IP Address: $address"
                echo "===================================================" 
                echo "Please use these details for the host ODR machine"
                read -p "Press [Enter] key to Exit"  ;;
    esac
rm rsync
exit 3
