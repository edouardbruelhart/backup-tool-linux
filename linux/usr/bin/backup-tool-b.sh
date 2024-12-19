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

# List all registered uuids
retrieve_uuids() {
    # Extract UUIDs from the config file
    uuid_list=$(grep -oP '^\[\K[^\]]+' "$CONFIG_FILE" | sort | uniq)

    if [ -z "$uuid_list" ]; then
    echo "No registered setup. Exiting..."
    exit 1
    fi
}

# perform backup
perform_backup() {
    # Loop over registered volumes
    for uuid in $uuid_list; do
        # Get mount point and volume name
        mount_point=$(lsblk -o UUID,MOUNTPOINT,LABEL | grep "$uuid" | awk '{print $2}')
        volume=$(awk -v uuid="[$uuid]" '/^\[/{found=0} $0 == uuid{found=1} found && /^volume=/{print substr($0, 8)}' "$CONFIG_FILE")

        # Check if volume is mounted
        if [[ -z "$mount_point" ]]; then
            echo "No mount point detected, skipping volume $volume (UUID: $uuid)."
            continue
        else
            echo "Backup in progress for volume $volume (UUID: $uuid)..."
        fi
        
        # Retrieve backup targets
        targets=()
        while IFS= read -r line; do
            targets+=("$line")
        done < <(awk -v uuid="[$uuid]" '
            /^\[/{found=0} 
            $0 == uuid {found=1} 
            found && /^target=/ {print substr($0, 8)}
        ' "$CONFIG_FILE")

        backup_path="$mount_point/backup"

        # Create the folder on the drive if it does not exist
        if [[ ! -d "$backup_path" ]]; then
            echo "Creating folder backup at $backup_path..."
            mkdir -p "$backup_path"
            if [[ $? -ne 0 ]]; then
                echo "Failed to create backup folder on $volume."
                continue
            fi
        else
            echo "Backup folder already exists at $backup_path. Skipping folder creation..."
        fi

        # Loop over each target
        for target in "${targets[@]}"; do
            # Check target existence
            if [[ ! -d "$target" ]]; then
                echo "Target folder $target does not exist. It will be removed from setup. Skipping..."
                # Remove the target line from the configuration file
                sed -i "/^\[$uuid\]/,/^\[/ s|^target=$target\$||; /^\s*$/d" "$CONFIG_FILE"

                # clean up empty lines left after deletion
                sed -i '/^$/ { N; /target=/ { s/^\n//; } }' "$CONFIG_FILE"
                continue
            fi

            # Get path to volume
            target_name=$(basename "$target")
            target_path="$backup_path/$target_name"

            # Create the folder on the drive if it does not exist
            if [[ ! -d "$target_path" ]]; then
                echo "Creating folder $target_name at $target_path..."
                mkdir -p "$target_path"
                if [[ $? -ne 0 ]]; then
                    echo "Failed to create folder $target_name on $volume."
                    continue
                fi
            else
                echo "Folder $target_name already exists at $target_path. Skipping folder creation..."
            fi

            # Sync the content of the source folder to the target folder using rsync
            echo "Syncing $target to $target_path..."
            rsync -a --delete "$target/" "$target_path/"
            if [[ $? -ne 0 ]]; then
                echo "Error occurred while syncing $target to $target_path."
            else
                echo "Successfully synced $target to $target_path."
            fi
        done
    done
}

retrieve_uuids

perform_backup