#!/bin/bash

# Check if dry-run is set
if [[ "$1" == "--dry-run" ]]; then
    echo "Dry-run: No changes will be made."
    exit 0
fi

# Prompt user before installing 3X-UI
read -p "Do you want to install 3X-UI? (y/n): " choice
if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
    echo "Installing 3X-UI..."
    # Insert actual installation command here
else
    echo "Installation of 3X-UI skipped."
fi
