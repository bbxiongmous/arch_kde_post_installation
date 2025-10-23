#!/usr/bin/env bash
# Arch post-install: KDE + fcitx5 + QEMU/libvirt + UFW/GUFW + nvim/btop/Kvantum
# Catppuccin Mocha + Papirus icons + Chrome (AUR) + LazyVim
# Extras: curl fzf ripgrep bat eza zoxide btop + Bash setup + Cascadia Nerd + Emoji
# Snapper + grub-btrfs: install only; enable grub-btrfs if available (no snapper scheduling)

set -Eeuo pipefail
trap 'echo "❌ Error on line $LINENO while running: $BASH_COMMAND" >&2' ERR

### ---------- Helpers / Preconditions ----------
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

kwcfg(){
  if have kwriteconfig6; then kwriteconfig6 "$@";
  elif have kwriteconfig5; then kwriteconfig5 "$@";
  else return 0; fi
}

### ---------- 1) System update & essentials ----------
log "[1/14] System update & essentials"
pacman -Syu --noconfirm
pacman -S --needed --noconfirm base-devel git curl wget unzip tar btrfs-progs

### ---------- 2) KDE + essentials + SDDM ----------
log "[2/14] KDE Plasma + essentials + SDDM"
pacman -S --needed --noconfirm \
  plasma sddm sddm-kcm \
  konsole dolphin okular gwenview kate \
  kdegraphics-thumbnailers ffmpegthumbs
systemctl enable sddm.service

### ---------- 3) Chinese input (fcitx5 + Rime) ----------
log "[3/14] Fcitx5 + Chinese addons"
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

### ---------- 4) Virtualization + Firewall ----------
log "[4/14] Virtualization (QEMU/KVM + libvirt) + UFW/GUFW"
pacman -S --needed --noconfirm \
  qemu-full libvirt virt-manager virt-viewer dnsmasq edk2-ovmf \
  bridge-utils openbsd-netcat ufw gufw

systemctl enable --now libvirtd
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

### ---------- 5) CLI tools ----------
log "[5/14] Neovim, btop, and CLI toolkit (curl fzf ripgrep bat eza zoxide btop)"
pacman -S --needed --noconfirm neovim btop \
  curl fzf ripgrep bat eza zoxide
# Provide 'batcat' for your alias (Arch binary is 'bat')
mkdir -p /usr/local/bin
if have bat && ! have batcat; then ln -sf /usr/bin/bat /usr/local/bin/batcat; fi

# Ensure user-owned config dirs
mkdir -p "$TARGET_HOME/.config" "$TARGET_HOME/.local/share"
chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config" "$TARGET_HOME/.local"

### ---------- 6) Your Bash setup ----------
log "[6/14] Bash aliases and zoxide init"
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

### ---------- 7) AUR helper yay (no password prompts) ----------
log "[7/14] AUR helper (yay) + pacman NOPASSWD"
SUDOERS_FILE="/etc/sudoers.d/90-pacman-nopasswd-$TARGET_USER"
if [[ ! -f "$SUDOERS_FILE" ]]; then
  echo "$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/pacman" > "$SUDOERS_FILE"
  chmod 440 "$SUDOERS_FILE"
fi
if ! have yay; then
  as_user 'git clone https://aur.archlinux.org/yay.git "$HOME/.cache/yay-src" || true'
  as_user 'cd "$HOME/.cache/yay-src" && makepkg -si --noconfirm'
fi

### ---------- 8) Google Chrome (AUR) ----------
log "[8/14] Google Chrome (AUR)"
as_user 'yay -S --noconfirm --needed --sudoloop google-chrome' || true

### ---------- 9) Fonts: Cascadia Code Nerd + Emoji ----------
log "[9/14] Cascadia Code Nerd Font + Noto Emoji"
pacman -S --needed --noconfirm noto-fonts-emoji
# Prefer AUR ttf-cascadia-code-nerd; fall back to meta package if needed
as_user 'yay -S --noconfirm --needed --sudoloop ttf-cascadia-code-nerd || yay -S --noconfirm --needed --sudoloop nerd-fonts-cascadia-code' || true
fc-cache -fv >/dev/null || true

### ---------- 10) Theming: Catppuccin + Papirus (force apply) ----------
log "[10/14] Catppuccin (Kvantum + KDE colors) + Papirus icons"

# Force Kvantum for Qt apps
mkdir -p "$TARGET_HOME/.config/plasma-workspace/env"
cat > "$TARGET_HOME/.config/plasma-workspace/env/kvantum.sh" <<'EOF'
#!/usr/bin/env bash
export QT_STYLE_OVERRIDE=kvantum
EOF
chmod +x "$TARGET_HOME/.config/plasma-workspace/env/kvantum.sh"

# User dirs for themes
as_user 'mkdir -p "$HOME/.config/Kvantum" "$HOME/.local/share/color-schemes"'

# Kvantum themes
as_user 'git clone --depth=1 https://github.com/catppuccin/Kvantum.git "$HOME/.config/Kvantum/.catppuccin-tmp" || true'
as_user 'cp -r "$HOME/.config/Kvantum/.catppuccin-tmp/themes/"* "$HOME/.config/Kvantum"/ 2>/dev/null || true'
as_user 'rm -rf "$HOME/.config/Kvantum/.catppuccin-tmp" || true'

# Kvantum selection file
mkdir -p "$TARGET_HOME/.config/Kvantum"
cat > "$TARGET_HOME/.config/Kvantum/kvantum.kvconfig" <<'EOF'
[General]
theme=Catppuccin-Mocha
# If the Mauve variant exists on your system, you can use:
# theme=Catppuccin-Mocha-Mauve
EOF
chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config/Kvantum"

# KDE color scheme
as_user 'curl -fsSL https://raw.githubusercontent.com/catppuccin/kde/refs/heads/main/dist/CatppuccinMocha.colors -o "$HOME/.local/share/color-schemes/CatppuccinMocha.colors"' || true

# Icons & cursors
pacman -S --needed --noconfirm papirus-icon-theme
as_user 'yay -S --noconfirm --needed --sudoloop catppuccin-cursors-mocha' || true

# Apply now and on login
APPLY_SCRIPT="$TARGET_HOME/.config/plasma-catppuccin-apply.sh"
cat > "$APPLY_SCRIPT" <<'EOS'
#!/usr/bin/env bash
set -e
kwcfg(){
  if command -v kwriteconfig6 >/dev/null 2>&1; then kwriteconfig6 "$@";
  elif command -v kwriteconfig5 >/dev/null 2>&1; then kwriteconfig5 "$@";
  else return 0; fi
}
if command -v kvantummanager >/dev/null 2>&1; then kvantummanager --set "Catppuccin-Mocha" || true; fi
kwcfg --file kdeglobals --group KDE   --key widgetStyle "kvantum" || true
if command -v plasma-apply-colorscheme >/dev/null 2>&1; then plasma-apply-colorscheme CatppuccinMocha || true; fi
kwcfg --file kdeglobals --group Icons --key Theme "Papirus-Dark" || true
kwcfg --file kcminputrc --group Mouse --key cursorTheme "Catppuccin-Mocha-Lavender-Cursors" || true
if command -v kquitapp5 >/dev/null 2>&1; then kquitapp5 plasmashell 2>/dev/null || true; (plasmashell &>/dev/null &) || true; fi
EOS
chmod +x "$APPLY_SCRIPT"
bash "$APPLY_SCRIPT" || true
ensure_line "$APPLY_SCRIPT &" "$TARGET_HOME/.config/plasma-workspace/env/catppuccin-apply.sh"
chmod +x "$TARGET_HOME/.config/plasma-workspace/env/catppuccin-apply.sh" 2>/dev/null || true
chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config/plasma-workspace"

### ---------- 11) LazyVim ----------
log "[11/14] LazyVim (~/.config/nvim)"
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

### ---------- 12) Snapper + grub-btrfs (install only; no snapper scheduling) ----------
log "[12/14] Snapper + grub-btrfs (install only)"
pacman -S --needed --noconfirm snapper grub-btrfs || true

# If grub-btrfs provides a systemd unit on this system (i.e., you use GRUB), enable it.
if systemctl list-unit-files | grep -q '^grub-btrfs\.path'; then
  systemctl enable --now grub-btrfs.path
  # Optional: rebuild GRUB menu if GRUB is installed
  if have grub-mkconfig; then grub-mkconfig -o /boot/grub/grub.cfg || true; fi
else
  echo "ℹ grub-btrfs.path unit not found. Skipping GRUB integration (non-GRUB systems or unit not provided)."
fi

### ---------- 13) Final ownership pass ----------
log "[13/14] Fix ownership of user configs"
chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config" "$TARGET_HOME/.local" || true

### ---------- 14) Summary ----------
log "[14/14] Summary"
echo "- yay: pacman NOPASSWD set in /etc/sudoers.d/90-pacman-nopasswd-$TARGET_USER"
echo "- CLI: curl fzf ripgrep bat eza zoxide btop installed; bash aliases added (batcat shim provided)"
echo "- Fonts: Cascadia Code Nerd + Noto Emoji installed; fc-cache refreshed"
echo "- Theme: Kvantum + Catppuccin Mocha + Papirus-Dark applied (also on login)"
echo "- Snapper & grub-btrfs installed; grub-btrfs enabled only if the unit exists"
echo "- Reboot recommended to pick up SDDM and environment."
