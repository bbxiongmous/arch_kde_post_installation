#!/usr/bin/env bash
# Arch post-install: KDE + Fcitx5 + QEMU/libvirt + UFW/GUFW + Neovim/btop/Kvantum
# Catppuccin Mocha + Papirus icons + Chrome (AUR) + LazyVim
set -Eeuo pipefail
trap 'echo "❌ Error on line $LINENO while running: $BASH_COMMAND" >&2' ERR

# -----------------------------
# Preconditions
# -----------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (use sudo)." >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "${TARGET_HOME:-}" || ! -d "$TARGET_HOME" ]]; then
  echo "Could not determine home for $TARGET_USER" >&2
  exit 1
fi

as_user() { sudo -u "$TARGET_USER" -H bash -lc "$*"; }

ensure_line() {
  local line="$1" file="$2"
  sudo mkdir -p "$(dirname "$file")"
  sudo touch "$file"
  sudo grep -qxF "$line" "$file" || echo "$line" | sudo tee -a "$file" >/dev/null
}

IM_ENV=$(cat <<'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
GLFW_IM_MODULE=ibus
SDL_IM_MODULE=fcitx
EOF
)

log() { printf "\n==== %s ====\n" "$*"; }

# -----------------------------
# 1) System update & essentials
# -----------------------------
log "[1/11] System update & essentials"
pacman -Syu --noconfirm
pacman -S --needed --noconfirm base-devel git curl wget unzip tar

# -----------------------------
# 2) KDE Plasma + essential apps + SDDM
# -----------------------------
log "[2/11] KDE Plasma + essentials + SDDM"
pacman -S --needed --noconfirm \
  plasma sddm sddm-kcm \
  konsole dolphin okular gwenview kate \
  kdegraphics-thumbnailers ffmpegthumbs
systemctl enable sddm.service

# -----------------------------
# 3) Chinese input: fcitx5 + Rime
# -----------------------------
log "[3/11] Fcitx5 + Chinese addons"
pacman -S --needed --noconfirm \
  fcitx5 fcitx5-qt fcitx5-gtk fcitx5-configtool fcitx5-chinese-addons fcitx5-rime

for kv in $IM_ENV; do
  ensure_line "$kv" "/etc/environment"
done
ensure_line "export GTK_IM_MODULE=fcitx" "$TARGET_HOME/.xprofile"
ensure_line "export QT_IM_MODULE=fcitx"  "$TARGET_HOME/.xprofile"
ensure_line "export XMODIFIERS=@im=fcitx" "$TARGET_HOME/.xprofile"

sudo mkdir -p "$TARGET_HOME/.config/autostart"
cat <<'EOF' | sudo tee "$TARGET_HOME/.config/autostart/fcitx5.desktop" >/dev/null
[Desktop Entry]
Type=Application
Exec=fcitx5
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=fcitx5
Comment=Start fcitx5 input method
EOF
sudo chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config/autostart" "$TARGET_HOME/.xprofile"

# -----------------------------
# 4) Virtualization: QEMU/KVM + libvirt + virt-manager
#    Firewall: UFW + GUFW
#    (FIX: do NOT install iptables-nft to avoid conflicts)
# -----------------------------
log "[4/11] Virtualization stack & firewall"
pacman -S --needed --noconfirm \
  qemu-full libvirt virt-manager virt-viewer dnsmasq edk2-ovmf \
  bridge-utils openbsd-netcat ufw gufw

# libvirtd
systemctl enable --now libvirtd
usermod -aG libvirt "$TARGET_USER" || true
if ! virsh net-info default >/dev/null 2>&1; then
  virsh net-define /usr/share/libvirt/networks/default.xml || true
  virsh net-autostart default || true
  virsh net-start default || true
fi

# UFW
systemctl enable --now ufw
ufw default deny incoming || true
ufw default allow outgoing || true
yes | ufw enable || true

# -----------------------------
# 5) CLI tools: Neovim, btop, Kvantum (+ ensure Kvantum style)
# -----------------------------
log "[5/11] Neovim, btop, Kvantum"
pacman -S --needed --noconfirm neovim btop kvantum kvantum-qt5

sudo mkdir -p "$TARGET_HOME/.config/plasma-workspace/env"
cat <<'EOF' | sudo tee "$TARGET_HOME/.config/plasma-workspace/env/kvantum.sh" >/dev/null
#!/usr/bin/env bash
export QT_STYLE_OVERRIDE=kvantum
EOF
sudo chmod +x "$TARGET_HOME/.config/plasma-workspace/env/kvantum.sh"
sudo chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config/plasma-workspace"

# -----------------------------
# 6) AUR helper: yay
# -----------------------------
log "[6/11] AUR helper (yay)"
if ! command -v yay >/dev/null 2>&1; then
  as_user 'git clone https://aur.archlinux.org/yay.git "$HOME/.cache/yay-src" || true'
  as_user 'cd "$HOME/.cache/yay-src" && makepkg -si --noconfirm'
fi

# -----------------------------
# 7) Google Chrome (AUR)
# -----------------------------
log "[7/11] Google Chrome (AUR)"
as_user 'yay -S --noconfirm --needed google-chrome' || true

# -----------------------------
# 8) Theming: Catppuccin Mocha + Papirus icons
# -----------------------------
log "[8/11] Catppuccin (Kvantum + KDE colors) + Papirus icons"

# Kvantum themes (user-local)
as_user 'mkdir -p "$HOME/.config/Kvantum" "$HOME/.local/share/color-schemes"'
as_user 'git clone --depth=1 https://github.com/catppuccin/Kvantum.git "$HOME/.config/Kvantum/.catppuccin-tmp" || true'
as_user 'cp -r "$HOME/.config/Kvantum/.catppuccin-tmp/themes/"* "$HOME/.config/Kvantum"/ 2>/dev/null || true'
as_user 'rm -rf "$HOME/.config/Kvantum/.catppuccin-tmp" || true'

# Kvantum selection
sudo mkdir -p "$TARGET_HOME/.config/Kvantum"
cat <<'EOF' | sudo tee "$TARGET_HOME/.config/Kvantum/kvantum.kvconfig" >/dev/null
[General]
theme=Catppuccin-Mocha
# To force the Mauve-accent variant (if present), use:
# theme=Catppuccin-Mocha-Mauve
EOF
sudo chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config/Kvantum"

# KDE color scheme
as_user 'curl -fsSL https://raw.githubusercontent.com/catppuccin/kde/refs/heads/main/dist/CatppuccinMocha.colors -o "$HOME/.local/share/color-schemes/CatppuccinMocha.colors"' || true

# Icons & cursors
pacman -S --needed --noconfirm papirus-icon-theme
as_user 'yay -S --noconfirm --needed catppuccin-cursors-mocha' || true

# Apply on login (safe to re-run)
APPLY_SCRIPT="$TARGET_HOME/.config/plasma-catppuccin-apply.sh"
cat <<'EOS' | sudo tee "$APPLY_SCRIPT" >/dev/null
#!/usr/bin/env bash
set -e
# Apply KDE color scheme
if command -v plasma-apply-colorscheme >/dev/null 2>&1; then
  plasma-apply-colorscheme CatppuccinMocha || true
fi
# Icon + cursor theme
if command -v kwriteconfig5 >/dev/null 2>&1; then
  kwriteconfig5 --file kdeglobals --group Icons --key Theme "Papirus-Dark" || true
  kwriteconfig5 --file kcminputrc --group Mouse --key cursorTheme "Catppuccin-Mocha-Lavender-Cursors" || true
fi
# Refresh (Plasma 5)
if command -v kquitapp5 >/dev/null 2>&1; then
  kquitapp5 plasmashell 2>/dev/null || true
  (plasmashell &>/dev/null &) || true
fi
EOS
sudo chmod +x "$APPLY_SCRIPT"
ensure_line "$APPLY_SCRIPT &" "$TARGET_HOME/.config/plasma-workspace/env/catppuccin-apply.sh"
sudo chmod +x "$TARGET_HOME/.config/plasma-workspace/env/catppuccin-apply.sh" 2>/dev/null || true
sudo chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config/plasma-workspace" 2>/dev/null || true

# -----------------------------
# 9) LazyVim setup
# -----------------------------
log "[9/11] LazyVim starter (~/.config/nvim)"
as_user '
  NVIM_DIR="$HOME/.config/nvim"
  if [[ -d "$NVIM_DIR" && -n "$(ls -A "$NVIM_DIR" 2>/dev/null)" ]]; then
    echo "Skipping LazyVim: ~/.config/nvim is not empty."
  else
    rm -rf "$NVIM_DIR"
    git clone --depth=1 https://github.com/LazyVim/starter "$NVIM_DIR" || true
    rm -rf "$NVIM_DIR/.git" || true
  fi
'

# -----------------------------
# 10) Final messages
# -----------------------------
log "[10/11] Wrap-up"
echo "- libvirtd enabled; user '$TARGET_USER' added to 'libvirt' group."
echo "- UFW enabled (deny incoming / allow outgoing). See: sudo ufw status"
echo "- Kvantum + Catppuccin Mocha + Papirus-Dark will apply on login."

log "[11/11] Done 🎉  Reboot recommended."
