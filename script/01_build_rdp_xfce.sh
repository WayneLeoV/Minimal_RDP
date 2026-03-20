#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

log() {
  printf '\n[%s] %s\n' "$(date +'%F %T')" "$*"
}

choose_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
    echo "$SUDO_USER"
    return
  fi

  if [[ -n "${USER:-}" && "${USER:-}" != "root" ]]; then
    echo "$USER"
    return
  fi

  awk -F: '$3>=1000 && $1!="nobody" {print $1; exit}' /etc/passwd
}

TARGET_USER="$(choose_user || true)"
TARGET_HOME=""
if [[ -n "$TARGET_USER" ]] && getent passwd "$TARGET_USER" >/dev/null 2>&1; then
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
fi

log "Updating package lists"
apt-get update

log "Installing Xorg + XRDP + XorgXrdp + XFCE"
apt-get install -y \
  xorg \
  xrdp \
  xorgxrdp \
  xfce4 \
  xfce4-goodies \
  dbus-x11 \
  xauth \
  x11-xserver-utils \
  xterm \
  fonts-dejavu-core \
  fonts-liberation

log "Configuring Xorg wrapper"
cat >/etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

log "Configuring XRDP to start XFCE"
if [[ -f /etc/xrdp/startwm.sh && ! -f /etc/xrdp/startwm.sh.bak ]]; then
  cp -a /etc/xrdp/startwm.sh /etc/xrdp/startwm.sh.bak
fi

cat >/etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
if [ -r /etc/profile ]; then
  . /etc/profile
fi

if [ -r "$HOME/.profile" ]; then
  . "$HOME/.profile"
fi

export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE
export DESKTOP_SESSION=xfce

unset DBUS_SESSION_BUS_ADDRESS
unset SESSION_MANAGER
unset XDG_RUNTIME_DIR

exec startxfce4
EOF

chmod 755 /etc/xrdp/startwm.sh

log "Preparing per-user XFCE session files"
mkdir -p /etc/skel
cat >/etc/skel/.xsession <<'EOF'
exec startxfce4
EOF
chmod 644 /etc/skel/.xsession

if [[ -n "$TARGET_USER" && -n "$TARGET_HOME" ]]; then
  mkdir -p "$TARGET_HOME"
  cat >"$TARGET_HOME/.xsession" <<'EOF'
exec startxfce4
EOF
  chmod 644 "$TARGET_HOME/.xsession"
  chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.xsession"

  mkdir -p "$TARGET_HOME/.config"
  chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config"
fi

log "Adding xrdp to ssl-cert group if present"
adduser xrdp ssl-cert >/dev/null 2>&1 || true

log "Opening firewall port 3389/tcp if UFW is installed"
if command -v ufw >/dev/null 2>&1; then
  ufw --force allow 3389/tcp >/dev/null 2>&1 || true
fi

log "Enabling services"
systemctl enable --now xrdp xrdp-sesman
systemctl restart xrdp xrdp-sesman

log "Done"
echo
echo "Use your RDP client to connect to: <server-ip>:3389"
echo "Login with the local Linux user you set above."
