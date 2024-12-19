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

# Function to display already registered drives that are plugged to the system.
display_drives() {

    # Extract UUIDs from the config file
    uuid_list=$(grep -oP '^\[\K[^\]]+' "$CONFIG_FILE" | sort | uniq)

    if [ -z "$uuid_list" ]; then
    echo "No registered setup. Exiting..."
    exit 1
    fi

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

    # Use grep -E with the OR pattern to filter lsblk output
    lsblk_output=$(lsblk -o TRAN,MODEL,SIZE,NAME,UUID | grep -E "\b($include_drives)\b")

    # Filter USB drives, excluding already setup drives
    usb_drives=$(echo "$lsblk_output" | awk '
    BEGIN { FS=" "; OFS=" " } $1 == "usb" { print "/dev/" $5, $2, $3, $4 }
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
            uuid=
            break
        fi
    done
}



select_action() {
    echo "Which action do you want to perform?"
    while true; do
        echo "1. Modify drive setup"
        echo "2. Delete drive setup"
        read -r action
        # Validate input
        if [[ $action -gt 0 && $action -le 2 ]]; then
            break
        else
            echo "Invalid choice. Please type 1 to modify, 2 to delete."
        fi
    done
}

modify_setup() {
    echo "modify"
}

delete_setup() {
    echo "delete"
}

# Main script

# Display drives
display_drives

# Display volumes
ask_existing_volume

# Ask user the action he wants to perform
select_action

# In case of positive answer, ask the new volume name to user
if [ "$action" == 1 ]; then
    modify_setup
fi

# In case of positive answer, ask the new volume name to user
if [ "$action" == 2 ]; then
    delete_setup
fi