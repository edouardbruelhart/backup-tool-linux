#!/bin/bash

# Get the current logged-in user's home directory
USER_HOME=$(eval echo ~$USER)

# Get the linked configuration file
if [ "$USER_HOME" == "/root" ]; then
    # If is root or uses sudo, use the default configuration file
    CONFIG_FILE="/etc/backup-tool/backup-tool.conf"
else
    # If user is a non-root user, use the user-specific configuration file
    CONFIG_FILE="$USER_HOME/.config/backup-tool/backup-tool.conf"
fi

# Function to ask for drive selection
ask_drives() {

    # Extract UUIDs from the config file
    uuid_list=$(grep -oP '^\[\K[^\]]+' "$CONFIG_FILE" | sort | uniq)

    # Full lsblk output with required columns
    lsblk_output=$(lsblk -o TRAN,MODEL,SIZE,NAME,UUID)

    # Remove already setup drives
    for uuid in $uuid_list; do
        # Extract the base drive name for the current UUID
        drive_name=$(lsblk -o NAME,UUID | grep "$uuid" | awk '{print $1}' | sed 's/^[[:space:]]*└─//' | sed 's/[0-9]*$//')

        if [ -z "$drive_name" ]; then
            continue
        fi

        # Remove the lines corresponding to the obtained drive_name from the lsblk_output
        lsblk_output=$(echo "$lsblk_output" | grep -v "$drive_name")
    done

    # Filter and prepare the list of USB drives, without already setup drives
    usb_drives=$(echo "$lsblk_output" | awk '
    BEGIN { FS=" "; OFS=" " }
    $1 == "usb" { print "/dev/" $5, $2, $3, $4 }
    ')

    # Check if there are available drives
    if [ -z "$usb_drives" ]; then
    echo "No available drive. Exiting..."
    exit 1
    fi

    # Display the available drives in the terminal and wait for a user response
    echo "Enter the number of the drive you want to select:"
    while true; do

        IFS=$'\n' read -rd '' -a usb_array <<< "$usb_drives"
        for i in "${!usb_array[@]}"; do
            echo "$((i+1)). ${usb_array[$i]}"
        done
        read -r drive
        # Validate input and retrieve selected drive informations
        if [[ $drive -le 0 || $drive -gt ${#usb_array[@]} ]]; then
            echo "Invalid choice. Please select a valid drive."
        else
            selected_drive="${usb_array[$drive-1]}"
            drive_path="${selected_drive%% *}"
            break
        fi
    done
}

# Function to ask for formatting
ask_formatting() {
    echo "Do you want to format the drive? This action erases all content on the drive."
    while true; do
        echo "1. Yes"
        echo "2. No"
        read -r format
        # Validate input
        if [[ $format -gt 0 && $format -le 2 ]]; then
            break
        else
            echo "Invalid choice. Please type 1 for Yes, 2 for No."
        fi
    done
}

# Function to ask for volume name
ask_new_volume() {
    echo "Enter a name for the newly created volume (letters and numbers only):"
    while true; do
        read -r volume_name
        LC_ALL=C # Enforce C locale for regex check
        if [[ $volume_name =~ ^[a-zA-Z0-9]+$ ]]; then
            echo "Formatting drive..."
            format_drive
            break
        else
            echo "Invalid volume name. Please use only letters and numbers (no spaces, special characters, or accents)."
        fi
    done
}

# Function to format the selected drive
format_drive() {
    # Retrieve all volumes of the drive
    names=$(lsblk -o NAME -nr "$drive_path" | grep -v '^$')

    # Create volumes path
    for name in $names; do
      full_path="/dev/$name"

      # Detect processes linked to the usb drives
      processes=$(sudo lsof "$full_path" >/dev/null 2>&1)
      
      # If there are processes using the partition, kill them to avoid permission issues
      if [[ -n "$processes" ]]; then
        sudo lsof -t "$full_path" | xargs -r sudo kill -9 >/dev/null 2>&1
      fi
    done

    # Get the list of mount points
    mountpoints=$(lsblk -o MOUNTPOINT -nr "$drive_path" | grep -v '^$')

    # Unmount each partition
    for mountpoint in $mountpoints; do
      sudo umount "$mountpoint" >/dev/null 2>&1
      if [[ $? -ne 0 ]]; then
        echo "Failed to unmount $mountpoint. Exiting."
        exit 1
      fi
    done

    # Delete all partitions on the disk
    sudo sgdisk --zap-all "$drive_path" >/dev/null 2>&1

    # Refresh the partition table and attempt to re-read the changes
    sudo partprobe "$drive_path" || sudo kpartx -u "$drive_path" >/dev/null 2>&1

    # Create a new partition table (GPT or MBR)
    sudo parted "$drive_path" mklabel gpt >/dev/null 2>&1

    # Create a new partition using the entire disk space
    sudo parted "$drive_path" mkpart primary 0% 100% >/dev/null 2>&1

    # Construct the new partition
    new_partition="${drive_path}1"

    # Wait for system update, otherwise the new volume is not correctly detected
    sleep 2

    # Format the new partition as NTFS with the specified volume name
    sudo mkfs.ntfs -f -L "$volume_name" "$new_partition" >/dev/null 2>&1

    # Check if formatting was successful
    if [ $? -eq 0 ]; then
      echo "$new_partition formatted successfully to NTFS with name '$volume_name'."
    else
      echo "Error formatting $new_partition."
      exit 1
    fi

    # Use partprobe or to ensure the new partition is detected
    sudo partprobe "$drive_path" >/dev/null 2>&1

    # Wait for system update, otherwise UUID is not correctly retrieved
    sleep 2

    # Extract UUID of newly formatted disk
    volume_name=$(lsblk -o LABEL -nr "$new_partition" | grep -v '^$')
    uuid=$(lsblk -o UUID -nr "$new_partition" | grep -v '^$')
    size=$(lsblk -o SIZE -nr "$new_partition" | grep -v '^$')
}

# Function to ask for volume name
ask_existing_volume() {
    # Extract the base drive name (e.g. sda from /dev/sda)
    base_name=$(basename "$drive_path")

    # Use lsblk to list partitions for the selected drive
    lsblk_output=$(lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,UUID -r | grep "^${base_name}[0-9]")
    
    # Construct the text to display volumes
    volumes=$(echo "$lsblk_output" | awk '
    BEGIN { FS=" "; OFS=" " } { print $4, $2, $3, $1, $5, $6 }
    ' | grep -v '^[[:space:]]*$')

    # Check if volumes are available
    if [ -z "$volumes" ]; then
        no_volume
    else
        existing_volume
    fi
}

# In case no volume is detected, asks user to format the drive
no_volume() {
    echo "No available volume. Do you want to format and create one? Be careful, this will erase all data on drive."
    while true; do
        echo "1. Yes"
        echo "2. No"
        read -r no_volume
        if [[ $no_volume -gt 0 && $no_volume -le 2 ]]; then
            if [ $no_volume == 1 ]; then
                ask_new_volume
                break
            else
                echo "Without formatting, this drive can't be used. Exiting..."
                exit 1
            fi
        else
            echo "Invalid choice. Please type 1 for Yes, 2 for No."
        fi
    done
}

# In case volume(s) is/are detected, asks user to choose the one he wants
existing_volume() {
    echo "Enter the number of the volume you want to select:"
    while true; do
        IFS=$'\n' read -rd '' -a volume_array <<< "$volumes"
        for i in "${!volume_array[@]}"; do
            echo "$((i+1)). ${volume_array[$i]}"
        done
        read -r volume_number

        if [[ $volume_number -le 0 || $volume_number -gt ${#volume_array[@]} ]]; then
            echo "Invalid choice. Please select a valid volume."
        else
            selected_volume="${volumes[$volume_number-1]}"
            fstype=$(echo "$selected_volume" | awk '{print $3}')
            # Check that the volume is formatted in NTFS, else propose user to format it.
            if [ "$fstype" == "ntfs" ]; then
                volume_name=$(echo "$selected_volume" | awk '{print $1}')
                uuid=$(echo "$selected_volume" | awk '{print $6}')
                size=$(echo "$selected_volume" | awk '{print $2}')
            else
                echo "The volume you selected is not formatted in NTFS. This could lead to compatibility issues with other systems and/or to file size limits. Do you want to format it in NTFS?"
                while true; do
                    echo "1. Yes"
                    echo "2. No"
                    read -r warning
                    if [[ $warning -gt 0 && $warning -le 2 ]]; then
                        if [ "$warning" == 1 ]; then
                            ask_new_volume
                        else
                            volume_name=$(echo "$selected_volume" | awk '{print $1}')
                            uuid=$(echo "$selected_volume" | awk '{print $6}')
                            size=$(echo "$selected_volume" | awk '{print $2}')
                        fi
                        break
                    else
                        echo "Invalid choice. Please type 1 to format, 2 to continue."
                    fi
                done
            fi
            break
        fi
    done
}

# Asks user to enter the paths of backup targets
ask_backup_target() {
    echo "Adding backup targets...:"

    # Initialize an array to store valid paths
    target_array=()

    # Get the total size of the external drive in bytes
    drive_size=$(lsblk -o SIZE -b -n "$drive_path" | head -n 1)

    # Initialize remaining size as the total drive size
    remaining_size=$drive_size

    while true; do
        echo "Enter the path of the folder you want to backup:"
        read -r backup_target

        # Check if the path exists
        if [ -d "$backup_target" ]; then
            # Get the size of the folder in bytes
            folder_size=$(du -sb "$backup_target" | awk '{ print $1 }')

            # Check if the folder fits in the remaining space
            if [ "$folder_size" -le "$remaining_size" ]; then
                # Add the folder to the array
                target_array+=("$backup_target")

                # Update the remaining size
                remaining_size=$(($remaining_size - $folder_size))

                # Convert sizes to human-readable format for display
                remaining_size_human=$(numfmt --to=iec "$remaining_size")

                echo "The folder '$backup_target' has been added."
                echo "Remaining space on the drive: $remaining_size_human."

                # Ask if the user wants to add another path
                echo "Do you want to add another folder?"
                echo "1. Yes"
                echo "2. No"
                read -r response
                if [[ $response -gt 0 && $response -le 2 ]]; then
                    if [ "$response" != 1 ]; then
                        break
                    fi
                else
                    echo "Invalid choice. Please type 1 to add a new target, 2 to stop here."
                fi
            else
                # Folder is too large for the remaining space
                remaining_size_human=$(numfmt --to=iec "$remaining_size")

                echo "The folder '$backup_target' is too large to fit in the remaining space ($remaining_size_human)."
                echo "Please choose a smaller folder or use another drive."
            fi
        else
            # Path does not exist
            echo "Invalid path. Please type a path that exists on the computer."
        fi
    done

    # Display the final list of selected folders
    echo "Backup target folders:"
    for path in "${target_array[@]}"; do
        echo "- $path"
    done
}

# Register the drive to config file
add_drive_to_config() {
    # Append the new drive configuration to the config file
    echo -e "\n[$uuid]" >> $CONFIG_FILE
    echo "volume=$volume_name" >> $CONFIG_FILE

    # Assuming targets is an array, loop through and append them
    for target in "${target_array[@]}"; do
        echo "target=$target" >> $CONFIG_FILE
    done

    echo "Setup successfully saved!"
}

# Main script

# Ask user to choose a drive
ask_drives

# Ask to format the drive
ask_formatting

# In case of positive answer, ask the new volume name to user
if [ "$format" == 1 ]; then
    ask_new_volume
fi

# In cas of negative answer, ask the user to choose an existing volume
if [ "$format" == 2 ]; then
    ask_existing_volume
fi

if [ -z "$uuid" ]; then
    echo "Error retrieving the UUID of the selected volume, try to unplug and plug the drive again, then rerun the script. Exiting..."
    exit 1
fi

# Asks backup targets
ask_backup_target

# Save choices
add_drive_to_config