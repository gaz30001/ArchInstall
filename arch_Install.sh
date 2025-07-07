#!/bin/bash

# Скрипт остановится, если какая-либо команда завершится с ошибкой
set -e

# Цвета для вывода
GREEN="\e[32m"
RED="\e[31m"
RESET="\e[0m"

# Функция для интерактивного выбора временной зоны
function select_timezone() {
    mapfile -t REGIONS < <(timedatectl list-timezones | cut -d'/' -f1 | sort -u | grep -v -e '^$' -e '^Etc$')
    echo -e "\n${GREEN}--- Настройка временной зоны ---${RESET}"
    echo "Выберите ваш регион:"
    # Выводим пронумерованный список в несколько столбцов
    (
        for i in "${!REGIONS[@]}"; do
            printf "%3d) %s\n" "$((i+1))" "${REGIONS[$i]}"
        done
    ) | column

    local region_choice
    while true; do
        read -p "Введите номер региона: " region_choice
        if [[ "$region_choice" =~ ^[0-9]+$ ]] && [ "$region_choice" -ge 1 ] && [ "$region_choice" -le "${#REGIONS[@]}" ]; then
            break
        else
            echo -e "${RED}Неверный ввод. Пожалуйста, введите число от 1 до ${#REGIONS[@]}.${RESET}"
        fi
    done
    local SELECTED_REGION="${REGIONS[$((region_choice-1))]}"

    mapfile -t ZONES < <(timedatectl list-timezones | grep "^$SELECTED_REGION/")
    echo -e "\nВыберите ваш город/зону:"
    # Выводим второй список также в несколько столбцов
    (
        for i in "${!ZONES[@]}"; do
            printf "%3d) %s\n" "$((i+1))" "${ZONES[$i]}"
        done
    ) | column

    local zone_choice
    while true; do
        read -p "Введите номер города/зоны: " zone_choice
        if [[ "$zone_choice" =~ ^[0-9]+$ ]] && [ "$zone_choice" -ge 1 ] && [ "$zone_choice" -le "${#ZONES[@]}" ]; then
            break
        else
            echo -e "${RED}Неверный ввод. Пожалуйста, введите число от 1 до ${#ZONES[@]}.${RESET}"
        fi
    done
    
    TIMEZONE="${ZONES[$((zone_choice-1))]}"
}


echo -e "${GREEN}### Интерактивный установщик Arch Linux с BTRFS и ZSH ###${RESET}"
echo -e "${GREEN}### Версия с ядром Zen и выводом в столбцы ###${RESET}"
echo -e "${RED}ВНИМАНИЕ: Этот скрипт сотрет все данные на выбранном диске!${RESET}"
read -p "Вы уверены, что хотите продолжить? (y/N): " confirm
if [[ "$confirm" != "y" ]]; then
    echo "Установка отменена."
    exit 1
fi

# 1. Сбор информации от пользователя
#------------------------------------------------------------------------------------
echo -e "\n${GREEN}Доступные диски:${RESET}"
lsblk -d -o NAME,SIZE,MODEL
read -p "Введите имя диска для установки (например, sda или nvme0n1): " DISK
DISK="/dev/${DISK}"
if [ ! -b "$DISK" ]; then
    echo -e "${RED}Ошибка: Диск $DISK не найден!${RESET}"
    exit 1
fi

read -p "Выберите таблицу разделов (GPT/MBR) [gpt]: " PART_TABLE
PART_TABLE=${PART_TABLE:-gpt}

read -p "Введите имя хоста (hostname) [archlinux]: " HOSTNAME
HOSTNAME=${HOSTNAME:-archlinux}

while true; do
    read -s -p "Введите пароль для root: " ROOT_PASSWORD; echo
    read -s -p "Подтвердите пароль для root: " ROOT_PASSWORD2; echo
    [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD2" ] && break
    echo -e "${RED}Пароли не совпадают. Попробуйте еще раз.${RESET}"
done

read -p "Введите имя нового пользователя [user]: " USERNAME
USERNAME=${USERNAME:-user}
while true; do
    read -s -p "Введите пароль для пользователя $USERNAME: " USER_PASSWORD; echo
    read -s -p "Подтвердите пароль: " USER_PASSWORD2; echo
    [ "$USER_PASSWORD" = "$USER_PASSWORD2" ] && break
    echo -e "${RED}Пароли не совпадают. Попробуйте еще раз.${RESET}"
done

select_timezone
echo -e "Выбрана временная зона: ${GREEN}$TIMEZONE${RESET}"

# 2. Подготовка системы
#------------------------------------------------------------------------------------
echo -e "\n${GREEN}Настройка системного времени...${RESET}"
timedatectl set-ntp true

# 3. Разметка диска и форматирование
#------------------------------------------------------------------------------------
echo -e "\n${GREEN}Очистка и разметка диска $DISK...${RESET}"
umount -R /mnt 2>/dev/null || true
sgdisk --zap-all $DISK

UEFI_MODE=false
if [ -d "/sys/firmware/efi/efivars" ]; then UEFI_MODE=true; fi

if $UEFI_MODE && [ "$PART_TABLE" = "gpt" ]; then
    echo "Режим UEFI/GPT обнаружен."
    sgdisk -n 1:0:+550M -t 1:ef00 $DISK
    sgdisk -n 2:0:0 -t 2:8300 $DISK
    PART_EFI="${DISK}1"; PART_ROOT="${DISK}2"
    mkfs.fat -F32 $PART_EFI
elif [ "$PART_TABLE" = "gpt" ]; then
    echo "Режим BIOS/GPT обнаружен."
    sgdisk -n 1:0:+1M -t 1:ef02 $DISK
    sgdisk -n 2:0:0 -t 2:8300 $DISK
    PART_ROOT="${DISK}2"
else
    echo "Режим BIOS/MBR обнаружен."
    parted -s $DISK mklabel msdos
    parted -s $DISK mkpart primary ext4 1MiB 100%
    parted -s $DISK set 1 boot on
    PART_ROOT="${DISK}1"
fi

echo -e "${GREEN}Форматирование корневого раздела в BTRFS...${RESET}"
mkfs.btrfs -f -L ArchLinux $PART_ROOT

# 4. Монтирование BTRFS с подтомами
#------------------------------------------------------------------------------------
echo -e "${GREEN}Создание и монтирование подтомов BTRFS...${RESET}"
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

# 5. Установка базовой системы
#------------------------------------------------------------------------------------
echo -e "\n${GREEN}Установка базовых пакетов с ядром Zen (может занять время)...${RESET}"
pacstrap -K /mnt base base-devel linux-zen linux-zen-headers linux-firmware btrfs-progs networkmanager nano git zsh grub sudo

# 6. Конфигурация системы
#------------------------------------------------------------------------------------
echo -e "${GREEN}Генерация fstab...${RESET}"
genfstab -U /mnt >> /mnt/etc/fstab

echo -e "${GREEN}Настройка системы внутри chroot...${RESET}"
arch-chroot /mnt /bin/bash <<EOF

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname
{
    echo "127.0.0.1 localhost"
    echo "::1       localhost"
    echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME"
} >> /etc/hosts

echo "root:$ROOT_PASSWORD" | chpasswd

if [ -d "/sys/firmware/efi/efivars" ]; then
    echo "Установка systemd-boot (UEFI)..."
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
    echo "Установка GRUB (BIOS)..."
    pacman -S --noconfirm os-prober
    grub-install --target=i386-pc $DISK
    grub-mkconfig -o /boot/grub/grub.cfg
fi

echo "Создание пользователя и настройка sudo..."
useradd -m -G wheel -s /bin/zsh "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager

echo "Настройка ZSH для пользователя $USERNAME..."
su - "$USERNAME" <<'ZSH_SETUP'
git clone https://github.com/ohmyzsh/ohmyzsh.git ~/.oh-my-zsh
ZSH_CUSTOM="~/.oh-my-zsh/custom"
git clone https://github.com/zsh-users/zsh-autosuggestions \${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
cp ~/.oh-my-zsh/templates/zshrc.zsh-template ~/.zshrc
sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="passion"/' ~/.zshrc
sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' ~/.zshrc
ZSH_SETUP

echo "Установка AUR-хелпера yay..."
su - "$USERNAME" <<'YAY_INSTALL'
cd /tmp
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
cd /
rm -rf /tmp/yay
YAY_INSTALL

EOF

# 7. Завершение
#------------------------------------------------------------------------------------
echo -e "\n${GREEN}Установка завершена!${RESET}"
umount -R /mnt
echo "Теперь вы можете перезагрузить систему. Не забудьте извлечь установочный носитель."
read -p "Перезагрузить систему сейчас? (y/N): " reboot_confirm
if [[ "$reboot_confirm" == "y" ]]; then
    reboot
fi

exit 0
