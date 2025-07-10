#!/bin/bash

#===========================================
#      WELCOME INSTALLER FOR ARCH LINUX
#      Style: BSPWM + POLYBAR (gruvbox)
#===========================================

set -e

# ========== COLORS ==========
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
RESET="\e[0m"

# ========== GREETING ==========
clear
echo -e "${CYAN}"
cat << "EOF"
__        __   _                            
\ \      / /__| | ___ ___  _ __ ___   ___  
 \ \ /\ / / _ \ |/ __/ _ \| '_ ` _ \ / _ \ 
  \ V  V /  __/ | (_| (_) | | | | | |  __/ 
   \_/\_/ \___|_|\___\___/|_| |_| |_|\___| 
EOF
echo -e "${RESET}${YELLOW}Welcome! Installing Arch Linux with style...${RESET}\n"

# ========== ASK TO CONTINUE ==========
read -p "Do you want to continue? (y/N): " confirm
[[ "$confirm" != "y" ]] && echo -e "${RED}Aborted.${RESET}" && exit 1

# ========== CHECK INTERNET ==========
ping -q -c 1 archlinux.org > /dev/null || { echo -e "${RED}No internet.${RESET}"; exit 1; }

# ========== TIME SETUP ==========
timedatectl set-ntp true

# ========== DISK CHOICE ==========
echo -e "${GREEN}Available disks:${RESET}"
mapfile -t DISKS < <(lsblk -dpno NAME,SIZE | grep -v "boot")
for i in "${!DISKS[@]}"; do
    echo "$((i+1))) ${DISKS[$i]}"
done
read -p "Choose disk number to install on: " disk_index
DISK=$(echo ${DISKS[$((disk_index-1))]} | awk '{print $1}')

# ========== PARTITION TABLE ==========
echo -e "\n${GREEN}Choose partition table:${RESET}"
echo "1) GPT (UEFI)"
echo "2) MBR (BIOS)"
read -p "Choose (1-2): " part_type
[[ "$part_type" == "1" ]] && PART_TABLE="gpt" || PART_TABLE="mbr"

# ========== HOSTNAME / USER ==========
read -p "Enter hostname [archlinux]: " HOSTNAME
HOSTNAME=${HOSTNAME:-archlinux}
read -p "Enter username [user]: " USERNAME
USERNAME=${USERNAME:-user}

# ========== PASSWORDS ==========
while true; do
    read -s -p "Enter root password: " ROOT_PASSWORD; echo
    read -s -p "Confirm root password: " ROOT_PASSWORD2; echo
    [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD2" ]] && break
    echo -e "${RED}Passwords don't match!${RESET}"
done

while true; do
    read -s -p "Enter password for $USERNAME: " USER_PASSWORD; echo
    read -s -p "Confirm password: " USER_PASSWORD2; echo
    [[ "$USER_PASSWORD" == "$USER_PASSWORD2" ]] && break
    echo -e "${RED}Passwords don't match!${RESET}"
done

# ========== TIMEZONE ==========
mapfile -t REGIONS < <(timedatectl list-timezones | cut -d'/' -f1 | sort -u | grep -v -e '^$' -e '^Etc$')
echo -e "\nChoose region:"
(for i in "${!REGIONS[@]}"; do printf "%3d) %-15s\n" "$((i+1))" "${REGIONS[$i]}"; done) | column
read -p "Region (1-${#REGIONS[@]}): " region_choice
SELECTED_REGION="${REGIONS[$((region_choice-1))]}"

mapfile -t ZONES < <(timedatectl list-timezones | grep "^$SELECTED_REGION/")
echo -e "\nChoose city:"
(for i in "${!ZONES[@]}"; do printf "%3d) %-25s\n" "$((i+1))" "${ZONES[$i]}"; done) | column
read -p "City (1-${#ZONES[@]}): " zone_choice
TIMEZONE="${ZONES[$((zone_choice-1))]}"

# ========== LOCALES ==========
LOCALE_LIST=("en_US.UTF-8 UTF-8" "ru_RU.UTF-8 UTF-8")
echo -e "\nChoose locales (e.g. 1 2):"
(for i in "${!LOCALE_LIST[@]}"; do echo "$((i+1))) ${LOCALE_LIST[$i]}"; done)
read -p "Locales: " locale_choices

# ========== FORMAT & MOUNT ==========
umount -R /mnt || true
sgdisk --zap-all $DISK || true

if [[ "$PART_TABLE" == "gpt" ]]; then
    sgdisk -n 1:0:+550M -t 1:ef00 $DISK
    sgdisk -n 2:0:0 -t 2:8300 $DISK
    PART_EFI="${DISK}1"; PART_ROOT="${DISK}2"
    mkfs.fat -F32 $PART_EFI
else
    parted -s $DISK mklabel msdos
    parted -s $DISK mkpart primary ext4 1MiB 100%
    parted -s $DISK set 1 boot on
    PART_ROOT="${DISK}1"
fi

mkfs.btrfs -f -L ArchLinux $PART_ROOT
mount -t btrfs $PART_ROOT /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@log
umount /mnt

mount -t btrfs -o subvol=@,noatime,compress=zstd:2,ssd,discard=async,space_cache=v2 $PART_ROOT /mnt
mkdir -p /mnt/{boot,home,.snapshots,var/log}
mount -t btrfs -o subvol=@home,noatime,compress=zstd:2,ssd,discard=async,space_cache=v2 $PART_ROOT /mnt/home
mount -t btrfs -o subvol=@snapshots,noatime,compress=zstd:2,ssd,discard=async,space_cache=v2 $PART_ROOT /mnt/.snapshots
mount -t btrfs -o subvol=@log,noatime,compress=zstd:2,ssd,discard=async,space_cache=v2 $PART_ROOT /mnt/var/log
[[ -n "$PART_EFI" ]] && mount $PART_EFI /mnt/boot

# ========== INSTALL BASE ==========
pacstrap -K /mnt base base-devel linux-zen linux-firmware btrfs-progs \
  networkmanager zsh git grub sudo terminus-font xterm pcmanfm ranger \
  feh xorg xorg-xinit mesa xf86-video-vesa bspwm polybar neovim

genfstab -U /mnt >> /mnt/etc/fstab

# ========== CONFIGURATION IN CHROOT ==========
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
setfont ter-v16b

echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1       localhost" >> /etc/hosts
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

for choice in $locale_choices; do
    echo "\${LOCALE_LIST[\$((choice-1))]}" >> /etc/locale.gen
done
locale-gen

first_choice=\$(echo $locale_choices | awk '{print \$1}')
echo LANG=\$(echo \${LOCALE_LIST[\$((first_choice-1))]} | cut -d' ' -f1) > /etc/locale.conf

# Users
useradd -m -G wheel,video,audio -s /bin/zsh $USERNAME
echo "$USERNAME:$USER_PASSWORD" | chpasswd
echo "root:$ROOT_PASSWORD" | chpasswd

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Bootloader
EOF

if [[ "$PART_TABLE" == "gpt" ]]; then
  arch-chroot /mnt bootctl --path=/boot install
  UUID=$(blkid -s UUID -o value $PART_ROOT)
  echo "default arch" > /mnt/boot/loader/loader.conf
  cat <<BOOT > /mnt/boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux-zen
initrd  /initramfs-linux-zen.img
options root=UUID=$UUID rootflags=subvol=@ rw
BOOT
else
  arch-chroot /mnt grub-install --target=i386-pc $DISK
  arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
fi

# Services
touch /mnt/etc/X11/xinit/xinitrc
echo "exec bspwm" >> /mnt/etc/X11/xinit/xinitrc
arch-chroot /mnt systemctl enable NetworkManager

# Oh-my-zsh, yay, gruvbox setup
arch-chroot /mnt su - $USERNAME -c "git clone https://aur.archlinux.org/yay.git ~/yay && cd ~/yay && makepkg -si --noconfirm"
arch-chroot /mnt su - $USERNAME -c "mkdir -p ~/.config/polybar && mkdir -p ~/.config/bspwm"

# .Xresources
cat <<XRES > /mnt/home/$USERNAME/.Xresources
*.foreground:   #ebdbb2
*.background:   #282828
*.color0:       #282828
*.color1:       #cc241d
*.color2:       #98971a
*.color3:       #d79921
*.color4:       #458588
*.color5:       #b16286
*.color6:       #689d6a
*.color7:       #a89984
*.color8:       #928374
*.color9:       #fb4934
*.color10:      #b8bb26
*.color11:      #fabd2f
*.color12:      #83a598
*.color13:      #d3869b
*.color14:      #8ec07c
*.color15:      #ebdbb2
XRES

arch-chroot /mnt chown $USERNAME:$USERNAME /home/$USERNAME/.Xresources

# DONE
echo -e "\n${GREEN}Installation complete! Reboot and enjoy your Arch!${RESET}"
