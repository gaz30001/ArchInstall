#!/bin/bash

# Скрипт остановится, если какая-либо команда завершится с ошибкой
set -e

# --- Цвета для вывода ---
GREEN="\e[32m"
RED="\e[31m"
BLUE="\e[34m"
YELLOW="\e[33m"
RESET="\e[0m"

# Очистка экрана и отображение баннера
clear
echo -e "${BLUE}"
echo "     _             _             _           _             "
echo "    / \   ___ __ _| |_ ___  _ __(_) ___ __| |_ ___ _ __  "
echo "   / _ \ / __/ _\` | __/ _ \| '__| |/ __/ _\` | __/ _ \ '__| "
echo "  / ___ \ (_| (_| | || (_) | |  | | (_| (_| | ||  __/ |    "
echo " /_/   \_\___\__,_|\__\___/|_|  |_|\___\__,_|\__\___|_|    "
echo -e "${RESET}"
echo -e "${YELLOW}Welcome! Installing Arch Linux with style...${RESET}"

# Проверка на запуск от имени root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Please run as root.${RESET}"
   exit 1
fi

# Установка более читаемого шрифта для консоли
setfont ter-132n || true

# --- ИСПРАВЛЕННЫЕ ФУНКЦИИ ---

# Эта функция ТОЛЬКО отображает опции в столбцах
display_options() {
    local -n options_ref=$1
    for i in "${!options_ref[@]}"; do
        printf "%3d) %s\n" "$((i+1))" "${options_ref[$i]}"
    done | column
}

# Эта функция ТОЛЬКО запрашивает ввод у пользователя
prompt_for_choice() {
    local -n options_ref=$1
    local prompt_text=$2
    local choice

    while true; do
        read -p "$prompt_text" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options_ref[@]}" ]; then
            echo "${options_ref[$((choice-1))]}"
            return
        else
            echo -e "${RED}Invalid input. Try again.${RESET}"
        fi
    done
}

# Функция для выбора временной зоны
select_timezone() {
    mapfile -t REGIONS < <(timedatectl list-timezones | cut -d'/' -f1 | sort -u | grep -v -e '^$' -e '^Etc$')
    echo -e "\n${GREEN}Select region:${RESET}"
    display_options REGIONS
    SELECTED_REGION=$(prompt_for_choice REGIONS "Region (1-${#REGIONS[@]}): ")
    
    mapfile -t ZONES < <(timedatectl list-timezones | grep "^$SELECTED_REGION/")
    echo -e "\n${GREEN}Select city/zone:${RESET}"
    display_options ZONES
    TIMEZONE=$(prompt_for_choice ZONES "Zone (1-${#ZONES[@]}): ")
}

# --- Сбор данных от пользователя ---

mapfile -t DISKS < <(lsblk -dno NAME,SIZE | awk '{print $1 " (" $2 ")"}')
echo -e "\n${GREEN}Select target disk (all data will be erased):${RESET}"
display_options DISKS
DISK_FULL=$(prompt_for_choice DISKS "Choice (1-${#DISKS[@]}): ")
DISK="/dev/$(echo $DISK_FULL | awk '{print $1}')"

PARTS=("GPT" "MBR")
echo -e "\n${GREEN}Select partition table:${RESET}"
display_options PARTS
PART_TABLE=$(prompt_for_choice PARTS "Choice (1-${#PARTS[@]}): ")
PART_TABLE=${PART_TABLE,,}

read -p "Hostname [arch]: " HOSTNAME
HOSTNAME=${HOSTNAME:-arch}

read -p "Username [oleg]: " USERNAME
USERNAME=${USERNAME:-oleg}

while true; do
    read -s -p "Root password: " ROOT_PASSWORD; echo
    read -s -p "Confirm root password: " ROOT_PASSWORD2; echo
    [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD2" ] && break
    echo -e "${RED}Passwords don't match.${RESET}"
done
while true; do
    read -s -p "Password for $USERNAME: " USER_PASSWORD; echo
    read -s -p "Confirm: " USER_PASSWORD2; echo
    [ "$USER_PASSWORD" = "$USER_PASSWORD2" ] && break
    echo -e "${RED}Passwords don't match.${RESET}"
done

LOCALES=("en_US.UTF-8" "ru_RU.UTF-8" "de_DE.UTF-8")
echo -e "\n${GREEN}Select default locale:${RESET}"
display_options LOCALES
DEFAULT_LOCALE=$(prompt_for_choice LOCALES "Choice (1-${#LOCALES[@]}): ")

select_timezone

# --- Начало установки ---

echo -e "\n${GREEN}Enabling NTP...${RESET}"
timedatectl set-ntp true

echo -e "${YELLOW}Wiping disk $DISK...${RESET}"
umount -R /mnt 2>/dev/null || true
sgdisk --zap-all $DISK

UEFI_MODE=false
if [ -d "/sys/firmware/efi/efivars" ]; then UEFI_MODE=true; fi

if $UEFI_MODE && [ "$PART_TABLE" = "gpt" ]; then
    sgdisk -n 1:0:+550M -t 1:ef00 $DISK
    sgdisk -n 2:0:0 -t 2:8300 $DISK
    PART_EFI="${DISK}1"; PART_ROOT="${DISK}2"
    mkfs.fat -F32 $PART_EFI
elif [ "$PART_TABLE" = "gpt" ]; then
    sgdisk -n 1:0:+1M -t 1:ef02 $DISK
    sgdisk -n 2:0:0 -t 2:8300 $DISK
    PART_ROOT="${DISK}2"
else
    parted -s $DISK mklabel msdos
    parted -s $DISK mkpart primary ext4 1MiB 100%
    parted -s $DISK set 1 boot on
    PART_ROOT="${DISK}1"
fi

echo -e "${GREEN}Formatting BTRFS...${RESET}"
mkfs.btrfs -f -L ArchLinux $PART_ROOT

echo -e "${GREEN}Creating & mounting BTRFS subvolumes...${RESET}"
BTRFS_OPTS="noatime,compress=zstd:2,ssd,discard=async,space_cache=v2"
mount -t btrfs -o $BTRFS_OPTS $PART_ROOT /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
umount /mnt

mount -t btrfs -o subvol=@,$BTRFS_OPTS $PART_ROOT /mnt
mkdir -p /mnt/{boot,home,.snapshots,var/log}
mount -t btrfs -o subvol=@home,$BTRFS_OPTS $PART_ROOT /mnt/home
mount -t btrfs -o subvol=@snapshots,$BTRFS_OPTS $PART_ROOT /mnt/.snapshots
mount -t btrfs -o subvol=@var_log,$BTRFS_OPTS $PART_ROOT /mnt/var/log
if [ -n "$PART_EFI" ]; then mount $PART_EFI /mnt/boot; fi

echo -e "${GREEN}Installing base system & packages...${RESET}"
pacstrap -K /mnt base base-devel linux-zen linux-zen-headers linux-firmware \
  btrfs-progs networkmanager nano git zsh grub sudo terminus-font \
  bspwm sxhkd polybar xterm xorg xorg-xinit feh pcmanfm ranger \
  go

echo -e "${GREEN}Generating fstab...${RESET}"
genfstab -U /mnt >> /mnt/etc/fstab

echo -e "${GREEN}Chrooting into new system to configure...${RESET}"
arch-chroot /mnt /bin/bash <<EOF

# Timezone & Clock
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Localization
echo "$DEFAULT_LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$DEFAULT_LOCALE" > /etc/locale.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
{
    echo "127.0.0.1 localhost"
    echo "::1       localhost"
    echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME"
} >> /etc/hosts

# Passwords
echo "root:$ROOT_PASSWORD" | chpasswd

# Bootloader
if [ -d "/sys/firmware/efi/efivars" ]; then
    bootctl --path=/boot install
    ROOT_UUID=\$(blkid -s UUID -o value $PART_ROOT)
    echo "default arch-zen.conf" > /boot/loader/loader.conf
    {
        echo "title   Arch Linux (Zen Kernel)"
        echo "linux   /vmlinuz-linux-zen"
        echo "initrd  /initramfs-linux-zen.img"
        echo "options root=UUID=\$ROOT_UUID rootflags=subvol=@ rw"
    } > /boot/loader/entries/arch-zen.conf
else
    pacman -S --noconfirm os-prober
    grub-install --target=i386-pc $DISK
    grub-mkconfig -o /boot/grub/grub.cfg
fi

# User setup
useradd -m -G wheel -s /bin/zsh "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Enable services
systemctl enable NetworkManager

# --- User-specific configuration ---
su - "$USERNAME" <<'USERCONF'
# ZSH and Oh My Zsh
git clone https://github.com/ohmyzsh/ohmyzsh.git ~/.oh-my-zsh
ZSH_CUSTOM="~/.oh-my-zsh/custom"
git clone https://github.com/zsh-users/zsh-autosuggestions \${ZSH_CUSTOM}/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting
cp ~/.oh-my-zsh/templates/zshrc.zsh-template ~/.zshrc
sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="passion"/' ~/.zshrc
sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' ~/.zshrc

# AUR helper (yay)
git clone https://aur.archlinux.org/yay.git /tmp/yay
cd /tmp/yay && makepkg -si --noconfirm && cd / && rm -rf /tmp/yay

# Window Manager config (bspwm)
mkdir -p ~/.config/{bspwm,sxhkd,polybar}
cp /usr/share/doc/bspwm/examples/bspwmrc ~/.config/bspwm/
cp /usr/share/doc/bspwm/examples/sxhkdrc ~/.config/sxhkd/
chmod +x ~/.config/bspwm/bspwmrc

# Xorg startup and resources
echo 'exec bspwm' > ~/.xinitrc

echo '*background: #282828\n*foreground: #ebdbb2\n*color0: #282828\n*color1: #cc241d\n*color2: #98971a\n*color3: #d79921\n*color4: #458588\n*color5: #b16286\n*color6: #689d6a\n*color7: #a89984\n*color8: #928374\n*color9: #fb4934\n*color10: #b8bb26\n*color11: #fabd2f\n*color12: #83a598\n*color13: #d3869b\n*color14: #8ec07c\n*color15: #ebdbb2' > ~/.Xresources
xrdb ~/.Xresources
USERCONF

EOF

# --- Завершение ---
umount -R /mnt
echo -e "${GREEN}Installation complete! Remove install media and reboot.${RESET}"
read -p "Reboot now? (y/N): " confirm
[[ "$confirm" == "y" || "$confirm" == "Y" ]] && reboot

exit 0
