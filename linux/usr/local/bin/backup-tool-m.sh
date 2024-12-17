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

# Extract UUIDs from the config file
uuid_list=$(grep -oP '^\[\K[^\]]+' "$CONFIG_FILE" | sort | uniq)

# Initialize an empty string for drives to exclude
include_drives=""

# Extract the base drive names for already setup UUIDs
for uuid in $uuid_list; do
    # Extract drive name matching the UUID (filter out partitions)
    drive_name=$(lsblk -o NAME,UUID | grep "$uuid" | awk '{print $1}' | sed 's/^[[:space:]]*└─//' | sed 's/[0-9]*$//')

    # Append to the list of drives to exclude
    if [ -n "$drive_name" ]; then
        include_drives="$include_drives$drive_name|"
    fi
done

# Remove the trailing '|'
include_drives=$(echo "$include_drives" | sed 's/|$//')

# Debug: Print the include_drives variable
echo "Include drives regex: $include_drives"

# Use grep -E with the OR pattern to filter lsblk output
lsblk_output=$(lsblk -o TRAN,MODEL,SIZE,NAME,UUID | grep -E "\b($include_drives)\b")
echo "$lsblk_output"

# Filter USB drives, excluding already setup drives
usb_drives=$(echo "$lsblk_output" | awk '
BEGIN { FS=" "; OFS=" " }
NR > 1 && $1 == "usb" { print "/dev/" $5, $2, $3, $4 }
')

# Check if there are available drives
if [ -z "$usb_drives" ]; then
    echo "No available drives. Exiting..."
    exit 1
fi

# Display the available drives in the terminal and wait for a user response
echo "Enter the number of the drive you want to modify:"
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