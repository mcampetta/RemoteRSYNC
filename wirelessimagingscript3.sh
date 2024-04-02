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
            echo "Lets first check that the system time is acurate"
            systemtime=$(date)
            echo -e "$systemtime"
            echo -e "Is the systen time correct? Enter (y)or (n): \c"
            read -r choice3
                case "$choice3" in
                    y);;
                    n)  echo -e "retrieving system time from google servers.."
                        googletime=$(curl -I 'https://google.com/' 2>/dev/null | grep -i '^date:' | sed 's/^[Dd]ate: //g')
                        echo -e "Retrieved google time is.."
                        echo -e "$googletime"
                        googletimeepoch=$(date -j -u -f "%a, %d %b %Y %T %Z" "$googletime" +%s)
                        echo -e "Retrieved google time in epoch is.."
                        echo -e "$googletimeepoch"    
                        echo -e "Type GMT time zone offset in seconds. (ex -18000 for Minneapoilis)"
                        echo -e "Common offset table belowfor reference"
                        echo -e "If your area isn't listed simply mutiply your GMT by 3600"
                        echo -e "So for example GMT -5 (Minneapolis) is -5 * 3600 which is -18000"
                        echo  "============================================================"
                        echo -e "EDT = -14400 (Canada)"
                        echo -e "CDT = -18000 (Minneapolis)"
                        echo -e "CEST = +7200 (Netherlands, Germany, Poland, Spain, Italy)"
                        echo -e "AEST = +36000 (Australia)"
                        echo -e "HKST = +28800 (Hong Kong)"
                        echo -e "BST = +3600 (London)"
                        echo -e "CST = +28800 (China)"
                        echo -e "JST = +32400 (Japan)"
                        echo -e "============================================================"
                        read -r offset
                        echo -e "selected offset is $offset"
                        googletimeepochadjusted=$(echo $(($googletimeepoch + $offset)))
                        echo -e "Adjusted google time is $googletimeepochadjusted in epoch format"
                        googletimeadjustedmac=$(date -j -u -f "%s" $googletimeepochadjusted +%m%d%H%M%y)
                        echo -e "Adjusted google time is $googletimeadjustedmac in mac format which is month day hour minute year format"
                        echo -e "Attempting to update correct date now.."
                        date $googletimeadjustedmac
                        echo -e "If date didin't change please make sure script is root.."
                    ;;
                esac
            if [[ $arch == x86_64* ]]; then
            echo "X64 Architecture"
                cd ~/
                echo "Getting things ready for automation.."
                echo "-Attempting to download rsync into $currentdirectory"
                curl -O -L http://ontrack.link/rsync
                echo "-Attempting to grant the binary read/write access"
                chmod +x rsync 
                if [ $? -ne 0 ]; then
                    echo "An error occurred while granting rsync read/write"
                    echo "Attempting to grant read/write to file as elevated user"
                    echo "Please enter password if prompted"
                    sudo chmod +x rsync 
                    exit 1
                fi
                echo "Ready!"
            elif  [[ $arch == arm* ]]; then
            echo "ARM Architecture"
                cd ~/
                echo "Getting things ready for automation.."
                echo "-Attempting to download rsync into $currentdirectory"
                curl -O -L http://ontrack.link/rsync_arm
                echo "-Attempting to grant the binary read/write access"
                chmod +x rsync_arm
                if [ $? -ne 0 ]; then
                    echo "An error occurred while granting rsync read/write"
                    echo "Attempting to grant read/write to file as elevated user"
                    echo "Please enter password if prompted"
                    sudo chmod +x rsync_arm
                    exit 1
                fi
        echo "Attempting to rename rsync binary"
        mv rsync_arm rsync
        fi    
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
            echo "Ontrack ODR password will be needed. Get ready.."
            caffeinate -dismut 65500 &
            echo "usr/bin/rsync -av $datavolume$serversourcedirectory $ODRusername@$ODRIPAddress:/Volumes/$jobnumber"
            if [[ "$systemvolume" = "/" ]]; then
                ./rsync -av --times --stats --human-readable --itemize-changes --info=progress2 --exclude 'Dropbox' --exclude 'Volumes' --exclude '.DocumentRevisions-V100' --exclude 'Cloud Storage' "$datavolume$serversourcedirectory" $ODRusername@$ODRIPAddress:/Volumes/$jobnumber
            fi
            if [[ "$systemvolume" != "/" ]]; then
                ./rsync -av --times --stats --human-readable --itemize-changes --info=progress2 --exclude 'Dropbox' --exclude 'Volumes' --exclude '.DocumentRevisions-V100' --exclude 'Cloud Storage' "$datavolume$serversourcedirectory" $ODRusername@$ODRIPAddress:/Volumes/$jobnumber
            fi            
            read -p "Transfer complete, you may close this script now";;                   
    esac
exit 3    
