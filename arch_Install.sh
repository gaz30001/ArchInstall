#!/bin/bash
set -e

# === Functions ===
prompt() { read -rp "$1: " "$2"; }

select_option() {
  echo -e "\n$1"
  local i=1
  local options=("${@:2}")
  for opt in "${options[@]}"; do
    printf "%2d) %s\n" "$i" "$opt"
    ((i++))
  done
  local choice
  while true; do
    read -rp "? " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#options[@]})); then
      echo "${options[$((choice - 1))]}"
      return
    fi
    echo "Invalid option. Enter a number between 1 and ${#options[@]}"
  done
}

echo "=== Arch Linux Btrfs Zsh Installer v8 ==="

# === User input ===
prompt "Hostname" hostname
prompt "Username" username

# === Disk detection (more reliable) ===
disks=()
while IFS= read -r line; do
  disks+=("$line")
done < <(lsblk -dpno NAME | grep -E "^/dev/(sd|hd|vd|nvme|mmcblk)" || true)

if [[ ${#disks[@]} -eq 0 ]]; then
  echo "❌ No disks found. Aborting."
  exit 1
fi

disk=$(select_option "Select target disk (ALL DATA WILL BE ERASED!)" "${disks[@]}")

# === Timezone selection ===
mapfile -t regions < <(find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 -type d | xargs -n1 basename)
region=$(select_option "Select timezone region" "${regions[@]}")

cities=()
while IFS= read -r -d '' city; do
  cities+=("$(basename "$city")")
done < <(find "/usr/share/zoneinfo/$region" -mindepth 1 -maxdepth 1 -type f -print0)

city=$(select_option "Select city in $region" "${cities[@]}")
timezone="$region/$city"

# === Locale selection ===
locales=(en_US.UTF-8 ru_RU.UTF-8 de_DE.UTF-8)
locale=$(select_option "Select system locale" "${locales[@]}")

# === Detect boot mode ===
if [ -d /sys/firmware/efi ]; then
  bootmode="UEFI"
  scheme="gpt"
else
  bootmode="BIOS"
  scheme="mbr"
fi
echo "Detected boot mode: $bootmode ($scheme)"

# === Partition disk ===
wipefs -af "$disk"
sgdisk --zap-all "$disk" 2>/dev/null || true

if [[ $scheme == "gpt" ]]; then
  parted "$disk" --script mklabel gpt \
    mkpart ESP fat32 1MiB 512MiB \
    set 1 esp on \
    mkpart primary ext4 512MiB 100%
  boot="${disk}1"
  root="${disk}2"
else
  parted "$disk" --script mklabel msdos \
    mkpart primary fat32 1MiB 512MiB \
    set 1 boot on \
    mkpart primary ext4 512MiB 100%
  boot="${disk}1"
  root="${disk}2"
fi

# === Format and mount ===
mkfs.fat -F32 "$boot"
mkfs.btrfs -f "$root"

mount "$root" /mnt
btrfs su cr /mnt/@
btrfs su cr /mnt/@home
btrfs su cr /mnt/@snapshots
btrfs su cr /mnt/@var_log
umount /mnt

mount -o noatime,compress=zstd:2,ssd,discard=async,space_cache=v2,subvol=@ "$root" /mnt
mkdir -p /mnt/{boot,home,.snapshots,var/log}
mount -o noatime,compress=zstd:2,ssd,discard=async,space_cache=v2,subvol=@home "$root" /mnt/home
mount -o noatime,compress=zstd:2,ssd,discard=async,space_cache=v2,subvol=@snapshots "$root" /mnt/.snapshots
mount -o noatime,compress=zstd:2,ssd,discard=async,space_cache=v2,subvol=@var_log "$root" /mnt/var/log
mount "$boot" /mnt/boot

# === Base installation ===
pacstrap /mnt base linux linux-firmware btrfs-progs sudo nano grub snapper snap-pac zsh git

genfstab -U /mnt >> /mnt/etc/fstab

# === Configure system ===
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
hwclock --systohc

echo "$locale UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$locale" > /etc/locale.conf

echo "$hostname" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1       localhost" >> /etc/hosts
echo "127.0.1.1 $hostname.localdomain $hostname" >> /etc/hosts

echo "Set password for root:"
passwd

useradd -m -G wheel -s /bin/zsh $username
echo "Set password for user $username:"
passwd $username
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

snapper --config root create-config /
sed -i 's/^ALLOW_GROUPS=""/ALLOW_GROUPS="wheel"/' /etc/snapper/configs/root
mkdir -p /.snapshots
chmod 750 /.snapshots
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer

if [ "$bootmode" == "UEFI" ]; then
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
else
  grub-install --target=i386-pc "$disk"
fi
grub-mkconfig -o /boot/grub/grub.cfg

git clone https://github.com/zsh-users/zsh-autosuggestions /usr/share/zsh/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting /usr/share/zsh/plugins/zsh-syntax-highlighting

cat <<ZRC > /etc/zshrc
export ZSH_THEME="passion"
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
ZRC

cp /etc/zshrc /home/$username/.zshrc
cp /etc/zshrc /root/.zshrc
chown $username:$username /home/$username/.zshrc
chsh -s /bin/zsh root
chsh -s /bin/zsh $username
EOF

echo -e "\n✅ Installation complete! Reboot and enjoy your new Arch Linux with Btrfs, Snapper, and Zsh 🚀"
