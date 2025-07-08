#!/bin/bash

set -e

# === Colors ===
RED="\e[31m"
GREEN="\e[32m"
CYAN="\e[36m"
YELLOW="\e[33m"
RESET="\e[0m"

# === ASCII WELCOME ===
echo -e "${CYAN}"
cat << "EOF"
    _            _                 _             _             
   /_\  _ __ ___| |_ _ __ ___  ___| |_ ___  _ __(_) ___  ___ 
  //_\\| '__/ __| __| '__/ _ \/ __| __/ _ \| '__| |/ _ \/ __|
 /  _  \ | | (__| |_| | |  __/\__ \ || (_) | |  | |  __/\__ \
 \_/ \_/_|  \___|\__|_|  \___||___/\__\___/|_|  |_|\___||___/
EOF
echo -e "${YELLOW}Welcome! Installing Arch Linux with style...${RESET}"

# === Confirm Start ===
echo -e "${RED}WARNING: This will erase all data on selected disk!${RESET}"
read -p "Continue? (y/N): " confirm
[[ "$confirm" == "y" ]] || exit 0

# === Detect Disks ===
echo -e "${GREEN}\nAvailable Disks:${RESET}"
mapfile -t DISKS < <(lsblk -dno NAME,SIZE | awk '{print $1}' )
for i in "${!DISKS[@]}"; do
    echo "$((i+1))) /dev/${DISKS[$i]}"
done
read -p "Choose your disk (1-${#DISKS[@]}): " disk_index
DISK="/dev/${DISKS[$((disk_index-1))]}"

# === Partition Table Type ===
echo -e "${GREEN}\nPartition table type:${RESET}"
OPTIONS=("GPT (UEFI recommended)" "MBR (Legacy BIOS)")
for i in "${!OPTIONS[@]}"; do
    echo "$((i+1))) ${OPTIONS[$i]}"
done
read -p "Choose (1-${#OPTIONS[@]}): " part_index
PART_TABLE="gpt"
[[ $part_index -eq 2 ]] && PART_TABLE="mbr"

# === Hostname ===
read -p "Enter hostname [archlinux]: " HOSTNAME
HOSTNAME=${HOSTNAME:-archlinux}

# === Username ===
read -p "Enter username [user]: " USERNAME
USERNAME=${USERNAME:-user}

# === Root password ===
while true; do
    read -s -p "Enter root password: " ROOT_PASSWORD; echo
    read -s -p "Confirm root password: " ROOT_PASSWORD2; echo
    [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD2" ]] && break
    echo -e "${RED}Passwords do not match. Try again.${RESET}"
done

# === User password ===
while true; do
    read -s -p "Enter password for $USERNAME: " USER_PASSWORD; echo
    read -s -p "Confirm password: " USER_PASSWORD2; echo
    [[ "$USER_PASSWORD" == "$USER_PASSWORD2" ]] && break
    echo -e "${RED}Passwords do not match. Try again.${RESET}"
done

# === Timezone Selection ===
echo -e "${GREEN}\nChoose your region:${RESET}"
mapfile -t REGIONS < <(timedatectl list-timezones | cut -d'/' -f1 | sort -u | grep -v -e '^$' -e '^Etc$')
for i in "${!REGIONS[@]}"; do
    echo "$((i+1))) ${REGIONS[$i]}"
done
read -p "Region (1-${#REGIONS[@]}): " region_choice
REGION="${REGIONS[$((region_choice-1))]}"

mapfile -t ZONES < <(timedatectl list-timezones | grep "^$REGION/")
echo -e "${GREEN}\nChoose your city:${RESET}"
for i in "${!ZONES[@]}"; do
    echo "$((i+1))) ${ZONES[$i]}"
done
read -p "City (1-${#ZONES[@]}): " zone_choice
TIMEZONE="${ZONES[$((zone_choice-1))]}"

# === Summary ===
echo -e "\n${CYAN}Summary:${RESET}"
echo -e "Disk: ${GREEN}$DISK${RESET}"
echo -e "Partition table: ${GREEN}$PART_TABLE${RESET}"
echo -e "Hostname: ${GREEN}$HOSTNAME${RESET}"
echo -e "Username: ${GREEN}$USERNAME${RESET}"
echo -e "Timezone: ${GREEN}$TIMEZONE${RESET}"
echo -e "\nReady to continue... (нажми Enter)"
read

# Далее идёт основной код установки (разметка, btrfs, pacstrap и т.д.)
# Ты можешь вставить сюда свои функции из предыдущего скрипта

# Заглушка:
echo -e "${GREEN}Script initialization complete. Continue installing...${RESET}"

exit 0
