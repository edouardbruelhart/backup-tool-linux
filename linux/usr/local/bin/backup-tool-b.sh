#!/bin/bash

# Define your configuration file
CONF_FILE="/etc/backup-tool.conf"

# Function to parse the configuration file
parse_conf() {
    # DRIVES, and FOLDERS from the config file
    DRIVES=$(grep "^DRIVES=" "$CONF_FILE" | cut -d'=' -f2 | tr ',' ' ')
    FOLDERS=$(grep "^FOLDERS=" "$CONF_FILE" | cut -d'=' -f2 | tr ',' ' ')
}

# Function to check if a drive is mounted and retrieve its mount point
get_mount_point() {
    local uuid=$1
    local mount_point=$(lsblk -o UUID,MOUNTPOINT | grep "$uuid" | awk '{print $2}')
    if [[ -z "$mount_point" ]]; then
        echo ""
    else
        echo "$mount_point"
    fi
}

# Main script execution
if [[ ! -f "$CONF_FILE" ]]; then
    echo "Configuration file $CONF_FILE not found!"
    exit 1
fi

# Parse the configuration file
parse_conf

# Ensure DRIVES and FOLDERS have the same number of items
drive_array=($DRIVES)
folder_array=($FOLDERS)

for i in "${!drive_array[@]}"; do
    drive_uuid="${drive_array[$i]}"
    mount_point=$(get_mount_point "$drive_uuid")
    if [[ -z "$mount_point" ]]; then
        echo "Skipping backup for drive UUID $drive_uuid as it is not mounted."
        continue
    fi

    # Loop through each folder path in FOLDERS
    for source_folder in "${folder_array[@]}"; do
        # Ensure the source folder exists
        if [[ ! -d "$source_folder" ]]; then
            echo "Source folder $source_folder does not exist. Skipping..."
            continue
        fi

        # Extract the base name of the folder (e.g., "dbgi" from "/home/edouard/Bureau/dbgi")
        target_folder_name=$(basename "$source_folder")
        target_folder_path="$mount_point/$target_folder_name"

        # Create the folder on the drive if it does not exist
        if [[ ! -d "$target_folder_path" ]]; then
            echo "Creating folder $target_folder_name at $target_folder_path..."
            mkdir -p "$target_folder_path"
            if [[ $? -ne 0 ]]; then
                echo "Failed to create folder $target_folder_name on drive $drive_uuid."
                continue
            fi
        else
            echo "Folder $target_folder_name already exists at $target_folder_path."
        fi

        # Sync the content of the source folder to the target folder using rsync
        echo "Syncing $source_folder to $target_folder_path..."
        rsync -a --delete "$source_folder/" "$target_folder_path/"
        if [[ $? -ne 0 ]]; then
            echo "Error occurred while syncing $source_folder to $target_folder_path."
        else
            echo "Successfully synced $source_folder to $target_folder_path."
        fi
    done
done