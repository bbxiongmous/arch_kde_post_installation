#!/usr/bin/env bash
# Arch post-install: KDE + fcitx5 + QEMU/libvirt + UFW/GUFW + Neovim/btop
# CLI: curl fzf ripgrep bat eza zoxide btop + Bash setup + Cascadia Nerd + Noto fonts (CJK & Emoji)
# Desktop plumbing: PipeWire, NetworkManager, XDG portals, codecs, guest tools, filesystems, utilities
# Services: timesyncd, printing, bluetooth, power-profiles-daemon
# AUR: yay (passwordless pacman), Google Chrome
# Snapper + grub-btrfs (install only; no snapper scheduling)
set -Eeuo pipefail
trap 'echo "❌ Error on line $LINENO while running: $BASH_COMMAND" >&2' ERR

### ---------- Helpers ----------
[[ $EUID -eq 0 ]] || { echo "Please run as root (sudo)." >&2; exit 1; }
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d "$TARGET_HOME" ]] || { echo "Could not determine home for $TARGET_USER" >&2; exit 1; }

have(){ command -v "$1" >/dev/null 2>&1; }
as_user(){ sudo -u "$TARGET_USER" -H bash -lc "$*"; }
log(){ printf "\n==== %s ====\n" "$*"; }
ensure_line(){ local s="$1" f="$2"; mkdir -p "$(dirname "$f")"; touch "$f"; grep -qxF "$s" "$f" || echo "$s" >>"$f"; }

IM_ENV=$(cat <<'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
GLFW_IM_MODULE=ibus
SDL_IM_MODULE=fcitx
EOF
)

### ---------- 1) System update ----------
log "[1/16] System update & base tools"
pacman -Syu --noconfirm
pacman -S --needed --noconfirm base-devel git curl wget unzip tar btrfs-progs

### ---------- 2) KDE + SDDM ----------
log "[2/16] KDE Plasma + essentials + SDDM"
pacman -S --needed --noconfirm \
  plasma sddm sddm-kcm \
  konsole dolphin okular gwenview kate \
  kdegraphics-thumbnailers ffmpegthumbs ark spectacle kcalc partitionmanager
systemctl enable sddm.service

### ---------- 3) Core desktop plumbing ----------
log "[3/16] Audio (PipeWire), NetworkManager, XDG portals"
pacman -S --needed --noconfirm \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber rtkit \
  networkmanager \
  xdg-desktop-portal xdg-desktop-portal-kde
systemctl enable --now NetworkManager
# PipeWire/WirePlumber start per-user automatically

### ---------- 4) Input (fcitx5 + Rime) ----------
log "[4/16] Fcitx5 + Chinese input"
pacman -S --needed --noconfirm \
  fcitx5 fcitx5-qt fcitx5-gtk fcitx5-configtool fcitx5-chinese-addons fcitx5-rime
for kv in $IM_ENV; do ensure_line "$kv" "/etc/environment"; done
ensure_line "export GTK_IM_MODULE=fcitx" "$TARGET_HOME/.xprofile"
ensure_line "export QT_IM_MODULE=fcitx"  "$TARGET_HOME/.xprofile"
ensure_line "export XMODIFIERS=@im=fcitx" "$TARGET_HOME/.xprofile"
mkdir -p "$TARGET_HOME/.config/autostart"
cat > "$TARGET_HOME/.config/autostart/fcitx5.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Exec=fcitx5
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=fcitx5
Comment=Start fcitx5 input method
EOF
chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config/autostart" "$TARGET_HOME/.xprofile"

### ---------- 5) Virtualization + Firewall + Guest tools ----------
log "[5/16] Virtualization (QEMU/KVM + libvirt) + UFW + guest agent"
pacman -S --needed --noconfirm \
  qemu-full libvirt virt-manager virt-viewer dnsmasq edk2-ovmf \
  bridge-utils openbsd-netcat ufw gufw \
  qemu-guest-agent spice-vdagent
systemctl enable --now libvirtd
systemctl enable --now qemu-guest-agent
usermod -aG libvirt "$TARGET_USER" || true
if ! virsh net-info default >/dev/null 2>&1; then
  virsh net-define /usr/share/libvirt/networks/default.xml || true
  virsh net-autostart default || true
  virsh net-start default || true
fi
systemctl enable --now ufw
ufw default deny incoming || true
ufw default allow outgoing || true
yes | ufw enable || true

### ---------- 6) Multimedia codecs & filesystems ----------
log "[6/16] Codecs (FFmpeg/GStreamer) + exFAT/NTFS"
pacman -S --needed --noconfirm ffmpeg gst-libav gst-plugins-good gst-plugins-bad gst-plugins-ugly
pacman -S --needed --noconfirm exfatprogs ntfs-3g

### ---------- 7) CLI tools ----------
log "[7/16] CLI tools: curl fzf ripgrep bat eza zoxide btop + neovim"
pacman -S --needed --noconfirm neovim btop \
  curl fzf ripgrep bat eza zoxide
mkdir -p /usr/local/bin
if have bat && ! have batcat; then ln -sf /usr/bin/bat /usr/local/bin/batcat; fi
mkdir -p "$TARGET_HOME/.config" "$TARGET_HOME/.local/share"
chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config" "$TARGET_HOME/.local"

### ---------- 8) Bash setup ----------
log "[8/16] Bash aliases and zoxide init"
BASH_BLOCK=$(cat <<'EOF'
# >>> MY-POSTINSTALL BASH SETUP >>>
alias ls='eza -lh --group-directories-first --icons'
alias lt='eza --tree --level=2 --long --icons --git'
alias ff="fzf --preview 'batcat --style=numbers --color=always {}'"
alias bat='batcat'
eval "$(zoxide init bash)"
# <<< MY-POSTINSTALL BASH SETUP <<<
EOF
)
as_user '
  touch "$HOME/.bashrc"
  if ! grep -q "^# >>> MY-POSTINSTALL BASH SETUP >>>" "$HOME/.bashrc"; then
    printf "%s\n" "'"$BASH_BLOCK"'" >> "$HOME/.bashrc"
  fi
'

### ---------- 9) Fonts ----------
log "[9/16] Fonts: Noto (core/CJK/Emoji) + Cascadia Code Nerd"
pacman -S --needed --noconfirm noto-fonts noto-fonts-cjk noto-fonts-emoji
as_user 'yay -S --noconfirm --needed --sudoloop ttf-cascadia-code-nerd || yay -S --noconfirm --needed --sudoloop nerd-fonts-cascadia-code' || true
fc-cache -fv >/dev/null || true

### ---------- 10) AUR helper yay ----------
log "[10/16] yay (AUR helper) + no-password pacman"
SUDOERS_FILE="/etc/sudoers.d/90-pacman-nopasswd-$TARGET_USER"
if [[ ! -f "$SUDOERS_FILE" ]]; then
  echo "$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/pacman" > "$SUDOERS_FILE"
  chmod 440 "$SUDOERS_FILE"
fi
if ! have yay; then
  as_user 'git clone https://aur.archlinux.org/yay.git "$HOME/.cache/yay-src" || true'
  as_user 'cd "$HOME/.cache/yay-src" && makepkg -si --noconfirm'
fi

### ---------- 11) Google Chrome (AUR) ----------
log "[11/16] Google Chrome (AUR)"
as_user 'yay -S --noconfirm --needed --sudoloop google-chrome' || true

### ---------- 12) Printing ----------
log "[12/16] Printing (CUPS)"
pacman -S --needed --noconfirm cups cups-pdf system-config-printer
systemctl enable --now org.cups.cupsd
# For many HP printers: uncomment if needed
# pacman -S --needed --noconfirm hplip

### ---------- 13) Bluetooth ----------
log "[13/16] Bluetooth (bluez + Bluedevil)"
pacman -S --needed --noconfirm bluez bluez-utils bluedevil
systemctl enable --now bluetooth

### ---------- 14) Power management ----------
log "[14/16] Power profiles (laptops/desktops)"
pacman -S --needed --noconfirm power-profiles-daemon
systemctl enable --now power-profiles-daemon

### ---------- 15) Time sync & Flatpak ----------
log "[15/16] Time sync + Flatpak/Flathub"
systemctl enable --now systemd-timesyncd
pacman -S --needed --noconfirm flatpak
as_user 'flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo' || true

### ---------- 16) Snapper + grub-btrfs (install only) ----------
log "[16/16] Snapper + grub-btrfs (install only)"
pacman -S --needed --noconfirm snapper grub-btrfs || true
if systemctl list-unit-files | grep -q '^grub-btrfs\.path'; then
  systemctl enable --now grub-btrfs.path
  if have grub-mkconfig; then grub-mkconfig -o /boot/grub/grub.cfg || true; fi
else
  echo "ℹ grub-btrfs.path unit not found (non-GRUB systems or unit not provided)."
fi

echo -e "\n✅ All done. Reboot recommended to start SDDM & apply services."
