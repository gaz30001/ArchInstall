#!/bin/bash

# Скрипт остановится, если какая-либо команда завершится с ошибкой
set -e

# Цвета для вывода
GREEN="\e[32m"
RED="\e[31m"
RESET="\e[0m"

echo -e "${GREEN}### Интерактивный установщик Arch Linux с BTRFS и ZSH ###${RESET}"
echo -e "${RED}ВНИМАНИЕ: Этот скрипт сотрет все данные на выбранном диске!${RESET}"
read -p "Вы уверены, что хотите продолжить? (y/N): " confirm
if [[ "$confirm" != "y" ]]; then
    echo "Установка отменена."
    exit 1
fi

# 1. Сбор информации от пользователя
#------------------------------------------------------------------------------------

# Выбор диска
echo -e "\n${GREEN}Доступные диски:${RESET}"
lsblk -d -o NAME,SIZE,MODEL
read -p "Введите имя диска для установки (например, sda или nvme0n1): " DISK
DISK="/dev/${DISK}"
if [ ! -b "$DISK" ]; then
    echo -e "${RED}Ошибка: Диск $DISK не найден!${RESET}"
    exit 1
fi

# Выбор таблицы разделов
read -p "Выберите таблицу разделов (GPT/MBR) [gpt]: " PART_TABLE
PART_TABLE=${PART_TABLE:-gpt}
if [[ "$PART_TABLE" != "gpt" && "$PART_TABLE" != "mbr" ]]; then
    echo -e "${RED}Неверный выбор. Используется GPT.${RESET}"
    PART_TABLE="gpt"
fi
echo -e "Выбрана таблица разделов: ${GREEN}$PART_TABLE${RESET}"

# Имя хоста
read -p "Введите имя хоста (hostname) [archlinux]: " HOSTNAME
HOSTNAME=${HOSTNAME:-archlinux}

# Пароль root
while true; do
    read -s -p "Введите пароль для root: " ROOT_PASSWORD
    echo
    read -s -p "Подтвердите пароль для root: " ROOT_PASSWORD2
    echo
    [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD2" ] && break
    echo -e "${RED}Пароли не совпадают. Попробуйте еще раз.${RESET}"
done

# Создание пользователя
read -p "Введите имя нового пользователя [user]: " USERNAME
USERNAME=${USERNAME:-user}
while true; do
    read -s -p "Введите пароль для пользователя $USERNAME: " USER_PASSWORD
    echo
    read -s -p "Подтвердите пароль: " USER_PASSWORD2
    echo
    [ "$USER_PASSWORD" = "$USER_PASSWORD2" ] && break
    echo -e "${RED}Пароли не совпадают. Попробуйте еще раз.${RESET}"
done

# Временная зона
# timedatectl list-timezones # Раскомментируйте, если нужен полный список
echo -e "\n${GREEN}Настройка временной зоны.${RESET}"
read -p "Введите вашу временную зону (например, Europe/Moscow) [Europe/Moscow]: " TIMEZONE
TIMEZONE=${TIMEZONE:-Europe/Moscow}


# 2. Подготовка системы
#------------------------------------------------------------------------------------
echo -e "\n${GREEN}Настройка системного времени...${RESET}"
timedatectl set-ntp true

# 3. Разметка диска и форматирование
#------------------------------------------------------------------------------------
echo -e "\n${GREEN}Очистка и разметка диска $DISK...${RESET}"
umount -R /mnt 2>/dev/null || true
sgdisk --zap-all $DISK

# Определение режима загрузки (BIOS/UEFI)
UEFI_MODE=false
if [ -d "/sys/firmware/efi/efivars" ]; then
    UEFI_MODE=true
fi

if $UEFI_MODE && [ "$PART_TABLE" = "gpt" ]; then
    echo "Режим UEFI/GPT обнаружен."
    sgdisk -n 1:0:+550M -t 1:ef00 $DISK # EFI раздел
    sgdisk -n 2:0:0 -t 2:8300 $DISK     # Linux раздел
    PART_EFI="${DISK}1"
    PART_ROOT="${DISK}2"
    mkfs.fat -F32 $PART_EFI
elif [ "$PART_TABLE" = "gpt" ]; then # BIOS/GPT
    echo "Режим BIOS/GPT обнаружен."
    sgdisk -n 1:0:+1M -t 1:ef02 $DISK  # BIOS boot раздел
    sgdisk -n 2:0:0 -t 2:8300 $DISK   # Linux раздел
    PART_ROOT="${DISK}2"
else # BIOS/MBR
    echo "Режим BIOS/MBR обнаружен."
    parted -s $DISK mklabel msdos
    parted -s $DISK mkpart primary ext4 1MiB 100%
    parted -s $DISK set 1 boot on
    PART_ROOT="${DISK}1"
fi

echo -e "${GREEN}Форматирование корневого раздела в BTRFS...${RESET}"
mkfs.btrfs -f -L ArchLinux $PART_ROOT

# 4. Монтирование BTRFS с подтомами (subvolumes)
#------------------------------------------------------------------------------------
echo -e "${GREEN}Создание и монтирование подтомов BTRFS...${RESET}"
BTRFS_OPTS="noatime,compress=zstd:2,ssd,discard=async,space_cache=v2"
mount -t btrfs -o $BTRFS_OPTS $PART_ROOT /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log

umount /mnt

# Монтирование подтомов с нужными опциями
mount -t btrfs -o subvol=@,$BTRFS_OPTS $PART_ROOT /mnt
mkdir -p /mnt/{boot,home,.snapshots,var/log}
mount -t btrfs -o subvol=@home,$BTRFS_OPTS $PART_ROOT /mnt/home
mount -t btrfs -o subvol=@snapshots,$BTRFS_OPTS $PART_ROOT /mnt/.snapshots
mount -t btrfs -o subvol=@var_log,$BTRFS_OPTS $PART_ROOT /mnt/var/log

# Монтирование EFI раздела, если он есть
if [ -n "$PART_EFI" ]; then
    mount $PART_EFI /mnt/boot
fi

# 5. Установка базовой системы
#------------------------------------------------------------------------------------
echo -e "\n${GREEN}Установка базовых пакетов (может занять время)...${RESET}"
pacstrap -K /mnt base linux linux-firmware btrfs-progs networkmanager nano git zsh grub

# 6. Конфигурация системы
#------------------------------------------------------------------------------------
echo -e "${GREEN}Генерация fstab...${RESET}"
genfstab -U /mnt >> /mnt/etc/fstab

echo -e "${GREEN}Настройка системы внутри chroot...${RESET}"
arch-chroot /mnt /bin/bash <<EOF

# Установка временной зоны
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Локализация
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf

# Настройка сети
echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1       localhost" >> /etc/hosts
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

# Пароль root
echo "root:$ROOT_PASSWORD" | chpasswd

# Установка загрузчика
if [ -d "/sys/firmware/efi/efivars" ]; then
    # Установка systemd-boot для UEFI
    echo "Установка systemd-boot (UEFI)..."
    bootctl --path=/boot install

    # Конфигурация systemd-boot
    echo "default arch.conf" > /boot/loader/loader.conf
    echo "timeout 3" >> /boot/loader/loader.conf
    echo "editor no" >> /boot/loader/loader.conf

    # Получение UUID корневого раздела
    ROOT_UUID=\$(blkid -s UUID -o value $PART_ROOT)
    echo "title   Arch Linux" > /boot/loader/entries/arch.conf
    echo "linux   /vmlinuz-linux" >> /boot/loader/entries/arch.conf
    echo "initrd  /initramfs-linux.img" >> /boot/loader/entries/arch.conf
    echo "options root=UUID=\$ROOT_UUID rootflags=subvol=@ rw" >> /boot/loader/entries/arch.conf
else
    # Установка GRUB для BIOS
    echo "Установка GRUB (BIOS)..."
    pacman -S --noconfirm os-prober # на всякий случай, если есть другие ОС
    grub-install --target=i386-pc $DISK
    grub-mkconfig -o /boot/grub/grub.cfg
fi

# Создание пользователя и настройка sudo
useradd -m -G wheel -s /bin/zsh "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd
# Раскомментируем строку для группы wheel в sudoers
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Включение NetworkManager
systemctl enable NetworkManager

echo "Настройка ZSH для пользователя $USERNAME..."
# Установка Oh My Zsh и плагинов от имени нового пользователя
su - "$USERNAME" <<'ZSH_SETUP'
# Клонируем Oh My Zsh
git clone https://github.com/ohmyzsh/ohmyzsh.git ~/.oh-my-zsh

# Клонируем плагины
ZSH_CUSTOM="~/.oh-my-zsh/custom"
git clone https://github.com/zsh-users/zsh-autosuggestions \${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

# Создаем .zshrc файл с нужными настройками
cp ~/.oh-my-zsh/templates/zshrc.zsh-template ~/.zshrc
sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="passion"/' ~/.zshrc
sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' ~/.zshrc
ZSH_SETUP

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
