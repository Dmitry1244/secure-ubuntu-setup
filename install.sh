#!/bin/bash

# Install script for secure Ubuntu setup

# Update package list
sudo apt-get update

# Install necessary packages
sudo apt-get install -y git curl ufw

# Configure UFW firewall
sudo ufw allow OpenSSH
sudo ufw enable
