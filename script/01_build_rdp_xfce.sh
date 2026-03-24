#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

############################################################
# 01_build_rdp_xfce.sh
#
# Goals:
#   1) Install the base Xorg + XRDP + XFCE stack
#   2) Install and configure ZRAM with conservative sizing
#   3) Prepare Xorg / XRDP / per-user session defaults
#   4) Keep the script idempotent and easy to maintain
#
# Notes:
#   - This script installs the platform only.
#   - XFCE / XRDP visual and channel tuning is handled in 02.
############################################################

############################################################
# [Phase 0] Logging helpers
############################################################

log() {
  printf '\n[%s] %s\n' "$(date +'%F %T')" "$*"
}

choose_user() {
  # Prefer the original sudo user if present
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
    echo "$SUDO_USER"
    return
  fi

  # Fall back to the current non-root user if possible
  if [[ -n "${USER:-}" && "${USER:-}" != "root" ]]; then
    echo "$USER"
    return
  fi

  # Last resort: pick the first normal login user from /etc/passwd
  awk -F: '$3>=1000 && $1!="nobody" {print $1; exit}' /etc/passwd
}

TARGET_USER="$(choose_user || true)"
TARGET_HOME=""
if [[ -n "$TARGET_USER" ]] && getent passwd "$TARGET_USER" >/dev/null 2>&1; then
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
fi

############################################################
# [Phase 1] Package installation
############################################################

log "Updating package lists"
apt-get update

log "Installing base desktop stack and ZRAM generator"
apt-get install -y \
  systemd-zram-generator \
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

############################################################
# [Phase 2] ZRAM + swapfile
#
# Policy:
#   - Create /swapfile as a low-priority fallback swap
#   - Prefer zram over disk swap for interactive responsiveness
#   - /etc/fstab is used to mount the fallback swap file automatically
############################################################

log "Configuring ZRAM generator"

mkdir -p /etc/systemd/zram-generator.conf.d

if [[ -f /etc/systemd/zram-generator.conf.d/10-xrdp.conf && ! -f /etc/systemd/zram-generator.conf.d/10-xrdp.conf.bak ]]; then
  cp -a /etc/systemd/zram-generator.conf.d/10-xrdp.conf /etc/systemd/zram-generator.conf.d/10-xrdp.conf.bak
fi

cat >/etc/systemd/zram-generator.conf.d/10-xrdp.conf <<'EOF'
# ZRAM configuration for a memory-sensitive XRDP desktop
#
# Strategy:
#   - Keep ZRAM conservative on small-memory hosts
#   - Use a fast compressor
#   - Give ZRAM a higher swap priority than the fallback swapfile
[zram0]
zram-size = min(ram / 4, 1024)
compression-algorithm = lz4
swap-priority = 100
EOF

log "Preparing fallback swapfile"

SWAPFILE="/swapfile"
SWAPSIZE_MIB="$(awk '/MemTotal:/ {print int($2 / 1024 / 2); exit}' /proc/meminfo)"
SWAPFSTAB_LINE="${SWAPFILE} none swap sw,pri=10 0 0"

# Backup fstab once before editing
if [[ -f /etc/fstab && ! -f /etc/fstab.bak ]]; then
  cp -a /etc/fstab /etc/fstab.bak
fi

# Ensure the swapfile is not active while we recreate it
swapoff "$SWAPFILE" >/dev/null 2>&1 || true

# Create or recreate the swapfile
if [[ -f "$SWAPFILE" ]]; then
  rm -f "$SWAPFILE"
fi

fallocate -l "${SWAPSIZE_MIB}M" "$SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAPSIZE_MIB" status=none
chmod 600 "$SWAPFILE"
mkswap "$SWAPFILE" >/dev/null

# Remove any previous /swapfile entry, then add the canonical line once
sed -i "\|^[[:space:]]*${SWAPFILE//\//\\/}[[:space:]]\+|d" /etc/fstab
echo "$SWAPFSTAB_LINE" >> /etc/fstab

# Activate fallback swap immediately with low priority
swapon -p 10 "$SWAPFILE" >/dev/null 2>&1 || true

log "Applying memory policy"
cat >/etc/sysctl.d/99-xrdp-zram.conf <<'EOF'
vm.swappiness = 100
EOF
sysctl --system >/dev/null 2>&1 || true

log "Starting ZRAM service now"
systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service >/dev/null 2>&1 || true

log "ZRAM + swapfile configured"

############################################################
# [Phase 3] Xorg wrapper
#
# Purpose:
#   - Allow XRDP/Xorg sessions to start without console-user restrictions
############################################################

log "Configuring Xorg wrapper"

cat >/etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

############################################################
# [Phase 4] XRDP session startup
#
# Purpose:
#   - Start XFCE reliably for every RDP session
#   - Keep the startup script minimal
#   - Avoid session-side tuning here; that belongs in 02
############################################################

log "Configuring XRDP to start XFCE"

if [[ -f /etc/xrdp/startwm.sh && ! -f /etc/xrdp/startwm.sh.bak ]]; then
  cp -a /etc/xrdp/startwm.sh /etc/xrdp/startwm.sh.bak
fi

cat >/etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
set -eu

# Minimal environment normalization for XRDP sessions
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

############################################################
# [Phase 5] Default per-user session files
#
# Purpose:
#   - Make new users inherit a working XFCE session automatically
#   - Patch the target user to reduce first-login surprises
############################################################

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

############################################################
# [Phase 6] Service and access adjustments
#
# Purpose:
#   - Allow XRDP to use SSL certificates
#   - Open the default RDP port if UFW is present
#   - Enable the required services
############################################################

log "Adding xrdp to ssl-cert group if present"
adduser xrdp ssl-cert >/dev/null 2>&1 || true

log "Opening firewall port 3389/tcp if UFW is installed"
if command -v ufw >/dev/null 2>&1; then
  ufw --force allow 3389/tcp >/dev/null 2>&1 || true
fi

log "Enabling services"
systemctl enable --now xrdp xrdp-sesman
systemctl restart xrdp xrdp-sesman

############################################################
# [Phase 7] Completion message
############################################################

log "Done"
echo
echo "Use your RDP client to connect to: <server-ip>:3389"
echo "Login with the local Linux user you set above."
echo "ZRAM will be active after the next reboot."
