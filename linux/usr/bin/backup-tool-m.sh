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
    include_volumes=""

    # Extract the base drive names for already setup UUIDs
    for uuid in $uuid_list; do
        # Extract drive name matching the UUID (filter out partitions)
        volume_name=$(lsblk -o NAME,UUID | grep "$uuid" | awk '{print $1}' | sed 's/^[[:space:]]*└─//')

        # Append to the list of drives to exclude
        if [ -n "$volume_name" ]; then
            include_volumes="$include_volumes$volume_name|"
        fi
    done

    # Remove the trailing '|'
    include_volumes=$(echo "$include_volumes" | sed 's/|$//')

    if [ -z "$include_volumes" ]; then
        echo "No registered drive connected. Exiting..."
        exit 1
    fi

    # Use grep -E with the OR pattern to filter lsblk output
    lsblk_output=$(lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,UUID -r | grep -E "\b($include_volumes)\b")

    # Construct the text to display volumes
    volumes=$(echo "$lsblk_output" | awk '
    BEGIN { FS=" "; OFS=" " } { print $4, $2, $3, $1, $5, $6 }
    ' | grep -v '^[[:space:]]*$')

    # Check if there are available drives
    if [ -z "$volumes" ]; then
        echo "No available volumes. Exiting..."
        exit 1
    fi

    # Display the available drives in the terminal and wait for a user response
    echo "Enter the number of the volume you want to modify:"
    while true; do

        IFS=$'\n' read -rd '' -a volumes_array <<< "$volumes"
        for i in "${!volumes_array[@]}"; do
            echo "$((i+1)). ${volumes_array[$i]}"
        done

        read -r volume
        # Validate input and retrieve selected drive informations
        if [[ $volume -le 0 || $volume -gt ${#volumes_array[@]} ]]; then
            echo "Invalid choice. Please select a valid volume."
        else
            selected_volume="${volumes_array[$volume-1]}"
            volume_name=$(echo "$selected_volume" | awk '{print $1}')
            uuid=$(echo "$selected_volume" | awk '{print $6}')
            size=$(echo "$selected_volume" | awk '{print $2}')
            volume_path="/dev/"$(echo "$selected_volume" | awk '{print $4}')
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
    echo "What do you want to modify?"
    while true; do
        echo "1. Add backup target"
        echo "2. Remove backup target"
        read -r modify
        # Validate input
        if [[ $modify -gt 0 && $modify -le 2 ]]; then
            break
        else
            echo "Invalid choice. Please type 1 to add a target, 2 to delete a target."
        fi
    done
}

new_target() {
    echo "Adding backup targets...:"

    # Retrieve existing targets for the UUID
    existing_targets=()
    while IFS= read -r line; do
        existing_targets+=("$line")
    done < <(awk -v uuid="[$uuid]" '
        /^\[/{found=0} 
        $0 == uuid {found=1} 
        found && /^target=/ {print substr($0, 8)}
    ' "$CONFIG_FILE")

    # Get the total size of the external drive in bytes
    drive_size=$(lsblk -o SIZE -b -n "$volume_path" | head -n 1)
    used_space=0

    echo "Calculating space used by existing targets..."
    for target in "${existing_targets[@]}"; do
        if [ -d "$target" ]; then
            folder_size=$(du -sb "$target" | awk '{ print $1 }')
            used_space=$(($used_space + $folder_size))
        else
            echo "Warning: Target '$target' does not exist on computer. Removing target..."
            
            # Remove the target line from the configuration file
            sed -i "/^\[$uuid\]/,/^\[/ s|^target=$target\$||; /^\s*$/d" "$CONFIG_FILE"

            # clean up empty lines left after deletion
            sed -i '/^$/ { N; /target=/ { s/^\n//; } }' "$CONFIG_FILE"
        fi
    done

    # Initialize remaining size
    remaining_size=$(($drive_size - $used_space))

    # Display theoretical remaining space
    remaining_size_human=$(numfmt --to=iec "$remaining_size")
    echo "Remaining space: $remaining_size_human"

    # Initialize an array to store valid paths
    target_array=()

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

    # Add new targets to the configuration file
    if [ ${#target_array[@]} -gt 0 ]; then
        echo "Updating configuration file with new targets..."

        # Insert new targets before the 'snapshot' parameter for the UUID block
        for path in "${target_array[@]}"; do
            sed -i "/^\[$uuid\]/,/^\[/ {/^volume=/a target=$path
                }" "$CONFIG_FILE"
        done
    fi

    # Display the final list of targets
    echo "Backup target folders:"
    for path in "${existing_targets[@]}" "${target_array[@]}"; do
        echo "- $path"
    done
}

remove_target() {
    echo "Removing backup targets...."
    # Retrieve existing targets for the UUID
    existing_targets=()
    while IFS= read -r line; do
        existing_targets+=("$line")
    done < <(awk -v uuid="[$uuid]" '
        /^\[/{found=0} 
        $0 == uuid {found=1} 
        found && /^target=/ {print substr($0, 8)}
    ' "$CONFIG_FILE")

    counter=1
    echo "Select the number of the target you want to remove:"
    while true; do
        for target in "${existing_targets[@]}"; do
            echo "$counter. $target"
            ((counter++))
        done
        read -r remove
        if [[ $remove -gt 0 && $remove -le $counter ]]; then
            break
        else
            echo "Invalid choice. Please choose a valid target."
        fi
    done
    target="${existing_targets[$remove-1]}"
    
    echo "updating configuration file..."
    # Remove the target line from the configuration file
    sed -i "/^\[$uuid\]/,/^\[/ s|^target=$target\$||; /^\s*$/d" "$CONFIG_FILE"

    # clean up empty lines left after deletion
    sed -i '/^$/ { N; /target=/ { s/^\n//; } }' "$CONFIG_FILE"
}

delete_setup() {
    while true; do
        echo "Are you sure you want to delete $volume_name setup?"
        echo "1. Yes"
        echo "2. No"
        read -r delete
        if [[ $delete -gt 0 && $delete -le 2 ]]; then
            break
        else
            echo "Invalid choice. Please type 1 to delete, 2 to cancel."
        fi
    done
    if [ $delete == 1 ]; then
        sed -i "/^\[$uuid\]/,/^$/d" $CONFIG_FILE
        echo "volume $volume_name has been deleted."
    else
        echo "Deletion canceled. Exiting..."
        exit 1
    fi
}

# Main script

# Display drives
display_drives

if [ -z "$uuid" ]; then
    echo "Error retrieving the UUID of the selected volume, try to unplug and plug the drive again, then rerun the script. Exiting..."
    exit 1
fi

# Ask user the action he wants to perform
select_action

# In case of positive answer, ask the new volume name to user
if [ "$action" == 1 ]; then
    modify_setup

    # Add a new backup target
    if [ "$modify" == 1 ]; then
        new_target
    fi

    # Remove a backup target
    if [ "$modify" == 2 ]; then
        remove_target
    fi
fi

# In case of positive answer, ask the new volume name to user
if [ "$action" == 2 ]; then
    delete_setup
fi