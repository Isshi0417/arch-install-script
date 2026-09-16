#!/usr/bin/env bash
set -eo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "This installation script must be run as root from the Arch live environment."
    exit 1
fi

read -rp "Enter target disk (e.g. /dev/nvme0n1 or /dev/sda): " TARGET_DISK
read -rp "Enter hostname: " SYSTEM_HOSTNAME
read -rp "Enter new username: " NEW_USER
read -rsp "Enter password for user and root: " USER_PASSWORD
echo

timedatectl set-ntp true

swapoff -a 2>/dev/null || true
umount -R /mnt 2>/dev/null || true

wipefs -af "$TARGET_DISK"
sgdisk -Z "$TARGET_DISK"
sgdisk -n 1:0:+4G -t 1:ef00 -c 1:"EFI" "$TARGET_DISK"
sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOT" "$TARGET_DISK"

udevadm settle
partprobe "$TARGET_DISK" 2>/dev/null || true
udevadm settle

if [[ "$TARGET_DISK" =~ [0-9]$ ]]; then
    EFI_PART="${TARGET_DISK}p1"
    ROOT_PART="${TARGET_DISK}p2"
else
    EFI_PART="${TARGET_DISK}1"
    ROOT_PART="${TARGET_DISK}2"
fi

mkfs.fat -F32 -n "EFI" "$EFI_PART"
mkfs.btrfs -f -L "ARCH" "$ROOT_PART"

mount "$ROOT_PART" /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_cache

umount /mnt

BTRFS_OPTS="noatime,compress=zstd:3,ssd,discard=async,space_cache=v2"

mount -o "${BTRFS_OPTS},subvol=@" "$ROOT_PART" /mnt

mkdir -p /mnt/{boot,home,.snapshots,var/log,var/cache}

mount -o "${BTRFS_OPTS},subvol=@home" "$ROOT_PART" /mnt/home
mount -o "${BTRFS_OPTS},subvol=@snapshots" "$ROOT_PART" /mnt/.snapshots
mount -o "${BTRFS_OPTS},subvol=@var_log" "$ROOT_PART" /mnt/var/log
mount -o "${BTRFS_OPTS},subvol=@var_cache" "$ROOT_PART" /mnt/var/cache
mount "$EFI_PART" /mnt/boot

pacstrap -K /mnt base base-devel git curl wget tar xz btrfs-progs pciutils linux-firmware networkmanager iwd efibootmgr pacman-contrib

genfstab -U /mnt >> /mnt/etc/fstab

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

cat <<EOF > /mnt/setup-chroot.sh
#!/usr/bin/env bash
set -eo pipefail

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "$SYSTEM_HOSTNAME" > /etc/hostname
cat <<HOSTS_EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $SYSTEM_HOSTNAME.localdomain $SYSTEM_HOSTNAME
HOSTS_EOF

echo "root:$USER_PASSWORD" | chpasswd
useradd -m -G wheel,video,audio,input -s /bin/bash "$NEW_USER"
echo "$NEW_USER:$USER_PASSWORD" | chpasswd
chown -R "$NEW_USER":"$NEW_USER" /home/"$NEW_USER"

echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-installer-wheel

echo 'MAKEFLAGS="-j\$(nproc)"' >> /etc/makepkg.conf
echo 'COMPRESSZST=(zstd -c -z -q -T0 -)' >> /etc/makepkg.conf

sed -i 's/^#ParallelDownloads = [0-9]*/ParallelDownloads = 5/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf

CACHY_TMP=\$(mktemp -d)
curl -sSL https://mirror.cachyos.org/cachyos-repo.tar.xz -o "\$CACHY_TMP/cachyos-repo.tar.xz"
tar -xf "\$CACHY_TMP/cachyos-repo.tar.xz" -C "\$CACHY_TMP"
(cd "\$CACHY_TMP/cachyos-repo" && yes '' | ./cachyos-repo.sh)
rm -rf "\$CACHY_TMP"

pacman -Syyu --noconfirm
pacman -Qqn | pacman -S --needed --noconfirm -

pacman -S --needed --noconfirm \\
    linux-cachyos \\
    linux-cachyos-headers \\
    ananicy-cpp \\
    cachyos-ananicy-rules \\
    cachyos-settings \\
    power-profiles-daemon \\
    zram-generator

systemctl enable ananicy-cpp
systemctl enable power-profiles-daemon
systemctl enable systemd-oomd
systemctl enable fstrim.timer
systemctl enable paccache.timer

cat <<EOF > /etc/sysctl.d/99-performance.conf
vm.max_map_count = 2147483642
fs.file-max = 2097152
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

cat <<ZRAM_EOF > /etc/systemd/zram-generator.conf
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
ZRAM_EOF

pacman -S --needed --noconfirm \\
    snapper \\
    snap-pac \\
    limine \\
    limine-snapper-sync \\
    btrfs-overlayfs

umount /.snapshots 2>/dev/null || true
rm -rf /.snapshots
snapper -c root create-config /
btrfs subvolume delete /.snapshots
mkdir -p /.snapshots
mount -a
chmod 750 /.snapshots
sed -i 's/ALLOW_GROUPS=""/ALLOW_GROUPS="wheel"/' /etc/snapper/configs/root

sed -i 's/\\(filesystems\\)/btrfs btrfs-overlayfs \\1/' /etc/mkinitcpio.conf
mkinitcpio -P

systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer
systemctl enable limine-snapper-sync.service

UCODE_LINE=""
if grep -qi "AuthenticAMD" /proc/cpuinfo; then
    pacman -S --needed --noconfirm amd-ucode
    UCODE_LINE="    module_path: boot():/amd-ucode.img"
elif grep -qi "GenuineIntel" /proc/cpuinfo; then
    pacman -S --needed --noconfirm intel-ucode
    UCODE_LINE="    module_path: boot():/intel-ucode.img"
fi

EXTRA_CMDLINE=""
if lspci | grep -Ei "VGA|3D" | grep -qi "NVIDIA"; then
    pacman -S --needed --noconfirm nvidia-dkms nvidia-utils lib32-nvidia-utils egl-wayland
    EXTRA_CMDLINE="nvidia_drm.modeset=1 nvidia_drm.fbdev=1"
elif lspci | grep -Ei "VGA|3D" | grep -qi "AMD|Radeon|Advanced Micro Devices"; then
    pacman -S --needed --noconfirm mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon xf86-video-amdgpu
elif lspci | grep -Ei "VGA|3D" | grep -qi "Intel"; then
    pacman -S --needed --noconfirm mesa lib32-mesa vulkan-intel lib32-vulkan-intel
fi

mkdir -p /boot/EFI/BOOT
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
efibootmgr --create --disk "$TARGET_DISK" --part 1 --label "Limine" --loader '\\\\EFI\\\\BOOT\\\\BOOTX64.EFI' --unicode 2>/dev/null || true

cat <<LIMINE_EOF > /boot/limine.conf
timeout: 5

/Arch Linux (linux-cachyos)
    protocol: linux
    kernel_path: boot():/vmlinuz-linux-cachyos
    module_path: boot():/initramfs-linux-cachyos.img
    kernel_cmdline: root=UUID=$ROOT_UUID rootflags=subvol=@ rw quiet splash $EXTRA_CMDLINE

//Snapshots
LIMINE_EOF

if [ -n "\$UCODE_LINE" ]; then
    sed -i "/kernel_path:/a \$UCODE_LINE" /boot/limine.conf
fi

pacman -S --needed --noconfirm \\
    pipewire \\
    wireplumber \\
    pipewire-pulse \\
    pipewire-alsa \\
    pipewire-jack \\
    lib32-pipewire-jack \\
    bluez \\
    bluez-utils

systemctl enable NetworkManager
systemctl enable bluetooth

pacman -S --needed --noconfirm \\
    steam \\
    gamescope \\
    mangohud \\
    lib32-mangohud \\
    wine-staging \\
    winetricks \\
    lutris

pacman -S --needed --noconfirm \\
    firefox \\
    thunar \\
    tumbler \\
    gvfs \\
    pavucontrol \\
    pamixer \\
    playerctl \\
    brightnessctl \\
    network-manager-applet \\
    blueman \\
    papirus-icon-theme \\
    adwaita-icon-theme \\
    xdg-user-dirs \\
    foot \\
    neovim \\
    ripgrep \\
    fd \\
    fzf \\
    bat \\
    jq \\
    btop \\
    docker \\
    docker-compose

sudo -i -u "$NEW_USER" xdg-user-dirs-update
usermod -aG docker "$NEW_USER"
systemctl enable docker

pacman -S --needed --noconfirm \\
    xdg-desktop-portal \\
    xdg-desktop-portal-wlr \\
    polkit-gnome \\
    wl-clipboard \\
    grim \\
    slurp \\
    fuzzel \\
    swaybg \\
    swayidle \\
    swaylock \\
    ttf-jetbrains-mono-nerd \\
    ttf-font-awesome \\
    noto-fonts \\
    noto-fonts-cjk \\
    noto-fonts-emoji

pacman -S --needed --noconfirm paru

sudo -i -u "$NEW_USER" paru -S --needed --noconfirm somewm

ln -sf /usr/bin/foot /usr/local/bin/xterm

sudo -i -u "$NEW_USER" mkdir -p /home/"$NEW_USER"/.config/somewm

if [ -f /etc/xdg/somewm/rc.lua ]; then
    cp /etc/xdg/somewm/rc.lua /home/"$NEW_USER"/.config/somewm/rc.lua
elif [ -f /etc/xdg/awesome/rc.lua ]; then
    cp /etc/xdg/awesome/rc.lua /home/"$NEW_USER"/.config/somewm/rc.lua
fi

if [ -f /home/"$NEW_USER"/.config/somewm/rc.lua ]; then
    sed -i 's/terminal = "xterm"/terminal = "foot"/' /home/"$NEW_USER"/.config/somewm/rc.lua
    echo 'awful.spawn.with_shell(gears.filesystem.get_configuration_dir() .. "autostart.sh")' >> /home/"$NEW_USER"/.config/somewm/rc.lua
fi

cat <<AUTO_EOF > /home/"$NEW_USER"/.config/somewm/autostart.sh
#!/usr/bin/env bash
/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 &
nm-applet &
blueman-applet &
AUTO_EOF
chmod +x /home/"$NEW_USER"/.config/somewm/autostart.sh
chown -R "$NEW_USER":"$NEW_USER" /home/"$NEW_USER"

cat <<ENV_EOF >> /etc/environment
TERMINAL="foot"
BROWSER="firefox"
QT_QPA_PLATFORM="wayland;xcb"
GDK_BACKEND="wayland,x11,*"
SDL_VIDEODRIVER="wayland"
CLUTTER_BACKEND="wayland"
ELECTRON_OZONE_PLATFORM_HINT="auto"
XDG_CURRENT_DESKTOP="somewm:wlroots"
XDG_SESSION_TYPE="wayland"
ENV_EOF

rm -f /etc/sudoers.d/99-installer-wheel
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/99-wheel

EOF

chmod +x /mnt/setup-chroot.sh
arch-chroot /mnt /bin/bash /setup-chroot.sh
rm -f /mnt/setup-chroot.sh

umount -R /mnt

echo "Installation complete. You may now reboot your system."
