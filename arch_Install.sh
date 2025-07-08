#!/bin/bash
set -e

GREEN="\e[32m"
RED="\e[31m"
RESET="\e[0m"

# Выбор локали
function select_locale() {
    echo -e "\n${GREEN}--- Выбор локали ---${RESET}"
    LOCALES=("en_US.UTF-8" "ru_RU.UTF-8" "de_DE.UTF-8" "fr_FR.UTF-8")

    for i in "${!LOCALES[@]}"; do
        printf "%2d) %s\n" $((i+1)) "${LOCALES[$i]}"
    done | column

    while true; do
        read -p "Введите номер локали: " locale_choice
        if [[ "$locale_choice" =~ ^[0-9]+$ ]] && [ "$locale_choice" -ge 1 ] && [ "$locale_choice" -le "${#LOCALES[@]}" ]; then
            SELECTED_LOCALE="${LOCALES[$((locale_choice-1))]}"
            break
        else
            echo -e "${RED}Неверный ввод. Повторите попытку.${RESET}"
        fi
    done
    echo -e "Выбрана локаль: ${GREEN}$SELECTED_LOCALE${RESET}"
}

# Выбор временной зоны
function select_timezone() {
    mapfile -t REGIONS < <(timedatectl list-timezones | cut -d'/' -f1 | sort -u | grep -v -e '^$' -e '^Etc$')
    echo -e "\n${GREEN}--- Настройка временной зоны ---${RESET}"
    echo "Выберите ваш регион:"
    for i in "${!REGIONS[@]}"; do
        printf "%3d) %s\n" "$((i+1))" "${REGIONS[$i]}"
    done | column

    while true; do
        read -p "Введите номер региона: " region_choice
        if [[ "$region_choice" =~ ^[0-9]+$ ]] && [ "$region_choice" -ge 1 ] && [ "$region_choice" -le "${#REGIONS[@]}" ]; then
            break
        else
            echo -e "${RED}Неверный ввод.${RESET}"
        fi
    done
    REGION="${REGIONS[$((region_choice-1))]}"

    mapfile -t ZONES < <(timedatectl list-timezones | grep "^$REGION/")
    echo -e "\nВыберите город/зону:"
    for i in "${!ZONES[@]}"; do
        printf "%3d) %s\n" "$((i+1))" "${ZONES[$i]}"
    done | column

    while true; do
        read -p "Введите номер города/зоны: " zone_choice
        if [[ "$zone_choice" =~ ^[0-9]+$ ]] && [ "$zone_choice" -ge 1 ] && [ "$zone_choice" -le "${#ZONES[@]}" ]; then
            break
        else
            echo -e "${RED}Неверный ввод.${RESET}"
        fi
    done
    TIMEZONE="${ZONES[$((zone_choice-1))]}"
}

# === Приветствие
echo -e "${GREEN}### Arch Linux Installer v11 with BTRFS, ZSH and Terminus ###${RESET}"
read -p "Вы уверены, что хотите продолжить? (y/N): " confirm
[[ "$confirm" != "y" ]] && exit 1

# === Ввод данных
lsblk -d -o NAME,SIZE,MODEL
read -p "Введите имя диска (например, sda или nvme0n1): " DISK
DISK="/dev/${DISK}"

read -p "Таблица разделов (gpt/mbr) [gpt]: " PART_TABLE
PART_TABLE=${PART_TABLE:-gpt}

read -p "Имя хоста [archlinux]: " HOSTNAME
HOSTNAME=${HOSTNAME:-archlinux}

while true; do
    read -s -p "Пароль root: " ROOT_PASS; echo
    read -s -p "Подтвердите: " ROOT_PASS2; echo
    [[ "$ROOT_PASS" == "$ROOT_PASS2" ]] && break
    echo -e "${RED}Пароли не совпадают.${RESET}"
done

read -p "Имя пользователя [user]: " USERNAME
USERNAME=${USERNAME:-user}
while true; do
    read -s -p "Пароль $USERNAME: " USER_PASS; echo
    read -s -p "Подтвердите: " USER_PASS2; echo
    [[ "$USER_PASS" == "$USER_PASS2" ]] && break
    echo -e "${RED}Пароли не совпадают.${RESET}"
done

select_locale
select_timezone

# === Подготовка
umount -R /mnt 2>/dev/null || true
sgdisk --zap-all "$DISK"

UEFI=false
[ -d /sys/firmware/efi/efivars ] && UEFI=true

# === Разметка
if $UEFI && [[ "$PART_TABLE" == "gpt" ]]; then
    sgdisk -n 1:0:+550M -t 1:ef00 "$DISK"
    sgdisk -n 2:0:0 -t 2:8300 "$DISK"
    PART_EFI="${DISK}1"
    PART_ROOT="${DISK}2"
    mkfs.fat -F32 "$PART_EFI"
else
    parted -s "$DISK" mklabel msdos
    parted -s "$DISK" mkpart primary ext4 1MiB 100%
    parted -s "$DISK" set 1 boot on
    PART_ROOT="${DISK}1"
fi

# === Форматирование и монтирование
mkfs.btrfs -f -L ArchLinux "$PART_ROOT"
mount "$PART_ROOT" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
umount /mnt

OPTS="noatime,compress=zstd:2,ssd,discard=async,space_cache=v2"
mount -o subvol=@,$OPTS "$PART_ROOT" /mnt
mkdir -p /mnt/{boot,home,.snapshots,var/log}
mount -o subvol=@home,$OPTS "$PART_ROOT" /mnt/home
mount -o subvol=@snapshots,$OPTS "$PART_ROOT" /mnt/.snapshots
mount -o subvol=@var_log,$OPTS "$PART_ROOT" /mnt/var/log
[ -n "$PART_EFI" ] && mount "$PART_EFI" /mnt/boot

# === Установка системы
pacstrap -K /mnt base base-devel linux-zen linux-firmware terminus-font zsh sudo networkmanager git grub btrfs-progs

genfstab -U /mnt >> /mnt/etc/fstab

# === Настройка в chroot
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "$SELECTED_LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$SELECTED_LOCALE" > /etc/locale.conf
echo "FONT=ter-v16n" > /etc/vconsole.conf

echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1       localhost" >> /etc/hosts
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/zsh "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager

# ZSH + plugins
echo "Настройка ZSH..."
git clone https://github.com/ohmyzsh/ohmyzsh.git /home/$USERNAME/.oh-my-zsh
git clone https://github.com/zsh-users/zsh-autosuggestions /home/$USERNAME/.oh-my-zsh/custom/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting /home/$USERNAME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting

cp /home/$USERNAME/.oh-my-zsh/templates/zshrc.zsh-template /home/$USERNAME/.zshrc
sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="passion"/' /home/$USERNAME/.zshrc
sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' /home/$USERNAME/.zshrc
chown -R $USERNAME:$USERNAME /home/$USERNAME
EOF

umount -R /mnt
echo -e "\n${GREEN}✅ Установка завершена. Перезагрузите систему.${RESET}"