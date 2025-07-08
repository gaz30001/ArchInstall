#!/bin/bash set -e

GREEN="\e[32m" RED="\e[31m" RESET="\e[0m"

=== Выбор локали ===

function select_locale() { echo -e "\n${GREEN}--- Select locale ---${RESET}" LOCALES=("en_US.UTF-8" "ru_RU.UTF-8" "de_DE.UTF-8" "fr_FR.UTF-8") for i in "${!LOCALES[@]}"; do printf "%2d) %s\n" $((i+1)) "${LOCALES[$i]}" done | column while true; do read -p "Enter locale number: " locale_choice if [[ "$locale_choice" =~ ^[0-9]+$ ]] && [ "$locale_choice" -ge 1 ] && [ "$locale_choice" -le "${#LOCALES[@]}" ]; then SELECTED_LOCALE="${LOCALES[$((locale_choice-1))]}" break else echo -e "${RED}Invalid input.${RESET}" fi done echo -e "Selected locale: ${GREEN}$SELECTED_LOCALE${RESET}" }

=== Выбор временной зоны ===

function select_timezone() { mapfile -t REGIONS < <(timedatectl list-timezones | cut -d'/' -f1 | sort -u | grep -v -e '^$' -e '^Etc$') echo -e "\n${GREEN}--- Select region ---${RESET}" for i in "${!REGIONS[@]}"; do printf "%3d) %s\n" "$((i+1))" "${REGIONS[$i]}" done | column while true; do read -p "Enter region number: " region_choice if [[ "$region_choice" =~ ^[0-9]+$ ]] && [ "$region_choice" -ge 1 ] && [ "$region_choice" -le "${#REGIONS[@]}" ]; then break else echo -e "${RED}Invalid input.${RESET}" fi done REGION="${REGIONS[$((region_choice-1))]}" mapfile -t ZONES < <(timedatectl list-timezones | grep "^$REGION/") echo -e "\nSelect city/zone:" for i in "${!ZONES[@]}"; do printf "%3d) %s\n" "$((i+1))" "${ZONES[$i]}" done | column while true; do read -p "Enter zone number: " zone_choice if [[ "$zone_choice" =~ ^[0-9]+$ ]] && [ "$zone_choice" -ge 1 ] && [ "$zone_choice" -le "${#ZONES[@]}" ]; then break else echo -e "${RED}Invalid input.${RESET}" fi done TIMEZONE="${ZONES[$((zone_choice-1))]}" echo -e "Selected timezone: ${GREEN}$TIMEZONE${RESET}" }

=== Приветствие ===

echo -e "${GREEN}=== Arch Linux Installer v13 ===${RESET}" echo -e "${RED}WARNING: This will erase all data on the selected disk!${RESET}" read -p "Continue installation? (y/N): " confirm [[ "$confirm" != "y" ]] && exit 1

=== Диск ===

echo -e "\n${GREEN}--- Available disks ---${RESET}" mapfile -t DISKS < <(lsblk -dpno NAME,SIZE | grep -E "^/dev/(sd|hd|vd|nvme|mmcblk)") for i in "${!DISKS[@]}"; do printf "%2d) %s\n" $((i+1)) "${DISKS[$i]}" done while true; do read -p "Select disk number: " disk_choice if [[ "$disk_choice" =~ ^[0-9]+$ ]] && ((disk_choice >= 1 && disk_choice <= ${#DISKS[@]})); then DISK="${DISKS[$((disk_choice-1))]}" break else echo -e "${RED}Invalid disk.${RESET}" fi done

=== Таблица разделов ===

echo -e "\n${GREEN}--- Partition Table Type ---${RESET}" echo " 1) GPT (UEFI)" echo " 2) MBR (BIOS)" while true; do read -p "Choose type (1 or 2): " part_choice case "$part_choice" in 1) PART_TABLE="gpt"; break ;; 2) PART_TABLE="mbr"; break ;; *) echo -e "${RED}Enter 1 or 2.${RESET}" ;; esac

done

read -p "Hostname [archlinux]: " HOSTNAME HOSTNAME=${HOSTNAME:-archlinux}

while true; do read -s -p "Root password: " ROOT_PASS; echo read -s -p "Confirm: " ROOT_PASS2; echo [[ "$ROOT_PASS" == "$ROOT_PASS2" ]] && break echo -e "${RED}Passwords do not match.${RESET}" done

read -p "Username [user]: " USERNAME USERNAME=${USERNAME:-user} while true; do read -s -p "Password for $USERNAME: " USER_PASS; echo read -s -p "Confirm: " USER_PASS2; echo [[ "$USER_PASS" == "$USER_PASS2" ]] && break echo -e "${RED}Passwords do not match.${RESET}" done

select_locale select_timezone

UEFI=false [ -d /sys/firmware/efi/efivars ] && UEFI=true

umount -R /mnt 2>/dev/null || true sgdisk --zap-all "$DISK" || true if $UEFI && [[ "$PART_TABLE" == "gpt" ]]; then sgdisk -n 1:0:+550M -t 1:ef00 "$DISK" sgdisk -n 2:0:0 -t 2:8300 "$DISK" PART_EFI="${DISK}1" PART_ROOT="${DISK}2" mkfs.fat -F32 "$PART_EFI" else parted -s "$DISK" mklabel msdos parted -s "$DISK" mkpart primary ext4 1MiB 100% parted -s "$DISK" set 1 boot on PART_ROOT="${DISK}1" fi

mkfs.btrfs -f "$PART_ROOT" mount "$PART_ROOT" /mnt for sub in @ @home @snapshots @var_log; do btrfs subvolume create /mnt/$sub done umount /mnt

OPTS="noatime,compress=zstd:2,ssd,discard=async,space_cache=v2" mount -o subvol=@,$OPTS "$PART_ROOT" /mnt mkdir -p /mnt/{boot,home,.snapshots,var/log} mount -o subvol=@home,$OPTS "$PART_ROOT" /mnt/home mount -o subvol=@snapshots,$OPTS "$PART_ROOT" /mnt/.snapshots mount -o subvol=@var_log,$OPTS "$PART_ROOT" /mnt/var/log [ -n "$PART_EFI" ] && mount "$PART_EFI" /mnt/boot

pacstrap -K /mnt base base-devel linux-zen linux-firmware terminus-font btrfs-progs zsh sudo git grub networkmanager go

genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime hwclock --systohc echo "$SELECTED_LOCALE UTF-8" >> /etc/locale.gen locale-gen echo "LANG=$SELECTED_LOCALE" > /etc/locale.conf echo "FONT=ter-v16n" > /etc/vconsole.conf echo "$HOSTNAME" > /etc/hostname echo "127.0.0.1 localhost" > /etc/hosts echo "::1       localhost" >> /etc/hosts echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts echo "root:$ROOT_PASS" | chpasswd useradd -m -G wheel -s /bin/zsh "$USERNAME" echo "$USERNAME:$USER_PASS" | chpasswd sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers systemctl enable NetworkManager git clone https://github.com/ohmyzsh/ohmyzsh.git /home/$USERNAME/.oh-my-zsh git clone https://github.com/zsh-users/zsh-autosuggestions /home/$USERNAME/.oh-my-zsh/custom/plugins/zsh-autosuggestions git clone https://github.com/zsh-users/zsh-syntax-highlighting /home/$USERNAME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting cp /home/$USERNAME/.oh-my-zsh/templates/zshrc.zsh-template /home/$USERNAME/.zshrc sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="passion"/' /home/$USERNAME/.zshrc sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' /home/$USERNAME/.zshrc chown -R $USERNAME:$USERNAME /home/$USERNAME

yay

su - $USERNAME -c "cd /home/$USERNAME && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm && cd .. && rm -rf yay" EOF

umount -R /mnt echo -e "${GREEN}✅ Installation complete! Reboot now.${RESET}"

