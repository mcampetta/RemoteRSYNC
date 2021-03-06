#!/bin/bash
#set -vx
speed=512K
blocksize=512
#!/bin/sh
if [ "`id -u`" -ne 0 ]; then
 clear
 echo "This script must be run as root user or a user with root permissions"
 echo "Switching from `id -un` to root"
 exec sudo "$0"
 exit 3
fi
while true
do
    clear
    echo "==================================================="
    echo " Ontrack MacOS Embedded SSD Imaging Script - 2021  "
    echo "==================================================="
    echo "Enter (1) to image drive Physically with DD  (Not for T2!)" 
    echo "Enter (2) to image drive Phyiscally with ddrescue (Not for T2!)" 
    echo "Enter (3) to copy files logically with DD  "    
    echo "Enter (4) to copy files logically with rsync  (Fully Automated Solution)"         
    echo "Enter q to exit q:"
    echo -e "\n"
    echo -e "Enter your choice: (4 is default for Mac devices) \c"
    read -r choice
    case "$choice" in
        1) echo -e "Choose source device \c "
 	   echo -e "\n"
 	   diskutil list
	   echo -e "Enter name of source (example disk1): \c"
           read -r iso 
           echo -e "Enter name of destination device (example disk2): \c"
           read -r device 
           echo -e "Going to copy $iso to $device, are you sure (y/N)? \c"
           read -r ans
                if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
                         echo "Exiting on user cancel"
                        exit 3
                fi
           sudo dd if=/dev/$iso of=/dev/$device bs=$blocksize
           echo "Copy Done! Press any key to return to main menu"
           read -r anykey;;
        2) echo -e "Enter job number: \c"
           read -r jobnumber
           echo -e "Choose source device \c "
 	   echo -e "\n"
 	   diskutil list
	   echo -e "Enter name of source (example disk1): \c"
           read -r iso 
           echo -e "Enter name of destination device (example disk2): \c"
           read -r device 
           echo -e "Going to copy $iso to $device, are you sure (y/N)? \c"
           read -r ans
                if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
                         echo "Exiting on user cancel"
                        exit 3
                fi
           sudo ddrescue --verbose --force /dev/$iso /dev/$device $jobnumber.txt
           echo "Copy Done! Press any key to return to main menu"
           read -r anykey;; 
        3) echo .................................. 
           echo Please Provide Source Volume Path \(Example: /\) and press Enter
           echo NOTE! YOU MAY DRAG AND DROP FOLDERS FROM FINDER HERE
           echo Possible Volumes are as follows...
           echo ..................................
           df -l | grep -v Mounted| awk ' { print $9 } '
           echo .................................. 
	# echo /Volumes/*
           read Source_Volume
           clear
           echo "Targeting $Source_Volume as source volume."
           echo .................................. 
           echo Please Provide Target External Volume Path 
           echo \(Example: /Volumes/\(name of volume/optionalpath\)\) and press Enter
           echo NOTE! YOU MAY DRAG AND DROP FOLDERS FROM FINDER HERE
           echo Possible Volumes are as follows...
           echo ..................................
           df -l | grep -v Mounted| awk ' { print $9 } '
           echo .................................. 
           read Destination_Volume
           echo "Targeting $Destination_Volume as destination volume."
           clear 
           echo Source Volume:$Source_Volume 
           echo Destination Volume:$Destination_Volume
           cd "$Source_Volume"
           echo "Creating Folder Structures on $Destination_Volume ???"
           find . -type d -not -path "./Volumes/*" -exec mkdir -p "$Destination_Volume/{}" \;
           echo "Copying Files to Target Volume ???"
           find . -type f -not -path "./Volumes/*" -exec dd if={} of="$Destination_Volume/{}" conv=noerror,sync \; 
           echo "Copy Complete!";;
        4)  echo -e "Enter job number: \c"
            read -r jobnumber
            echo "Searching for source customer drives.."
            retrieveLast2AttachedDevices=$(mount | grep -v "My Passport" | tail -3)
            retrieveLast2AttachedDevicesMountedSize=$(df -Hl |  grep -v "My Passport" | awk '{print $3}' | tail -3)
            #echo "$retrieveLast2AttachedDevicesMountedSize"
            retrieveLast2AttachedDevicesMountedSizeArray=($retrieveLast2AttachedDevicesMountedSize)
            IFS=$'\n'
            #Device1String=${regtrieveLast2AttachedDevicesMountedSizeArray[0]}
            #Device2String=${regtrieveLast2AttachedDevicesMountedSizeArray[1]}
            #Gets rid of the storage type at the end to convert to int for our sort
            #Device1StringTrimmed="${Device1String%?}"
            #Device2StringTrimmed="${Device2String%?}"
            largestStorageVolumeRecentlyMounted=$(echo "${retrieveLast2AttachedDevicesMountedSize[*]}" | sort -nr | head -n1)
            #echo "$largestStorageVolumeRecentlyMounted"
            echo "Found a potential source customer drive.."
            echo "Conducting initial checks.."
            #retrieveLast2AttachedDevices=$(mount | tail -2)
            #echo "Selecting Largest recently mounted storage volume by size"
            echo -e "Is this the correct drive?"
            selectedVolume=$(df -Hl | grep -v "My Passport" | tail -3 | grep $largestStorageVolumeRecentlyMounted)
            value=${selectedVolume#*%*%}
            value=$(echo "$value" | xargs)
            echo "Selected $value"
            Source_Volume=$value
            #Source_Volume=$(echo "$value" | sed 's/ /\\ /g' )
            echo -e "Press enter to confirm and continue otherwise overide by manuall dragging and dropping mounted drive from finder"
            read response
            if [[ "$response" != "" ]]; then
                    echo "User has decided to overide and use $response instead!"
                    echo "Moving on to prepping customer media drive now"
                    if [ -d "/Volumes/$jobnumber" ]; then
                        echo "Existing destination device identified..continuing from where we left off.."
                    elif [[ ! -d  "/Volumes/$jobnumber" ]]; then
                        #statements
                        echo "Please attach External customer copy out drive now to continue.."
                        while [ ! -f /Volumes/My\ Passport/Install\ Western\ Digital\ Software\ for\ Mac.dmg ]; do sleep 1; done
                        echo "External customer drive found!"
                        echo "Proceeding to format customer drive"
                        echo "Volume:$jobnumber"
                        echo "Filesystem:Mac OS Extended (Journaled)"
                        MyPassportMountPoint=$(mount | grep My)
                        #echo $MyPassportMountPoint
                        MyPassportDisk=$(echo $MyPassportMountPoint | cut -d'/' -f3 |  cut -d ' ' -f1)
                        MyPassportDisk=${MyPassportDisk#*/*/}    
                        MyPassportDisk=${MyPassportDisk::${#MyPassportDisk}-2}                  
                        diskutil eraseDisk JHFS+ $jobnumber $MyPassportDisk
                    fi        
                    response=$(echo "$response" | sed "s@\\\\@@g")
                    response=$(echo "$response" | xargs)
                    echo "Commencing RSYNC copy out with the following parameters"
                    echo "rsync -av --exclude "Dropbox" --exclude "Volumes" --exclude ".DocumentRevisions-V100" ""$response/"" "/Volumes/$jobnumber/$jobnumber""
                    echo "Creating $jobnumber subfolder.. at /Volumes/$jobnumber/"
                    mkdir -p "/Volumes/$jobnumber/$jobnumber"
                    rsync -av --exclude "Dropbox" --exclude "Volumes" --exclude ".DocumentRevisions-V100" ""$response/"" "/Volumes/$jobnumber/$jobnumber"
                exit 3
            fi
            if [[ "$response" = "" ]]; then
                    echo "User has decided to autodetected volume.."
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
                    echo "rsync -av --exclude "Dropbox" --exclude "Volumes" --exclude ".DocumentRevisions-V100" $Source_Volume/ "/Volumes/$jobnumber/$jobnumber""
                    echo "Creating $jobnumber subfolder.. at /Volumes/$jobnumber/"
                    mkdir -p "/Volumes/$jobnumber/$jobnumber"                    
                    rsync -av --exclude "Dropbox" --exclude "Volumes" --exclude ".DocumentRevisions-V100" "$Source_Volume/" "/Volumes/$jobnumber/$jobnumber"
                exit 3
            fi
	       echo Copy done!;;
        q) exit ;;
    esac
done
