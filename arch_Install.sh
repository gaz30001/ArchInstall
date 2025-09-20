#!/bin/bash

#-------------------- Цвета --------------------

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

set -e
clear

#-------------------- ASCII приветствие --------------------

echo -e "${YELLOW}"
cat << "EOF"


---

\ \      / /| | ___ ___  _ __ ___   ___
 \ \ /\ / /| | |/ __/ _ \| '_ ` _ \ / _ \
  \ V  V / | | | (_| (_) | | | | | |  __/
   \_/\_/  |_|_|\___\___/|_| |_| |_|\___|

EOF
echo -e "${RESET}${GREEN}Welcome to Arch Linux Automated Installer (Optimized for Older Hardware)!${RESET}"

#-------------------- Подтверждение --------------------

read -p "Do you want to continue? (y/N): " confirm
[[ "$confirm" != "y" ]] && echo -e "${RED}Aborted.${RESET}" && exit 1

#-------------------- Проверка интернета --------------------

ping -q -c 1 archlinux.org > /dev/null || { echo -e "${RED}No internet.${RESET}"; exit 1; }

#-------------------- Настройка времени --------------------

timedatectl set-ntp true

#-------------------- Выбор диска --------------------

echo -e "\n${GREEN}Available disks:${RESET}"
mapfile -t DISKS < <(lsblk -dpno NAME,SIZE | grep -v "boot")
for i in "${!DISKS[@]}"; do
    echo "$((i+1))) ${DISKS[$i]}"
done
read -p "Choose disk number to install on: " disk_index
DISK=$(echo ${DISKS[$((disk_index-1))]} | awk '{print $1}')

#-------------------- Тип таблицы --------------------

echo -e "\nPartition type:"
echo "1) GPT (UEFI)"
echo "2) MBR (BIOS)"
read -p "Choose (1-2): " part_type
[[ "$part_type" == "1" ]] && PART_TABLE="gpt" || PART_TABLE="mbr"

#-------------------- Хост и пользователь --------------------

read -p "Enter hostname [archlinux]: " HOSTNAME
HOSTNAME=${HOSTNAME:-archlinux}
read -p "Enter username [user]: " USERNAME
USERNAME=${USERNAME:-user}

#-------------------- Пароли --------------------

while true; do
    read -s -p "Enter root password: " ROOT_PASSWORD; echo
    read -s -p "Confirm root password: " ROOT_PASSWORD2; echo
    [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD2" ]] && break
    echo -e "${RED}Mismatch.${RESET}"
done

while true; do
    read -s -p "Password for $USERNAME: " USER_PASSWORD; echo
    read -s -p "Confirm password: " USER_PASSWORD2; echo
    [[ "$USER_PASSWORD" == "$USER_PASSWORD2" ]] && break
    echo -e "${RED}Mismatch.${RESET}"
done

#-------------------- Выбор таймзоны --------------------

# Этот раздел оставлен без изменений, так как он не влияет на производительность
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

#-------------------- Локали --------------------

echo -e "\nChoose locales (space-separated):"
LOCALE_LIST=("en_US.UTF-8 UTF-8" "ru_RU.UTF-8 UTF-8")
(for i in "${!LOCALE_LIST[@]}"; do echo "$((i+1))) ${LOCALE_LIST[$i]}"; done)
read -p "Locales [1 2]: " locale_choices
locale_choices=${locale_choices:-"1 2"}

#-------------------- Разметка диска (оптимизировано под Ext4) --------------------

umount -R /mnt || true
sgdisk --zap-all $DISK || true

if [[ "$PART_TABLE" == "gpt" ]]; then
    # GPT for UEFI
    sgdisk -n 1:0:+550M -t 1:ef00 $DISK   # EFI partition
    sgdisk -n 2:0:0 -t 2:8300 $DISK      # Linux root
    PART_EFI="${DISK}p1" # Используем суффикс 'p' для GPT, если диск nvme, то будет nvme0n1p1
    PART_ROOT="${DISK}p2"
    mkfs.fat -F32 $PART_EFI
else
    # MBR for BIOS
    parted -s $DISK mklabel msdos
    parted -s $DISK mkpart primary ext4 1MiB 100%
    parted -s $DISK set 1 boot on
    PART_ROOT="${DISK}1"
fi

echo -e "\n${YELLOW}Formatting root partition with Ext4 (fast and reliable for old hardware)...${RESET}"
mkfs.ext4 -F -L ArchLinux $PART_ROOT
mount $PART_ROOT /mnt
if [[ -n "$PART_EFI" ]]; then
    mkdir -p /mnt/boot
    mount $PART_EFI /mnt/boot
fi

#-------------------- Создание файла подкачки (Swap) --------------------
read -p "Enter swap file size in MB (e.g., 1024 for 1GB) [1024]: " SWAP_SIZE
SWAP_SIZE=${SWAP_SIZE:-1024}
dd if=/dev/zero of=/mnt/swapfile bs=1M count=$SWAP_SIZE status=progress
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
swapon /mnt/swapfile

#-------------------- Обновление зеркал --------------------

echo -e "\n${GREEN}Updating mirror list for faster downloads...${RESET}"
pacman -Sy --noconfirm reflector
reflector --verbose --country Russia,Germany --sort rate -n 10 --save /etc/pacman.d/mirrorlist

#-------------------- Установка системы (оптимизированный набор пакетов) --------------------

echo -e "\n${GREEN}Installing base system (pacstrap)... This may take a while.${RESET}"
# - linux-lts: ядро с долгосрочной поддержкой, лучше для старого железа
# - xf86-video-ati: драйвер для вашей видеокарты ATI Radeon X1250
# - openbox, tint2: легковесный оконный менеджер и панель
# - efibootmgr: нужен для UEFI загрузчика
# - Удалены: linux-zen, btrfs-progs, xf86-video-vesa, bspwm, polybar, go
pacstrap -K /mnt base base-devel linux-lts linux-firmware \
networkmanager dhcpcd zsh git sudo terminus-font xterm pcmanfm ranger feh \
xorg xorg-xinit mesa xf86-video-ati openbox tint2 efibootmgr grub

genfstab -U /mnt >> /mnt/etc/fstab
# Убедимся, что swap есть в fstab
echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

#-------------------- Настройки в chroot --------------------

arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
setfont ter-v18n # Шрифт Terminus для кириллицы

echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1       localhost" >> /etc/hosts
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts
EOF

#-------------------- Локали --------------------

for choice in $locale_choices; do
    echo "${LOCALE_LIST[$((choice-1))]}" >> /mnt/etc/locale.gen
done
first_choice=$(echo $locale_choices | awk '{print $1}')
arch-chroot /mnt locale-gen
arch-chroot /mnt bash -c "echo LANG=$(echo ${LOCALE_LIST[$((first_choice-1))]} | cut -d' ' -f1) > /etc/locale.conf"

#-------------------- root и пользователь --------------------

echo "root:$ROOT_PASSWORD" | arch-chroot /mnt chpasswd
arch-chroot /mnt useradd -m -G wheel,video,audio -s /bin/zsh $USERNAME
echo "$USERNAME:$USER_PASSWORD" | arch-chroot /mnt chpasswd
arch-chroot /mnt sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

#-------------------- Bootloader --------------------

if [[ "$PART_TABLE" == "gpt" ]]; then
    arch-chroot /mnt bootctl --path=/boot install
    UUID=$(blkid -s UUID -o value $PART_ROOT)
    echo "default arch-lts" > /mnt/boot/loader/loader.conf
    echo "timeout 3" >> /mnt/boot/loader/loader.conf
    cat <<BOOT > /mnt/boot/loader/entries/arch-lts.conf
title   Arch Linux (LTS)
linux   /vmlinuz-linux-lts
initrd  /initramfs-linux-lts.img
options root=UUID=$UUID rw
BOOT
else
    # Добавляем grub в pacstrap, если его там еще нет
#    pacman -S --noconfirm grub
    arch-chroot /mnt grub-install --target=i386-pc $DISK
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
fi

#-------------------- Службы --------------------

arch-chroot /mnt systemctl enable NetworkManager

#-------------------- ZSH и yay --------------------

arch-chroot /mnt su - $USERNAME -c "git clone https://github.com/ohmyzsh/ohmyzsh.git ~/.oh-my-zsh"
arch-chroot /mnt su - $USERNAME -c "git clone https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
arch-chroot /mnt su - $USERNAME -c "git clone https://github.com/zsh-users/zsh-syntax-highlighting ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting"
arch-chroot /mnt su - $USERNAME -c "cp ~/.oh-my-zsh/templates/zshrc.zsh-template ~/.zshrc"
arch-chroot /mnt su - $USERNAME -c "sed -i 's/ZSH_THEME=\"robbyrussell\"/ZSH_THEME=\"passion\"/' ~/.zshrc"
arch-chroot /mnt su - $USERNAME -c "sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' ~/.zshrc"

# Установка yay (без небезопасных правил sudo)
arch-chroot /mnt su - $USERNAME -c "cd ~ && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm"

#-------------------- Настройка графической сессии (Openbox) --------------------

# Создаем базовый .xinitrc для запуска Openbox
cat <<XINIT > /mnt/home/$USERNAME/.xinitrc
#!/bin/sh
# Загрузка ресурсов X (цвета и т.д.)
xrdb -merge ~/.Xresources &
# Запуск панели
tint2 &
# Запуск оконного менеджера Openbox
exec openbox-session
XINIT

# Копируем конфиги Openbox и Tint2 по умолчанию
arch-chroot /mnt su - $USERNAME -c "mkdir -p ~/.config/openbox && cp -r /etc/xdg/openbox/* ~/.config/openbox/"
arch-chroot /mnt su - $USERNAME -c "mkdir -p ~/.config/tint2 && cp /etc/xdg/tint2/tint2rc ~/.config/tint2/"
arch-chroot /mnt chown -R $USERNAME:$USERNAME /home/$USERNAME

#-------------------- Xresources Gruvbox --------------------

cat <<XCONF > /mnt/home/$USERNAME/.Xresources
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
XCONF
arch-chroot /mnt chown $USERNAME:$USERNAME /home/$USERNAME/.Xresources


#-------------------- Конец --------------------

echo -e "\n${GREEN}Installation complete!${RESET}"
echo -e "${YELLOW}After reboot, log in as '$USERNAME' and run the 'startx' command to start the graphical environment.${RESET}"
echo -e "${YELLOW}You may now reboot.${RESET}"
