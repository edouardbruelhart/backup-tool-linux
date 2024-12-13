#!/bin/bash

# Loading config file
config_file="/etc/backup-tool.conf"

# Full lsblk output with required columns, including transport type (TRAN)
lsblk_output=$(lsblk -a -d -o TRAN,MODEL,SIZE,NAME)

# Filter and prepare the list of USB drives (TRAN=usb), with device paths (e.g., /dev/sda1)
usb_drives=$(echo "$lsblk_output" | awk '
BEGIN { FS=" "; OFS=" " }
NR > 1 && $1 == "usb" { print "check", "/dev/" $5, $2, $3, $4 }
')

# Use zenity to present a checklist for selecting multiple USB drives
selected_drives=$(zenity --list --title="Select a Drive" --column="" --column="Drive Path" --column="Name" --column="Model" --column="Size" --checklist --multiple $usb_drives)

# Check if any drives were selected
if [ -z "$selected_drives" ]; then
  echo "No drives selected. Exiting..."
  exit 1
fi

# Split the selected drives into an array
IFS='|' read -r -a drives_array <<< "$selected_drives"

# Ask user for the new volume name
volume_name="backup"

# Ask user for confirmation before formatting
zenity --question --title="Confirm Formatting" --text="Are you sure you want to format the selected drives as exFAT? This will erase all data on the drives."

# Check if the user clicked "Yes"
if [ $? -eq 0 ]; then
  # Clear existing drives first
  sudo sed -i '/^DRIVES=/c\DRIVES=' "$config_file"

  for drive in "${drives_array[@]}"; do
    # Extract the device path (e.g., /dev/sda) from the selected drive
    disk_path=$drive

    # Get the list of device names (e.g., sdb1, sdb2)
    names=$(lsblk -o NAME -nr "$disk_path" | grep -v '^$')

    # Iterate over each partition
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
    mountpoints=$(lsblk -o MOUNTPOINT -nr "$disk_path" | grep -v '^$')

    # Unmount each partition
    for mountpoint in $mountpoints; do
      sudo umount "$mountpoint" >/dev/null 2>&1
      if [[ $? -ne 0 ]]; then
        echo "Failed to unmount $mountpoint. Exiting."
        exit 1
      fi
    done

    # Delete all partitions on the disk
    sudo sgdisk --zap-all "$disk_path" >/dev/null 2>&1

    # Refresh the partition table and attempt to re-read the changes
    sudo partprobe "$disk_path" || sudo kpartx -u "$disk_path" >/dev/null 2>&1

    # Create a new partition table (GPT or MBR)
    sudo parted "$disk_path" mklabel gpt >/dev/null 2>&1

    # Create a new partition using the entire disk space
    sudo parted "$disk_path" mkpart primary 0% 100% >/dev/null 2>&1

    # Find the new partition (assuming it will be the first partition on the disk)
    new_partition="${disk_path}1"

    sleep 2

    # Format the new partition as exFAT with the specified volume name
    sudo mkfs.exfat -n "$volume_name" "$new_partition" >/dev/null 2>&1

    # Check if formatting was successful
    if [ $? -eq 0 ]; then
      echo "$new_partition formatted successfully to exFAT with name '$volume_name'."
    else
      echo "Error formatting $new_partition."
      exit 1
    fi

    # Use partprobe or kpartx to ensure the new partition is detected
    sudo partprobe "$disk_path" >/dev/null 2>&1

    sleep 2

    # Extract UUID of newly formatted disk
    UUID=$(lsblk -o UUID -nr "$new_partition" | grep -v '^$')
    
    # Append the UUID to DRIVES (comma-separated list)
    current_drives=$(grep '^DRIVES=' "$config_file" | cut -d'=' -f2)
    if [[ -n "$current_drives" ]]; then
        updated_drives="${current_drives}${UUID},"
    else
        updated_drives="${UUID},"
    fi
    sudo sed -i "/^DRIVES=/c\DRIVES=${updated_drives}" "$config_file"

  done

  # Remove trailing comma from DRIVES
  sudo sed -i -E 's/DRIVES=(.*),$/DRIVES=\1/' "$config_file"

else
  echo "Formatting canceled."
fi

# Use a loop to let the user select multiple backup destinations
destinations_array=()
while true; do
    # Get the terminal window ID
    parent_window=$(xwininfo -root -tree | grep -i "Terminal" | head -n 1 | awk '{print $1}')
    echo "$parent_window"

    # Launch Zenity to select a directory
    selected_destination=$(zenity --file-selection --directory --title="Select Backup Target" --text="Choose a directory as a backup target.")
    
    # Check if a destination was selected
    if [ -z "$selected_destination" ]; then
        zenity --error --text="No directory selected. Please select a directory to continue."
    else
        # Add the selected destination to the array
        destinations_array+=("$selected_destination")
        echo "$destination_array"
        
        # Ask the user if they want to add another destination
        zenity --question --title="Add Another Backup Target?" --text="Do you want to add another backup target?"
        if [ $? -ne 0 ]; then
            break  # Exit the loop if the user clicks "No"
        fi
    fi
done

# Check if any destinations were selected
if [ ${#destinations_array[@]} -eq 0 ]; then
    echo "No backup target selected. Exiting..."
    exit 1
fi

# Clear existing folders first
sudo sed -i '/^FOLDERS=/c\FOLDERS=' "$config_file"

# Save the selected destinations to the FOLDERS parameter
destinations_string=$(printf ",%s" "${destinations_array[@]}")
destinations_string=${destinations_string:1}  # Remove leading comma
sudo sed -i "/^FOLDERS=/c\FOLDERS=${destinations_string}" "$config_file"

# Remove trailing comma from FOLDERS
sudo sed -i -E 's/FOLDERS=(.*),$/FOLDERS=\1/' "$config_file"

echo "Backup destinations saved successfully."