#!/usr/bin/env bash
set -euo pipefail

############################################################
# 02_xrdp_xfce_optimize.sh
#
# Goals:
#   1) Keep resource usage low and improve RDP responsiveness
#   2) Disable unneeded components/features, keep binaries installed
#   3) Use a black-focused GUI theme
#   4) Apply all XFCE customization once, not on every RDP login
#
# Target:
#   Ubuntu + xrdp + xorgxrdp + XFCE
#
# Design principles:
#   - Keep core components to avoid black screen issues
#   - Use system-wide defaults + autostart overrides + xrdp config
#   - Make all changes idempotent and repeatable
############################################################

############################################################
# [Tunables]
############################################################

# Keep clipboard: 1=enabled, 0=disabled
# Note: keeping clipboard is more convenient for development;
# disabling it slightly reduces channel overhead
KEEP_CLIPBOARD="${KEEP_CLIPBOARD:-1}"

# Seconds to wait after disconnect before killing the session
DISCONNECT_KILL_SECONDS="${DISCONNECT_KILL_SECONDS:-60}"

# Disable Bluetooth service (usually useless on cloud servers)
DISABLE_BLUETOOTH="${DISABLE_BLUETOOTH:-1}"

# Disable PulseAudio autospawn (do not uninstall, only stop autospawn)
DISABLE_PULSEAUDIO_AUTOSPAWN="${DISABLE_PULSEAUDIO_AUTOSPAWN:-1}"

# Disable AT-SPI bridge (reduces desktop accessibility overhead)
DISABLE_AT_SPI="${DISABLE_AT_SPI:-1}"

# Dark theme name (prefer a common dark theme)
GTK_DARK_THEME="Nordic-darker"      # Adwaita-dark
WM_DARK_THEME="Nordic-darker"       # Adwaita-dark
ICON_THEME="Papirus"                # Adwaita

############################################################
# [Base functions]
############################################################

BACKUP_ROOT="/var/backups/xrdp_xfce_optimize"
TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}_${TS}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Please run this script with sudo/root." >&2
    exit 1
  fi
}

backup_file() {
  local src="$1"
  if [[ -f "$src" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp -a "$src" "$BACKUP_DIR/"
  fi
}

backup_dir() {
  local src="$1"
  if [[ -d "$src" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp -a "$src" "$BACKUP_DIR/"
  fi
}

safe_install_file() {
  local path="$1"
  local content="$2"
  mkdir -p "$(dirname "$path")"
  backup_file "$path"
  printf '%s\n' "$content" > "$path"
}

safe_append_once() {
  local file="$1"
  local line="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if ! grep -qxF "$line" "$file"; then
    printf '%s\n' "$line" >> "$file"
  fi
}

############################################################
# [1. Force a unified desktop startup method (system-wide)]
#
# Purpose:
#   - Make all users use XFCE consistently
#   - Avoid black screens caused by different .xsession files
#   - Clean up session-related environment variables
#   - IMPORTANT: do not run xfconf-query here anymore;
#     all customization is applied once during script execution
############################################################

write_startwm() {
  cat > /etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
set -eu

# AT-SPI accessibility bridge is usually unnecessary in remote desktop usage.
# Disable it via environment to reduce startup overhead.
export NO_AT_BRIDGE=1

# Normalize session environment to reduce interference from other desktops
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE
export DESKTOP_SESSION=xfce

# Clear common session pollution variables to reduce black-screen / crash risk
unset DBUS_SESSION_BUS_ADDRESS
unset SESSION_MANAGER

# Only start the desktop; do not modify session settings here
if command -v startxfce4 >/dev/null 2>&1; then
  exec startxfce4
fi

exec xfce4-session
EOF
  chmod 0755 /etc/xrdp/startwm.sh
}

############################################################
# [2. Allow XRDP to use Xorg (avoid permission issues)]
#
# Purpose:
#   - Avoid "Only console users allowed"
#   - Ensure xorgxrdp works correctly
############################################################

write_xwrapper() {
  cat > /etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF
}

############################################################
# [3. Provide a default .xsession for all users]
#
# Purpose:
#   - New users inherit the XFCE startup method automatically
#   - Existing users get a valid .xsession to reduce black screen risk
############################################################

write_skel_xsession() {
  mkdir -p /etc/skel

  cat > /etc/skel/.xsession <<'EOF'
#!/bin/sh
exec startxfce4
EOF
  chmod 0755 /etc/skel/.xsession

  if [[ -d /home ]]; then
    while IFS= read -r -d '' homedir; do
      if [[ -d "$homedir" && ! -e "$homedir/.xsession" ]]; then
        cat > "$homedir/.xsession" <<'EOF'
#!/bin/sh
exec startxfce4
EOF
        chmod 0755 "$homedir/.xsession"
        chown --reference="$homedir" "$homedir/.xsession" 2>/dev/null || true
      fi
    done < <(find /home -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
  fi
}

############################################################
# [4. XRDP core performance tuning]
#
# Notes:
#   - Keep: max_bpp / bitmap_cache / bitmap_compression / bulk_compression
#           / use_fastpath / tcp_keepalive
#   - Do not add: xserverbpp / use_compression / h264_* (not applicable here)
#   - Channel trimming: disable sound, device redirection, RAIL, xrdpvr
#   - Session cleanup: KillDisconnected + DisconnectedTimeLimit
############################################################

patch_ini() {
  python3 - "$1" "$KEEP_CLIPBOARD" "$DISCONNECT_KILL_SECONDS" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
keep_clipboard = sys.argv[2] == '1'
disconnect_kill_seconds = sys.argv[3]

if not path.exists():
    raise SystemExit(f"Configuration file not found: {path}")

text = path.read_text(encoding="utf-8", errors="ignore")
lines = text.splitlines()

def find_section(section):
    sec = f'[{section.lower()}]'
    for i, line in enumerate(lines):
        if line.strip().lower() == sec:
            return i
    return None

def section_end(start_idx):
    for j in range(start_idx + 1, len(lines)):
        if lines[j].lstrip().startswith('['):
            return j
    return len(lines)

def upsert(section, kvs):
    start = find_section(section)
    if start is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines.append(f"[{section}]")
        for k, v in kvs:
            lines.append(f"{k}={v}")
        return

    end = section_end(start)
    body = lines[start + 1:end]

    for k, v in kvs:
        pat = re.compile(r'^\s*[#;]?\s*' + re.escape(k) + r'\s*=.*$', re.IGNORECASE)
        replaced = False
        for idx, line in enumerate(body):
            if pat.match(line):
                body[idx] = f"{k}={v}"
                replaced = True
                break
        if not replaced:
            body.append(f"{k}={v}")

    lines[start + 1:end] = body

name = path.name

if name == "xrdp.ini":
    upsert("Globals", [
        ("autorun", "Xorg"),
        ("allow_channels", "true"),
        ("allow_multimon", "false"),
        ("bitmap_cache", "true"),
        ("bitmap_compression", "true"),
        ("bulk_compression", "true"),
        ("hidelogwindow", "true"),
        ("max_bpp", "16"),
        ("tcp_nodelay", "true"),
        ("tcp_keepalive", "true"),
        ("use_fastpath", "both"),
    ])

    upsert("Channels", [
        ("rdpdr", "false"),
        ("rdpsnd", "false"),
        ("drdynvc", "true"),
        ("cliprdr", "true" if keep_clipboard else "false"),
        ("rail", "false"),
        ("xrdpvr", "false"),
    ])

    upsert("Xorg", [
        ("code", "20"),
    ])

elif name == "sesman.ini":
    upsert("Globals", [
        ("EnableUserWindowManager", "false"),
        ("UserWindowManager", "startwm.sh"),
        ("DefaultWindowManager", "startwm.sh"),
        ("ReconnectScript", "reconnectwm.sh"),
    ])

    upsert("Sessions", [
        ("KillDisconnected", "true"),
        ("DisconnectedTimeLimit", disconnect_kill_seconds),
        ("IdleTimeLimit", "0"),
        ("MaxSessions", "5"),
    ])

else:
    raise SystemExit(f"Unsupported file: {name}")

path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
PY
}

############################################################
# [5. XFCE system-wide defaults (system dir + /etc/skel + existing users)]
#
# Notes:
#   - This is "default value override", not uninstall/removal
#   - /etc/xdg defaults help new users inherit settings
#   - Existing user configs are also updated to avoid old settings persisting
#   - Desktop icons are kept enabled
############################################################

write_xfce_default_files() {
  local sysdir="/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
  local skeldir="/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml"

  mkdir -p "$sysdir" "$skeldir"

  # xsettings:
  #   - dark theme
  #   - keep menu icons / button icons
  #   - keep font smoothing
  cat > "$sysdir/xsettings.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="${GTK_DARK_THEME}"/>
    <property name="IconThemeName" type="string" value="${ICON_THEME}"/>
    <property name="EnableEventSounds" type="bool" value="false"/>
    <property name="EnableInputFeedbackSounds" type="bool" value="false"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="MenuImages" type="bool" value="true"/>
    <property name="ButtonImages" type="bool" value="true"/>
    <property name="EnableTooltips" type="bool" value="false"/>
  </property>
</channel>
EOF

  # xfwm4: disable compositing and shadows, set dark theme
  cat > "$sysdir/xfwm4.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
    <property name="show_frame_shadow" type="bool" value="false"/>
    <property name="show_popup_shadow" type="bool" value="false"/>
    <property name="workspace_count" type="int" value="1"/>
    <property name="theme" type="string" value="${WM_DARK_THEME}"/>
  </property>
</channel>
EOF

  # xfce4-desktop: clear wallpaper and force a pure black background
cat > "$sysdir/xfce4-desktop.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
EOF

  for monitor in monitor0 monitorVirtual1 monitorrdp0; do
    cat >> "$sysdir/xfce4-desktop.xml" <<EOF
      <property name="${monitor}" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="0"/>
          <property name="image-show" type="bool" value="false"/>
          <property name="image-path" type="empty"/>
          <property name="last-image" type="empty"/>
          <property name="last-single-image" type="empty"/>

          <property name="rgba1" type="array">
            <value type="double" value="0.000000"/>
            <value type="double" value="0.000000"/>
            <value type="double" value="0.000000"/>
            <value type="double" value="1.000000"/>
          </property>
          <property name="rgba2" type="array">
            <value type="double" value="0.000000"/>
            <value type="double" value="0.000000"/>
            <value type="double" value="0.000000"/>
            <value type="double" value="1.000000"/>
          </property>
        </property>
      </property>
EOF
  done

  cat >> "$sysdir/xfce4-desktop.xml" <<'EOF'
    </property>
  </property>
</channel>
EOF

  # Copy to /etc/skel so new users inherit the settings by default
  cp -a "$sysdir/xsettings.xml" "$skeldir/xsettings.xml"
  cp -a "$sysdir/xfwm4.xml" "$skeldir/xfwm4.xml"
  cp -a "$sysdir/xfce4-desktop.xml" "$skeldir/xfce4-desktop.xml"

  # Update existing users (including root) so old configs do not keep winning
  local home_dirs=("/root")
  if [[ -d /home ]]; then
    while IFS= read -r -d '' homedir; do
      home_dirs+=("$homedir")
    done < <(find /home -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
  fi

  for homedir in "${home_dirs[@]}"; do
    [[ -d "$homedir" ]] || continue
    local user_conf="$homedir/.config/xfce4/xfconf/xfce-perchannel-xml"
    mkdir -p "$user_conf"
    cp -a "$sysdir/xsettings.xml" "$user_conf/xsettings.xml"
    cp -a "$sysdir/xfwm4.xml" "$user_conf/xfwm4.xml"
    cp -a "$sysdir/xfce4-desktop.xml" "$user_conf/xfce4-desktop.xml"
    chown -R --reference="$homedir" "$homedir/.config" 2>/dev/null || true
  done
}

############################################################
# [6. Disable unnecessary XFCE autostart / daemons]
#
# Notes:
#   - Only use Hidden=true overrides, do not remove packages
#   - Suitable for cloud servers: power manager, screensaver,
#     notification daemon are usually unnecessary
############################################################

write_autostart_overrides() {
  local adir="/etc/xdg/autostart"
  mkdir -p "$adir"

  for file in \
    xfce4-power-manager.desktop \
    xfce4-screensaver.desktop \
    xfce4-notifyd.desktop
  do
    cat > "$adir/$file" <<'EOF'
[Desktop Entry]
Hidden=true
EOF
  done
}

############################################################
# [7. System-level disable: Bluetooth / PulseAudio autospawn / AT-SPI / colord]
############################################################

disable_nonessential_services() {
  # Bluetooth: usually useless on a cloud server, disable it
  if [[ "$DISABLE_BLUETOOTH" == "1" ]]; then
    systemctl disable --now bluetooth.service bluetooth.socket bluetooth.target 2>/dev/null || true
  fi

  # colord: color management is usually unnecessary for cloud/RDP-only usage
  systemctl disable --now colord.service 2>/dev/null || true
  systemctl mask colord.service 2>/dev/null || true

  # PulseAudio: do not uninstall, only prevent autospawn
  if [[ "$DISABLE_PULSEAUDIO_AUTOSPAWN" == "1" ]]; then
    mkdir -p /etc/pulse/client.conf.d
    cat > /etc/pulse/client.conf.d/99-xrdp-minimal.conf <<'EOF'
autospawn = no
EOF
  fi

  # AT-SPI: accessibility bridge is usually unnecessary for cloud RDP usage
  if [[ "$DISABLE_AT_SPI" == "1" ]]; then
    safe_append_once /etc/environment 'NO_AT_BRIDGE=1'
    mkdir -p /etc/profile.d
    cat > /etc/profile.d/99-no-at-spi.sh <<'EOF'
#!/bin/sh
export NO_AT_BRIDGE=1
EOF
    chmod 0644 /etc/profile.d/99-no-at-spi.sh
  fi
}

############################################################
# [8. Install theme and icon once]
############################################################

install_theme_and_icon() {
  # Install theme, (Nordic-darker, papirus-icon-theme), (Adwaita-dark, Adwaita)
  local theme_name="Nordic-darker"
  local theme_file="/tmp/Nordic-darker.tar.xz"
  local url="https://github.com/EliverLara/Nordic/releases/download/v2.2.0/Nordic-darker.tar.xz"
  if [[ ! -d "/usr/share/themes/${theme_name}" && ! -d "/usr/share/themes/${theme_name}.theme" ]]; then
    log "Installing theme: ${theme_name}"
    curl -fsSL "$url" -o "$theme_file"
    mkdir -p /usr/share/themes
    tar -xf "$theme_file" -C /usr/share/themes
    rm -f "$theme_file"
  fi

  # Papirus icon theme
  if ! dpkg -s papirus-icon-theme >/dev/null 2>&1; then
    apt-get update
    apt-get install -y papirus-icon-theme
  fi

  # Fallback to the system dark theme if Nordic-darker is not available
  if [[ ! -d "/usr/share/themes/Nordic-darker" ]]; then
    GTK_DARK_THEME="Adwaita-dark"
    WM_DARK_THEME="Adwaita-dark"
  fi

  # Fallback to Adwaita icons if Papirus is not installed successfully
  if ! dpkg -s papirus-icon-theme >/dev/null 2>&1; then
    ICON_THEME="Adwaita"
  fi
}

############################################################
# [Main flow]
############################################################

main() {
  require_root

  [[ -f /etc/xrdp/xrdp.ini ]] || { echo "Could not find /etc/xrdp/xrdp.ini. Please run the 01 installation script first."; exit 1; }
  [[ -f /etc/xrdp/sesman.ini ]] || { echo "Could not find /etc/xrdp/sesman.ini. Please run the 01 installation script first."; exit 1; }

  mkdir -p "$BACKUP_DIR"
  backup_file /etc/xrdp/xrdp.ini
  backup_file /etc/xrdp/sesman.ini
  backup_file /etc/xrdp/startwm.sh
  backup_file /etc/X11/Xwrapper.config
  backup_dir /etc/xdg/xfce4/xfconf/xfce-perchannel-xml
  backup_dir /etc/xdg/autostart
  backup_dir /etc/pulse/client.conf.d
  backup_file /etc/environment
  backup_dir /etc/profile.d

  log "Backup current configuration files: $BACKUP_DIR"

  install_theme_and_icon

  write_startwm
  write_xwrapper
  patch_ini /etc/xrdp/xrdp.ini
  patch_ini /etc/xrdp/sesman.ini

  write_xfce_default_files
  write_autostart_overrides
  disable_nonessential_services
  write_skel_xsession

  systemctl enable --now xrdp-sesman xrdp >/dev/null 2>&1 || true
  systemctl restart xrdp-sesman xrdp

  log "02_xrdp_xfce_optimize.sh completed."
  systemctl --no-pager --full --legend=no status xrdp-sesman xrdp | sed -n '1,18p' || true
}

main "$@"
