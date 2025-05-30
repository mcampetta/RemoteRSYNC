#!/bin/bash

# Function to create directories on the remote host
create_directories() {
  echo "Creating directory structure on remote server..."

  find "$SOURCE_FOLDER" -type d -not -path "$SOURCE_FOLDER/Volumes/*" -print0 | \
  ssh "$USER@$IP_ADDRESS" "xargs -0 -I{} sh -c 'mkdir -p \"$DESTINATION_FOLDER/{}\"'"

  echo "Directory structure creation complete."
}

# Function to copy files to the remote host
copy_files() {
  echo "Copying files to remote server..."

 find "$SOURCE_FOLDER" -type f -not -path "$SOURCE_FOLDER/Volumes/*" -print0 | \
 ssh "$USER@$IP_ADDRESS" 'xargs -0 -I{} sh -c "dd of=\"$DESTINATION_FOLDER/{}\" bs=4M"'

  echo "File transfer complete."
}

# Prompt for user input
echo "Welcome to the file transfer script!"
read -p "Enter the remote username: " USER
read -p "Enter the remote IP address: " IP_ADDRESS
read -p "Enter the source folder path (local): " SOURCE_FOLDER
read -p "Enter the destination folder path (remote): " DESTINATION_FOLDER

# Validate inputs
if [[ -z "$USER" || -z "$IP_ADDRESS" || -z "$SOURCE_FOLDER" || -z "$DESTINATION_FOLDER" ]]; then
  echo "Error: All inputs are required."
  exit 1
fi

# Confirm with the user before proceeding
echo ""
echo "You are about to execute the following actions:"
echo "  - Remote Username: $USER"
echo "  - Remote IP Address: $IP_ADDRESS"
echo "  - Source Folder: $SOURCE_FOLDER"
echo "  - Destination Folder: $DESTINATION_FOLDER"
echo ""
read -p "Do you want to continue? (y/n): " CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Operation canceled."
  exit 0
fi

# Execute the operations
create_directories
copy_files

echo "All operations completed successfully!"
