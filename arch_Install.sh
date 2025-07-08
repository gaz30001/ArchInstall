#!/bin/bash

set -e

# Цвета
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
RESET="\e[0m"

# ASCII Welcome + пауза
clear
echo -e "${CYAN}"
echo "      _       _                 _                     _             _            "
echo "     / \   __| |_   _____ _ __ | |_ _   _ _ __   ___| |_ ___  _ __(_) ___  _ __  "
echo "    / _ \ / _\` \ \ / / _ \ '_ \| __| | | | '_ \ / __| __/ _ \| '__| |/ _ \| '_ \ "
echo "   / ___ \ (_| |\ V /  __/ | | | |_| |_| | | | | (__| || (_) | |  | | (_) | | | |"
echo "  /_/   \_\__,_| \_/ \___|_| |_|\__|\__,_|_| |_|\___|\__\___/|_|  |_|\___/|_| |_|"
echo -e "${RESET}"
echo -e "${YELLOW}Welcome! Installing Arch Linux with style... 🐧✨${RESET}\n"
sleep 2

# Проверка запуска от root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}This script must be run as root!${RESET}"
  exit 1
fi

# Функция отображения прогресса
function show_progress() {
  local msg="$1"
  echo -ne "${GREEN}==> $msg...${RESET}"
  sleep 0.3
  echo -e " ${BLUE}done.${RESET}"
}

# Функция выбора из списка
function select_from_list() {
    local prompt="$1"
    shift
    local options=("$@")
    local i=1
    echo -e "${YELLOW}$prompt${RESET}"
    for opt in "${options[@]}"; do
        echo -e "  ${GREEN}$i)${RESET} $opt"
        ((i++))
    done
    local choice
    while true; do
        read -p "Choose (1-${#options[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "${options[$((choice-1))]}"
            return
        else
            echo -e "${RED}Invalid input.${RESET}"
        fi
    done
}

# Выбор диска
mapfile -t DISKS < <(lsblk -dno NAME,SIZE | awk '{print $1 " (" $2 ")"}')
DISK_ENTRY=$(select_from_list "Choose a disk for installation:" "${DISKS[@]}")
DISK="/dev/$(echo "$DISK_ENTRY" | awk '{print $1}')"

# Выбор типа таблицы разделов
PART_TABLE=$(select_from_list "Select partition table type:" "gpt" "mbr")

# Имя хоста и пароли
read -p "Hostname [archlinux]: " HOSTNAME
HOSTNAME=${HOSTNAME:-archlinux}
read -s -p "Root password: " ROOT_PASS; echo
read -s -p "Confirm password: " ROOT_PASS2; echo
[[ "$ROOT_PASS" != "$ROOT_PASS2" ]] && echo "Passwords do not match" && exit 1
read -p "New username [oleg]: " USER
USER=${USER:-oleg}
read -s -p "Password for user: " USER_PASS; echo
read -s -p "Confirm password: " USER_PASS2; echo
[[ "$USER_PASS" != "$USER_PASS2" ]] && echo "Passwords do not match" && exit 1

# Выбор региона и зоны
mapfile -t REGIONS < <(timedatectl list-timezones | cut -d'/' -f1 | sort -u | grep -v -e '^$' -e '^Etc$')
REGION=$(select_from_list "Choose region:" "${REGIONS[@]}")
mapfile -t ZONES < <(timedatectl list-timezones | grep "^$REGION/")
TIMEZONE=$(select_from_list "Choose city/zone:" "${ZONES[@]}")

# Разметка диска и форматирование
umount -R /mnt 2>/dev/null || true
sgdisk --zap-all "$DISK"
if [ "$PART_TABLE" = "gpt" ]; then
  if [ -d /sys/firmware/efi ]; then
    sgdisk -n1:0:+550M -t1:ef00 -n2:0:0 -t2:8300 "$DISK"
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
    mkfs.fat -F32 "$EFI_PART"
  else
    sgdisk -n1:0:+1M -t1:ef02 -n2:0:0 -t2:8300 "$DISK"
    ROOT_PART="${DISK}2"
  fi
else
  parted -s "$DISK" mklabel msdos
  parted -s "$DISK" mkpart primary ext4 1MiB 100%
  parted -s "$DISK" set 1 boot on
  ROOT_PART="${DISK}1"
fi
mkfs.btrfs -f -L ArchLinux "$ROOT_PART"

# Монтирование и подтомы
mount "$ROOT_PART" /mnt
for sv in @ @home @snapshots @var_log; do
  btrfs subvolume create "/mnt/$sv"
  echo "Created subvolume: $sv"
done
umount /mnt

opts="noatime,compress=zstd:2,ssd,discard=async,space_cache=v2"
mount -o subvol=@,$opts "$ROOT_PART" /mnt
mkdir -p /mnt/{boot,home,.snapshots,var/log}
mount -o subvol=@home,$opts "$ROOT_PART" /mnt/home
mount -o subvol=@snapshots,$opts "$ROOT_PART" /mnt/.snapshots
mount -o subvol=@var_log,$opts "$ROOT_PART" /mnt/var/log
[ -n "$EFI_PART" ] && mount "$EFI_PART" /mnt/boot

# Установка системы
show_progress "Installing base system and packages"
pacstrap -K /mnt base base-devel linux linux-firmware linux-zen btrfs-progs networkmanager sudo zsh git nano terminus-font pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber rofi feh xterm bspwm sxhkd dunst xorg-server xorg-xinit xorg-xrandr xorg-xsetroot pcmanfm ranger lxappearance unzip

# fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Настройка внутри chroot
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Локаль
sed -i '/^#en_US.UTF-8 UTF-8/s/^#//' /etc/locale.gen
sed -i '/^#ru_RU.UTF-8 UTF-8/s/^#//' /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname
{
    echo "127.0.0.1 localhost"
    echo "::1       localhost"
    echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME"
} >> /etc/hosts

echo "root:$ROOT_PASS" | chpasswd

# Bootloader
if [ -d /sys/firmware/efi ]; then
    bootctl install
    UUID=\$(blkid -s UUID -o value $ROOT_PART)
    echo "default arch.conf" > /boot/loader/loader.conf
    echo -e "title Arch Linux\nlinux /vmlinuz-linux-zen\ninitrd /initramfs-linux-zen.img\noptions root=UUID=\$UUID rootflags=subvol=@ rw" > /boot/loader/entries/arch.conf
else
    pacman -S --noconfirm grub
    grub-install --target=i386-pc $DISK
    grub-mkconfig -o /boot/grub/grub.cfg
fi

# Пользователь
useradd -m -G wheel -s /bin/zsh $USER
echo "$USER:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
systemctl enable NetworkManager

# ZSH и oh-my-zsh
su - $USER -c '
  git clone https://github.com/ohmyzsh/ohmyzsh.git ~/.oh-my-zsh
  ZSH_CUSTOM=~/.oh-my-zsh/custom
  git clone https://github.com/zsh-users/zsh-autosuggestions \$ZSH_CUSTOM/plugins/zsh-autosuggestions
  git clone https://github.com/zsh-users/zsh-syntax-highlighting \$ZSH_CUSTOM/plugins/zsh-syntax-highlighting
  cp ~/.oh-my-zsh/templates/zshrc.zsh-template ~/.zshrc
  sed -i "s/ZSH_THEME=\"robbyrussell\"/ZSH_THEME=\"passion\"/" ~/.zshrc
  sed -i "s/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/" ~/.zshrc
'

# Yay
pacman -S --noconfirm go
su - $USER -c '
  cd /tmp
  git clone https://aur.archlinux.org/yay.git
  cd yay
  makepkg -si --noconfirm
'

# Polybar и Xresources Gruvbox
su - $USER -c '
mkdir -p ~/.config/polybar
cd ~/.config/polybar
curl -LO https://raw.githubusercontent.com/material-shell/material-shell/master/config/polybar/material/polybar.ini
'

su - $USER -c '
echo "! Gruvbox dark" > ~/.Xresources
echo "*.background: #282828" >> ~/.Xresources
echo "*.foreground: #ebdbb2" >> ~/.Xresources
for i in {0..15}; do echo "*.color\$i: #$(printf '%02x' $((RANDOM%256)))$(printf '%02x' $((RANDOM%256)))$(printf '%02x' $((RANDOM%256)))" >> ~/.Xresources; done
'
EOF

# Завершение
umount -R /mnt
echo -e "${GREEN}Installation complete. You may reboot now.${RESET}"
read -p "Reboot now? (y/N): " choice
[[ "$choice" =~ ^[Yy]$ ]] && reboot
