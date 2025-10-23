#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config & helpers
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

# -----------------------------
# System update & essentials
# -----------------------------
echo "[1/11] Full system update..."
pacman -Syu --noconfirm

echo "[2/11] Base dev tools..."
pacman -S --needed --noconfirm base-devel git curl wget unzip tar

# -----------------------------
# KDE Plasma + essential apps + SDDM
# -----------------------------
echo "[3/11] Installing KDE Plasma + essentials..."
pacman -S --needed --noconfirm \
  plasma sddm sddm-kcm \
  konsole dolphin okular gwenview kate \
  kdegraphics-thumbnailers ffmpegthumbs

echo "Enabling SDDM..."
systemctl enable sddm.service

# -----------------------------
# Chinese input: fcitx5 + Rime
# -----------------------------
echo "[4/11] Installing fcitx5 + Chinese addons..."
pacman -S --needed --noconfirm \
  fcitx5 fcitx5-qt fcitx5-gtk fcitx5-configtool fcitx5-chinese-addons fcitx5-rime

echo "Setting IM env vars system-wide and for user login..."
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
# Virtualization: QEMU/KVM + libvirt + virt-manager
# Firewall: UFW + GUFW
# -----------------------------
echo "[5/11] Installing virtualization stack & firewall..."
pacman -S --needed --noconfirm \
  qemu-full libvirt virt-manager virt-viewer dnsmasq edk2-ovmf \
  bridge-utils openbsd-netcat iptables-nft \
  ufw gufw

echo "Enabling libvirtd and default NAT network..."
systemctl enable --now libvirtd
usermod -aG libvirt "$TARGET_USER" || true
if ! virsh net-info default >/dev/null 2>&1; then
  virsh net-define /usr/share/libvirt/networks/default.xml || true
  virsh net-autostart default || true
  virsh net-start default || true
fi

echo "Enabling and configuring UFW (deny in / allow out)..."
systemctl enable --now ufw
ufw default deny incoming || true
ufw default allow outgoing || true
yes | ufw enable || true

# -----------------------------
# CLI tools: Neovim, btop, Kvantum
# -----------------------------
echo "[6/11] Installing Neovim, btop, Kvantum..."
pacman -S --needed --noconfirm neovim btop kvantum kvantum-qt5 kvantum-qt6 kvantum-manager

# Ensure Kvantum is respected (Qt style)
sudo mkdir -p "$TARGET_HOME/.config/plasma-workspace/env"
cat <<'EOF' | sudo tee "$TARGET_HOME/.config/plasma-workspace/env/kvantum.sh" >/dev/null
#!/usr/bin/env bash
export QT_STYLE_OVERRIDE=kvantum
EOF
sudo chmod +x "$TARGET_HOME/.config/plasma-workspace/env/kvantum.sh"
sudo chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config/plasma-workspace"

# -----------------------------
# AUR helper: yay
# -----------------------------
if ! command -v yay >/dev/null 2>&1; then
  echo "[7/11] Installing yay (AUR helper)..."
  as_user 'git clone https://aur.archlinux.org/yay.git "$HOME/.cache/yay-src" || true'
  as_user 'cd "$HOME/.cache/yay-src" && makepkg -si --noconfirm'
fi

# -----------------------------
# Google Chrome (AUR)
# -----------------------------
echo "[8/11] Installing Google Chrome (AUR)..."
as_user 'yay -S --noconfirm --needed google-chrome'

# -----------------------------
# Theming: Catppuccin Mocha (Mauve) + Papirus icons
# -----------------------------
echo "[9/11] Installing Catppuccin (Kvantum + KDE colors) and Papirus icons..."

# Kvantum themes (user-local)
as_user 'mkdir -p "$HOME/.config/Kvantum" "$HOME/.local/share/color-schemes"'
as_user 'git clone --depth=1 https://github.com/catppuccin/Kvantum.git "$HOME/.config/Kvantum/.catppuccin-tmp" || true'
as_user 'cp -r "$HOME/.config/Kvantum/.catppuccin-tmp/themes/"* "$HOME/.config/Kvantum"/'
as_user 'rm -rf "$HOME/.config/Kvantum/.catppuccin-tmp"'

# Select Kvantum theme (Mocha; change to Catppuccin-Mocha-Mauve if you prefer that exact variant)
KV_CFG_DIR="$TARGET_HOME/.config/Kvantum"
sudo mkdir -p "$KV_CFG_DIR"
cat <<'EOF' | sudo tee "$KV_CFG_DIR/kvantum.kvconfig" >/dev/null
[General]
theme=Catppuccin-Mocha
# Or, if available on your clone:
# theme=Catppuccin-Mocha-Mauve
EOF
sudo chown -R "$TARGET_USER":"$TARGET_USER" "$KV_CFG_DIR"

# KDE Color scheme (Catppuccin Mocha)
as_user 'curl -fsSL https://raw.githubusercontent.com/catppuccin/kde/refs/heads/main/dist/CatppuccinMocha.colors -o "$HOME/.local/share/color-schemes/CatppuccinMocha.colors"'

# Cursors (Catppuccin Mocha) via AUR
as_user 'yay -S --noconfirm --needed catppuccin-cursors-mocha' || true

# Icons: Papirus (Dark)
pacman -S --needed --noconfirm papirus-icon-theme

# Apply icons/colors/cursor on login (safe to re-run)
APPLY_SCRIPT="$TARGET_HOME/.config/plasma-catppuccin-apply.sh"
cat <<'EOS' | sudo tee "$APPLY_SCRIPT" >/dev/null
#!/usr/bin/env bash
set -e

# Apply KDE color scheme
if command -v plasma-apply-colorscheme >/dev/null 2>&1; then
  plasma-apply-colorscheme CatppuccinMocha || true
fi

# Apply icon theme (Papirus-Dark) + cursor theme
if command -v kwriteconfig5 >/dev/null 2>&1; then
  kwriteconfig5 --file kdeglobals --group Icons --key Theme "Papirus-Dark" || true
  kwriteconfig5 --file kcminputrc --group Mouse --key cursorTheme "Catppuccin-Mocha-Lavender-Cursors" || true
fi

# Refresh Plasma shell if available (Plasma 5)
if command -v kquitapp5 >/dev/null 2>&1; then
  kquitapp5 plasmashell 2>/dev/null || true
  (plasmashell &>/dev/null &) || true
fi
EOS
sudo chmod +x "$APPLY_SCRIPT"
sudo chown "$TARGET_USER":"$TARGET_USER" "$APPLY_SCRIPT"

# Autostart the apply script each login
ensure_line "$APPLY_SCRIPT &" "$TARGET_HOME/.config/plasma-workspace/env/catppuccin-apply.sh"
sudo chmod +x "$TARGET_HOME/.config/plasma-workspace/env/catppuccin-apply.sh" 2>/dev/null || true
sudo chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config/plasma-workspace" 2>/dev/null || true

# -----------------------------
# LazyVim setup
# -----------------------------
echo "[10/11] Setting up LazyVim starter (~/.config/nvim)..."
as_user '
  NVIM_DIR="$HOME/.config/nvim"
  if [[ -d "$NVIM_DIR" && -n "$(ls -A "$NVIM_DIR" 2>/dev/null)" ]]; then
    echo "Skipping LazyVim: ~/.config/nvim is not empty."
  else
    rm -rf "$NVIM_DIR"
    git clone --depth=1 https://github.com/LazyVim/starter "$NVIM_DIR"
    rm -rf "$NVIM_DIR/.git"
  fi
'

# -----------------------------
# Wrap up
# -----------------------------
echo "[11/11] Done 🎉"
echo "- Reboot recommended to start SDDM and load env vars."
echo "- Log into Plasma; Kvantum + Catppuccin Mocha and Papirus-Dark icons will apply."
echo "- Virt-manager ready; user added to libvirt group."
echo "- Firewall (UFW) enabled: 'sudo ufw status' to inspect."
