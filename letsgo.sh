#!/bin/bash -x

#--------------services-----------------------------
# start for name resolution for recalbox - needed for ssh when auto connecting vm to retroNAS
	service dbus start
    service avahi-daemon start
#--------------FUNCTIONS-----------------------------

function get_host_path {
  target="$1"
  output=$(findmnt --target "${target}")
  fstype=$(echo "${output}" | awk '{print $3}')
  source=$(echo "${output}" | awk '{print $2}')
  
   if [[ $output == *shfs* ]]; then
    host_path=$(echo $output | awk -F'[\\[\\]]' '{print "/mnt/user"$2}')
    echo "$host_path"
  elif echo "${source}" | grep -qE '/dev/mapper/md[0-9]+'; then
    disk_num=$(echo "${source}" | sed -nE 's|/dev/mapper/md([0-9]+)\[.*|\1|p')
    subvol=$(echo "${source}" | sed -nE 's|/dev/mapper/md[0-9]+\[(.*)\]|\1|p')
    host_path="/mnt/disk${disk_num}${subvol}"
	echo "${host_path}"
  else
    echo "Unsupported filesystem type: ${fstype}"
    return 1
  fi
  
}
function download_recalbox {
    # Create download location if it doesn't exist
    if [ ! -d "$download_location" ]; then
        echo "Download location directory does not exist. Creating it..."
        mkdir -p "$download_location"
    fi

    # Download the files
    echo "Downloading files..."
    cd "$download_location" || { echo "Failed to change directory to $download_location. Exiting..."; exit 1; }
    curl -O "$download_url1" || { echo "Failed to download $download_url1. Exiting..."; exit 1; }
    curl -O "$download_url_sha1" || { echo "Failed to download $download_url_sha1. Exiting..."; exit 1; }

    # Verify the SHA1 checksum
    for i in {1..3}; do
        echo "Verifying checksum (try $i)..."
        cd "$download_location" || { echo "Failed to change directory to $download_location. Exiting..."; exit 1; }
        sha1sum -c recalbox-x86_64.img.xz.sha1 --status || { echo "Checksum verification failed. Retrying..."; rm -f recalbox-x86_64.img.xz; rm -f recalbox-x86_64.img.xz.sha1; continue; }
        echo "Checksum verified."
        break
    done

    # Decompress the file
    echo "Decompressing file..."
    unxz -v recalbox-x86_64.img.xz || { echo "Failed to decompress file. Exiting..."; exit 1; }

    # Verify the decompressed file
    echo "Verifying decompressed file..."
    if [[ ! -f "$download_location/recalbox-x86_64.img" ]]; then
        echo "Decompressed file verification failed. Exiting..."
        exit 1
    fi
    echo "Decompressed file verified."
    rm -f recalbox-x86_64.img.xz.sha1
	
	   # Rename new file to vdisk1.img
    mv recalbox-x86_64.img vdisk1.img || { echo "Failed to rename file. Exiting..."; exit 1; }
	
	}
	
	
function check_4_existing {
    # Check if the vdisk1.img file exists
    if [[ -f "$download_location/vdisk1.img" ]]; then
        # Check if the REPLACE variable is set to "Yes"
        if [[ "$REPLACE" == "Yes" ]]; then
            # Rename existing file
            old_filename=$(date +"vdisk1-old-%Y-%m-%d-%H-%M.img")
            mv "$download_location/vdisk1.img" "$download_location/$old_filename" || { echo "Failed to rename file. Exiting..."; exit 1; }
        else
            echo "The VM is already installed and the vdisk is there."
            echo "If you want to replace the existing VM, either delete it or set the REPLACE variable in the Docker template to allow me to replace the VM."
            exit 1
        fi
    fi

 
}


function expand_vdisk {
    vdisk_path="$download_location/vdisk1.img"
    vdisk_size=$(qemu-img info "$vdisk_path" | grep "virtual size:" | awk '{print $3}')
    if [ "$vdisk_size" != "20G" ]; then
        echo "Expanding virtual disk..."
        qemu-img resize -f raw "$vdisk_path" 20G || { echo "Failed to expand virtual disk. Exiting..."; exit 1; }
    else
        echo "Virtual disk is already 20GB."
    fi
}

function set_variables {
   
download_url1="${download_url1:-https://upgrade.recalbox.com/latest/download/x86_64/recalbox-x86_64.img.xz}"
download_url_sha1="${download_url_sha1:-https://upgrade.recalbox.com/latest/download/x86_64/recalbox-x86_64.img.xz.sha1}"
	domains_share=$(get_host_path "/vm_location")
    download_location="/vm_location/""$vm_name"
	vdisk_location="$domains_share/$vm_name"
    icon_location="/unraid_vm_icons/Recalbox.png"  
	XML_FILE="/tmp/recal.xml"
}


define_recalbox() {
	# Generate a random UUID and MAC address
	UUID=$(uuidgen)
	MAC=$(printf '52:54:00:%02X:%02X:%02X\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

	# Replace the UUID and MAC address tags in the XML file with the generated values
	sed -i "s#<uuid>.*<\/uuid>#<uuid>$UUID<\/uuid>#" "$XML_FILE"
	sed -i "s#<mac address='.*'/>#<mac address='$MAC'/>#" "$XML_FILE"

	# Replace the source file location in the XML file with the vdisk location and filename
	sed -i "s#<source file='.*'/>#<source file='$vdisk_location/vdisk1.img'/>#" "$XML_FILE"

	# Replace the source directory location in the XML file with the specified RetroNAS share directory
	sed -i "s#<source dir='.*'/>#<source dir='$RETRO_SHARE'/>#" "$XML_FILE"

	# Replace the name of the virtual machine in the XML file with the specified name
	sed -i "s#<name>.*<\/name>#<name>$vm_name<\/name>#" "$XML_FILE"

    # Create the NVRAM file with the UUID value
	echo "As this is an ovmf VM I need to create an nvram file. Creating now ...."
    nvram_file="/var/lib/libvirt/qemu/nvram/${UUID}_VARS-pure-efi.fd"
     qemu-img create -f raw "$nvram_file" 64k

    # Replace the NVRAM file location in the XML file with the newly created file path
    sed -i "s#<nvram>.*_VARS-pure-efi.fd</nvram>#<nvram>$nvram_file</nvram>#" "$XML_FILE"

	# Define the virtual machine using the modified XML file
	virsh define "$XML_FILE"
}


function download_xml {
	local url="https://raw.githubusercontent.com/SpaceinvaderOne/Recalbox_inabox/main/recal.xml"
	curl -s -L $url -o $XML_FILE
}

function download_icon {
    local url="https://github.com/SpaceinvaderOne/Recalbox_inabox/raw/main/Recalbox.png"

    # Check if the exists (as will only if on Unraid)
    if [ -d "$(dirname "$icon_location")" ]; then
        # Download the file to the Unraid location
        curl -s -L "$url" -o "$icon_location"
    else
        # Download the file to the current working directory for other Linus systems
        curl -s -L "$url" -o "$(basename "$icon_location")"
    fi
}

function get_ip() {
  retrohost="$1"
  retronas_ip=$(ping -c 1 -4 $retrohost | awk -F'[()]' '/PING/{print $2}')
  echo "IP address of $retrohost is: $retronasip"
}

function connect_retronas() {
    # Check if the CONNECT_RETRONAS variable is set to "Yes"
    if [ "$CONNECT_RETRONAS" != "Yes" ]; then
        echo "CONNECT_RETRONAS is not set to Yes. Skipping connection."
        return
    fi
    
    # Check if the VM is running
    vm_running=$(virsh list --state-running | grep -w "$vm_name")
    if [ -z "$vm_running" ]; then
        echo "The VM $vm_name is not running. Exiting..."
        exit 1
    fi

    echo "This part may take a while if the vm is still booting"
    echo "So if the vm hasn't fully started, I may need to try a few times"
    echo "So I will try once every 30 seconds"
    echo ""
    echo "Obiously make sure your RetroNAS vm is running for RecalBox to be able to connect to it! "
    echo ""

    # Get the IP address of the RetroNAS
    get_ip $RETRONAS
   

    echo "Adding RetroNAS SMB shares to RecalBox configuration:"
    echo "sharenetwork_smb1=ROMS@$retronas_ip:recalbox/roms:username=$retronas_user:password=$retronas_password:vers=2.0"
    echo "sharenetwork_smb2=BIOS@$retronas_ip:recalbox/bios:username=$retronas_user:password=$retronas_password:vers=2.0"
    echo "sharenetwork_smb3=SAVES@$retronas_ip:recalbox/saves:username=$retronas_user:password=$retronas_password:vers=2.0"
    echo ""

    # Edit the file
    sed -i "/^#custom_retronas_config/a sharenetwork_smb1=ROMS@$retronas_ip:recalbox/roms:username=$retronas_user:password=$retronas_password:vers=2.0\nsharenetwork_smb2=BIOS@$retronas_ip:recalbox/bios:username=$retronas_user:password=$retronas_password:vers=2.0\nsharenetwork_smb3=SAVES@$retronas_ip:recalbox/saves:username=$retronas_user:password=$retronas_password:vers=2.0" /app/recalbox-boot.conf
    # 
    # Try to copy the file to the Recalbox host up to 8 times with a 30 second gap
    echo "Trying to copy the file to Recalbox host..."
    for i in {1..8}; do
        sshpass -p "recalboxroot" scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /app/recalbox-boot.conf root@"$RECALBOX":/boot/recalbox-boot.conf
        if [ $? -eq 0 ]; then
            echo "File copied successfully."
            echo "I will need to just quickly reboot the VM"
            echo "Then your RecalBox should be connected to your RetroNAS"
            echo ""
			sshpass -p "recalboxroot" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$RECALBOX" "chmod 777 /boot/recalbox-boot.conf"
            virsh reboot $vm_name
            echo "Ok so all done! Remember your RetroNAS VM should be running before you start RecalBox"
            sleep $TIMETOWAIT
            return
        else
            echo "Failed to copy. Retrying in 30 seconds..."
            sleep $TIMETOWAIT
        fi
    done

    # If unable to copy the file after 8 attempts, exit with an error message
    echo "Giving up. Can't copy file to Recalbox host."
    sleep $TIMETOWAIT
    exit 1
}



# Call the functions

set_variables 
connect_retronas
check_4_existing 
download_recalbox
expand_vdisk
download_xml
download_icon
define_recalbox
sleep $TIMETOWAIT


