#!/bin/bash
    clear
    echo "==================================================="
    echo " Ontrack MacOS Embedded SSD Imaging Script - 2022  "
    echo "==================================================="
    echo "Enter (1) if this is the Ontrack Machine" 
    echo "Enter (2) if this is the Customer Machine " 
    echo "==================================================="    
    echo  "Enter your choice:"
    read -r choice
    case "$choice" in
        1)  #clear
            echo "========================================================================="
            echo "-----------Ontrack MacOS Embedded SSD Imaging Script - 2022--------------"
            echo "========================================================================="
            echo "---------------------------- ATTENTION! ---------------------------------"
            echo "========================================================================="
            echo "This script requires Terminal have Full Disk Access privileges.          "
            echo "                                                                         "
            echo "Go to Sys Prefs/Security & Privacy/Privacy/Full Disk Access/ Add terminal"
            echo "                                                                         "
            echo "If this is not done the customer machine will fail to connect to ODR host"
            echo "========================================================================="
            read -p "Press [Enter] key to acknowledge and continue"
            echo "========================================================================="
            sudo -s <<EOF
            systemsetup -setremotelogin on 
EOF
            #clear
            echo -e "Enter Job Number: \c"
            read -r jobnumber
            echo  "jobnumber set to $jobnumber"
            echo "Moving on to prepping customer media drive now"
            if [ -d "/Volumes/$jobnumber" ]; then
                echo "Existing destination device identified.."
            fi
            if [[ ! -d  "/Volumes/$jobnumber" ]]; then
                echo "Please attach External customer copy out drive now to continue.."
            while [ ! -d /Volumes/My\ Passport ]; do sleep 1; done
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
            #clear              
            user=$(w | awk '{print $1}' | head -3 | tail -1)
            address=$(ifconfig | grep "inet " | grep -Fv 127.0.0.1 | awk '{print $2}')
            echo  "===================================================" 
            echo  "Ontrack Data Transfer Server started!"  
            echo  "===================================================" 
            echo  "Server Information:" 
            echo  "JobNumber: $jobnumber"
            echo  "Username: $user"   
            echo  "ODR Host IP Address: $address"
            echo  "===================================================" 
            echo  "You'll need this information for the second part   "
            echo  "Command for customer machine from terminal is ...  "
            echo  "---------------------------------------------------"
            echo  "bash -c \"\$(curl -fsSLk http://ontrack.link/extract)\""
            echo  "---------------------------------------------------"
            echo  "You may run that on the customer machine now  ...  "
            echo  "===================================================" 
            read -p "Press [Enter] key to Exit"  ;;
        2)  #clear 
            echo -e "Enter Job Number: \c"
            read -r jobnumber
            echo  "jobnumber set to $jobnumber"
            echo -e "Enter ODR Host Username: \c"
            read -r ODRusername
            echo  "customer username set to $ODRusername"  
            echo -e "Enter ODR IP Address: \c"
            read -r ODRIPAddress
            echo "ODR IP Address set to $ODRIPAddress"  
            echo  "======================================="
            echo  "What files would you like transferred?"
            echo  "======================================="
            echo  "Enter (1) for full filsystem"
            echo  "Enter (2) to target Users "
            echo  "Enter (3) to target Applications "
            echo  "Enter (4) to target Library "
            echo  "Enter (5) to target System "
            echo  "Enter (6) to target custom path"
            echo  "======================================="
            read -r choice2
                case "$choice2" in 
                 1) serversourcedirectory="/";;
                 2) serversourcedirectory="/Users";;
                 3) serversourcedirectory="/Applications";;
                 4) serversourcedirectory="/Library";;
                 5) serversourcedirectory="/System";;
                 6)  echo  "Enter customer path: \c"
                     read -r serversourcedirectory;;
                esac
            echo  " "
            if [[ "$serversourcedirectory" = "" ]]; then
                echo  "Default destionation of "/" set for source directory"
                serversourcedirectory="/"
            fi
            if [[ "$serversourcedirectory" != "" ]]; then
                echo  "User has decided to overide source directory"
                echo  "$serversourcedirectory will be used as source directory "
            fi
            echo "Doing a few quick checks now.."
            systemvolume=$(mount | grep sealed | awk -F 'on' '{print $2 FS "."}' | cut -d '(' -f1 | sed '/Update/d')
            systemvolume=`echo $systemvolume | sed 's/ *$//g'`
            #systemvolume=$(printf %q "$systemvolume")
            #This part of the searchest for the largest volume and assumes it is the main data volume. This is thought of as safe since the customer machine should have no drives attached and it's largest volume should be it's data volume (almost all of the time)
            largestvolume=$(df -Hl | awk '{print $3}' | sort -nr | sed '/M/d' | sed '/Used/d' | head -n1)
            selectedVolume=$(df -Hl | grep $largestvolume)
            value=${selectedVolume#*%*%}
            value=$(echo "$value" | sed 's/ *$//g')
            value="$(echo -e "${value}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            #echo "$value"
            #read -p "Pausing script, press [enter] to continue"
            datavolume=$value
            #datavolume=$(printf %q "$datavolume")
            echo "System Volume:$systemvolume"
            echo "Data Volume:$datavolume"
            read -p "Pausing script, press [enter] to continue"
            echo "Commencing RSYNC copy out with the following parameters"
            echo "Customer password will be needed. Get ready.."
            caffeinate -dismut 65500 &
            echo "usr/bin/rsync -av $datavolume$serversourcedirectory $ODRusername@$ODRIPAddress:/Volumes/$jobnumber"
            if [[ "$systemvolume" = "/" ]]; then
                /usr/bin/rsync -av "$datavolume$serversourcedirectory" $ODRusername@$ODRIPAddress:/Volumes/$jobnumber
            fi
            if [[ "$systemvolume" != "/" ]]; then
                "$systemvolume/usr/bin/rsync" -av "$datavolume$serversourcedirectory" $ODRusername@$ODRIPAddress:/Volumes/$jobnumber
            fi            
            read -p "Transfer complete, you may close this script now";;                   
    esac
exit 3    
