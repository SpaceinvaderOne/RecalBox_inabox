#!/bin/bash

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

    # Rename existing file if it exists
    if [[ -f "$download_location/vdisk1.img" ]]; then
        old_filename=$(date +"vdisk1-old-%Y-%m-%d-%H-%M.img")
        mv vdisk1.img "$download_location/$old_filename" || { echo "Failed to rename file. Exiting..."; exit 1; }
    fi

    # Rename new file to vdisk1.img
    mv recalbox-x86_64.img vdisk1.img || { echo "Failed to rename file. Exiting..."; exit 1; }
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
    icon_location="/unraid_vm_icons/Recalbox-logo.png"  
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

function connect_retronas() {
    # Check if the CONNECT_RETRONAS variable is set to "Yes"
    if [ "$CONNECT_RETRONAS" != "Yes" ]; then
        echo "CONNECT_RETRONAS is not set to Yes. Skipping connection."
        echo ""
        echo ""
        echo "However your RecalBox VM is now installed. You can see it in the Unraid VMs tab."
        echo "It will run with the virual graphics card (vnc qxl) currently installed but to use properly"
        echo "you should passthrough a GPU, Sound and a keyboard/mouse and/or game controller"
        return
    fi

    echo "Starting RecalBox"
    virsh start $vm_name
    echo "This part may take a while as the VM takes a while to install on the first run"
    echo "I am going to wait for 90 seconds then I will try and copy the necessary file"
    echo "It may take a few attempts depending on how long it takes for you VM to fully install"
    echo "So I will try once every 30 seconds"
	echo "I recommend opening a vnc console window into the Recalbox VM (on the vm tab - not here)"
	echo "That way you will see when the install has finished"
    sleep 60

    # Try to copy the file to the Recalbox host up to 8 times with a 30 second gap
    echo "Trying to copy the file to Recalbox host..."
    for i in {1..8}; do
        sshpass -p "recalboxroot" scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /app/recalbox-boot.conf root@"$RECALBOX":/boot/recalbox-boot.conf
        if [ $? -eq 0 ]; then
            echo "File copied successfully."
            echo "RecalBox should now be connected to your RetroNAS"
            echo ""
			echo "I need to restart the vm now for the new config to take effect"
			virsh reboot $vm_name
            echo "RecalBox VM is now installed. You can see it in the Unraid VMs tab."
            echo "It will run with the virtual graphics card currently installed but to use properly"
            echo "you should passthrough a GPU, Sound and a keyboard/mouse and/or game controller"
			sleep 30
            return
        else
            echo "Failed to copy. Retrying in 30 seconds..."
            sleep 30
        fi
    done

    # If unable to copy the file after 8 attempts, exit with an error message
    echo "Giving up. Can't copy file to Recalbox host."
	sleep 30
    exit 1
}


# Call the functions

set_variables 
download_recalbox
expand_vdisk
download_xml
download_icon
define_recalbox
connect_retronas

