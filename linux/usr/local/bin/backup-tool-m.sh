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

# Initialize an empty string to hold the lsblk_output
lsblk_output=""

# Remove already setup drives
for uuid in $uuid_list; do
    # Extract the base drive name for the current UUID
    drive_name=$(lsblk -o NAME,UUID | grep "$uuid" | awk '{print $1}' | sed 's/^[[:space:]]*└─//' | sed 's/[0-9]*$//')

    # Get the relevant lsblk information for the current drive
    lsblk=$(lsblk -o TRAN,MODEL,SIZE,NAME | grep "$drive_name")

    # Append the retrieved lsblk information to lsblk_output with a newline
    lsblk_output="$lsblk_output$lsblk\n"
done

# Filter and prepare the list of USB drives, without already setup drives
usb_drives=$(echo "$lsblk_output" | awk '
BEGIN { FS="[[:space:]]+"; OFS=" " }
NR > 1 && $1 == "usb" { print "/dev/" $4, $2, $3, $1 }
')
echo "$usb_drives"
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