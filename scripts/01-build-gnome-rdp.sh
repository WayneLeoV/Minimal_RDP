#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

TOTAL_STEPS=8
CURRENT_STEP=0

log() {
  printf '[%s] %s\n' "$(date +'%F %T')" "$*"
}

step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  printf '\n[%s] Step %d/%d: %s\n' "$(date +'%F %T')" "$CURRENT_STEP" "$TOTAL_STEPS" "$1"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root (or via sudo)." >&2
    exit 1
  fi
}

require_amd64() {
  local arch
  arch="$(dpkg --print-architecture)"
  if [ "$arch" != "amd64" ]; then
    echo "This script is written for amd64 only. Current architecture: ${arch}" >&2
    exit 1
  fi
}

choose_dark_theme() {
  if [ -d /usr/share/themes/Yaru-dark ]; then
    printf '%s' 'Yaru-dark'
  elif [ -d /usr/share/themes/Adwaita-dark ]; then
    printf '%s' 'Adwaita-dark'
  else
    printf '%s' 'Adwaita-dark'
  fi
}

backup_file() {
  local f="$1"
  if [ -e "$f" ]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

ensure_line_in_file() {
  local file="$1"
  local line="$2"
  grep -qxF "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
}

set_ini_key() {
  local file="$1"
  local section="$2"
  local key="$3"
  local value="$4"

  awk -v section="$section" -v key="$key" -v value="$value" '
    function is_section(line) { return line ~ /^\[[^]]+\]$/ }
    BEGIN {
      in_sec = 0
      found_sec = 0
      set_key = 0
    }
    {
      line = $0
      if (is_section(line)) {
        if (in_sec && !set_key) {
          print key "=" value
          set_key = 1
        }
        in_sec = (line == "[" section "]")
        if (in_sec) found_sec = 1
        print
        next
      }

      if (in_sec && line ~ "^[[:space:]]*[;#]?[[:space:]]*" key "[[:space:]]*=") {
        print key "=" value
        set_key = 1
        next
      }

      print
    }
    END {
      if (in_sec && !set_key) {
        print key "=" value
        set_key = 1
      }
      if (!found_sec) {
        print ""
        print "[" section "]"
        print key "=" value
      }
    }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

install_base_packages() {
  log "Installing desktop, RDP, language, and input method packages"
  apt-get update
  apt-get install -y \
    software-properties-common \
    ca-certificates \
    curl \
    wget \
    gnupg \
    xdg-utils \
    x11-xserver-utils \
    unzip \
    git \
    ubuntu-desktop-minimal \
    gnome-shell-extensions \
    gnome-session \
    xrdp \
    xorgxrdp \
    dbus-x11 \
    dconf-cli \
    systemd-zram-generator \
    ibus \
    ibus-libpinyin \
    language-pack-zh-hans \
    fonts-noto-cjk

  # Remove common desktop applications that are not required for this workstation.
  local purge_pkgs=(
    gnome-software
    packagekit
    packagekit-tools
    firefox
    thunderbird
    rhythmbox
    totem
    shotwell
    simple-scan
    cheese
    gnome-calendar
    gnome-contacts
    gnome-maps
    gnome-weather
    yelp
  )

  for pkg in "${purge_pkgs[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      apt-get purge -y "$pkg" || true
    fi
  done

  if snap list firefox >/dev/null 2>&1; then
    snap remove --purge firefox || true
  fi

  apt-get autoremove -y --purge || true
}

configure_timezone() {
  log "Setting timezone to America/Los_Angeles"
  timedatectl set-timezone America/Los_Angeles || true
  ln -snf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime
  printf '%s\n' 'America/Los_Angeles' >/etc/timezone
}

configure_system_environment() {
  log "Setting system-wide input method environment variables"
  install -d -m 0755 /etc/environment.d
  cat >/etc/environment.d/99-ai-coding-ime.conf <<'EOF_ENV'
GTK_IM_MODULE=ibus
QT_IM_MODULE=ibus
SDL_IM_MODULE=ibus
XMODIFIERS=@im=ibus
GLFW_IM_MODULE=ibus
EOF_ENV
}

configure_gnome_defaults() {
  log "Configuring GNOME defaults for all users"

  local gtk_theme
  gtk_theme="$(choose_dark_theme)"

  install -d -m 0755 /etc/dconf/profile
  cat >/etc/dconf/profile/user <<'EOF_PROFILE'
user-db:user
system-db:local
EOF_PROFILE

  install -d -m 0755 /etc/dconf/db/local.d
  cat >/etc/dconf/db/local.d/00-ai-coding-ui <<EOF_DCONF
[org/gnome/desktop/interface]
enable-animations=false
enable-hot-corners=false
color-scheme='prefer-dark'
gtk-theme='${gtk_theme}'
gtk-im-module='ibus'

[org/gnome/desktop/background]
picture-options='none'
color-shading-type='solid'
primary-color='000000'
secondary-color='000000'

[org/gnome/desktop/screensaver]
picture-options='none'
color-shading-type='solid'
primary-color='000000'
secondary-color='000000'
lock-enabled=false
lock-delay=uint32 0

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/settings-daemon/plugins/power]
idle-dim=false
sleep-inactive-ac-timeout=0
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-timeout=0
sleep-inactive-battery-type='nothing'

[org/gnome/desktop/input-sources]
sources=[('xkb', 'us'), ('ibus', 'libpinyin')]
mru-sources=[('ibus', 'libpinyin'), ('xkb', 'us')]
show-all-sources=true
current=uint32 0
xkb-options=@as []

[org/gnome/shell]
enabled-extensions=['alternate-tab@gnome-shell-extensions.gcampax.github.com', 'apps-menu@gnome-shell-extensions.gcampax.github.com', 'launch-new-instance@gnome-shell-extensions.gcampax.github.com', 'places-menu@gnome-shell-extensions.gcampax.github.com', 'static-workspaces@gnome-shell-extensions.gcampax.github.com', 'window-list@gnome-shell-extensions.gcampax.github.com', 'workspace-indicator@gnome-shell-extensions.gcampax.github.com']
disable-user-extensions=true
development-tools=false
EOF_DCONF

  install -d -m 0755 /etc/dconf/db/local.d/locks
  cat >/etc/dconf/db/local.d/locks/00-ai-coding-ui <<'EOF_LOCKS'
/org/gnome/desktop/interface/enable-animations
/org/gnome/desktop/interface/enable-hot-corners
/org/gnome/desktop/interface/color-scheme
/org/gnome/desktop/interface/gtk-theme
/org/gnome/desktop/interface/gtk-im-module
/org/gnome/desktop/background/picture-options
/org/gnome/desktop/background/color-shading-type
/org/gnome/desktop/background/primary-color
/org/gnome/desktop/background/secondary-color
/org/gnome/desktop/screensaver/picture-options
/org/gnome/desktop/screensaver/color-shading-type
/org/gnome/desktop/screensaver/primary-color
/org/gnome/desktop/screensaver/secondary-color
/org/gnome/desktop/screensaver/lock-enabled
/org/gnome/desktop/screensaver/lock-delay
/org/gnome/desktop/session/idle-delay
/org/gnome/settings-daemon/plugins/power/idle-dim
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-timeout
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-timeout
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-type
/org/gnome/desktop/input-sources/sources
/org/gnome/desktop/input-sources/mru-sources
/org/gnome/desktop/input-sources/show-all-sources
/org/gnome/desktop/input-sources/current
/org/gnome/desktop/input-sources/xkb-options
/org/gnome/shell/enabled-extensions
/org/gnome/shell/disable-user-extensions
/org/gnome/shell/development-tools
EOF_LOCKS

  dconf update
}

configure_xsession_blanking() {
  log "Disabling X11 screen blanking for all X sessions"
  install -d -m 0755 /etc/X11/Xsession.d
  cat >/etc/X11/Xsession.d/90-ai-coding-disable-blanking <<'EOF_XSESSION'
#!/bin/sh
xset s off -dpms 2>/dev/null || true
xset s noblank 2>/dev/null || true
EOF_XSESSION
  chmod 0755 /etc/X11/Xsession.d/90-ai-coding-disable-blanking
}

configure_gdm() {
  log "Forcing GNOME login path to Xorg"
  install -d -m 0755 /etc/gdm3
  backup_file /etc/gdm3/custom.conf

  if [ -f /etc/gdm3/custom.conf ]; then
    if grep -Eq '^[;#]?[[:space:]]*WaylandEnable[[:space:]]*=' /etc/gdm3/custom.conf; then
      sed -i -E 's|^[;#]?[[:space:]]*(WaylandEnable[[:space:]]*=).*|\1false|' /etc/gdm3/custom.conf
    else
      awk '
        BEGIN { inserted=0 }
        /^\[daemon\][[:space:]]*$/ {
          print
          print "WaylandEnable=false"
          inserted=1
          next
        }
        { print }
        END {
          if (!inserted) {
            print ""
            print "[daemon]"
            print "WaylandEnable=false"
          }
        }
      ' /etc/gdm3/custom.conf > /etc/gdm3/custom.conf.tmp && mv /etc/gdm3/custom.conf.tmp /etc/gdm3/custom.conf
    fi
  else
    cat >/etc/gdm3/custom.conf <<'EOF_GDM'
[daemon]
WaylandEnable=false
EOF_GDM
  fi
}

configure_xrdp() {
  log "Tuning xrdp for lower latency and lower bandwidth"
  local ini="/etc/xrdp/xrdp.ini"
  backup_file "$ini"

  set_ini_key "$ini" "Globals" "bitmap_cache" "true"
  set_ini_key "$ini" "Globals" "bitmap_compression" "true"
  set_ini_key "$ini" "Globals" "bulk_compression" "true"
  set_ini_key "$ini" "Globals" "max_bpp" "16"
  set_ini_key "$ini" "Globals" "tcp_nodelay" "true"
  set_ini_key "$ini" "Globals" "use_fastpath" "both"
  set_ini_key "$ini" "Globals" "security_layer" "negotiate"

  # Launch a GNOME Classic session when possible; otherwise fall back to the Ubuntu GNOME session.
  cat >/etc/xrdp/startwm.sh <<'EOF_STARTWM'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
unset SESSION_MANAGER
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=GNOME-Classic:GNOME
export GNOME_SHELL_SESSION_MODE=classic

xset s off -dpms 2>/dev/null || true
xset s noblank 2>/dev/null || true

if command -v dbus-run-session >/dev/null 2>&1; then
    if command -v gnome-session-classic >/dev/null 2>&1; then
        exec dbus-run-session -- gnome-session-classic
    fi

    if [ -f /usr/share/gnome-session/sessions/gnome-classic.session ]; then
        exec dbus-run-session -- gnome-session --session=gnome-classic
    fi

    exec dbus-run-session -- gnome-session --session=ubuntu
fi

if command -v gnome-session-classic >/dev/null 2>&1; then
    exec gnome-session-classic
fi

if [ -f /usr/share/gnome-session/sessions/gnome-classic.session ]; then
    exec gnome-session --session=gnome-classic
fi

exec gnome-session --session=ubuntu
EOF_STARTWM
  chmod 0755 /etc/xrdp/startwm.sh

  systemctl daemon-reload
  systemctl enable xrdp >/dev/null 2>&1 || true
  systemctl enable xrdp-sesman >/dev/null 2>&1 || true
  systemctl enable gdm3 >/dev/null 2>&1 || true
  systemctl set-default graphical.target
}

configure_zram() {
  log "Configuring zram to 1GB with higher priority than disk swap"
  install -d -m 0755 /etc/systemd
  cat >/etc/systemd/zram-generator.conf <<'EOF_ZRAM'
[zram0]
zram-size = 1024
compression-algorithm = zstd
swap-priority = 100
EOF_ZRAM

  modprobe zram num_devices=1 >/dev/null 2>&1 || true

  if [ -e /sys/block/zram0/disksize ]; then
    swapoff /dev/zram0 >/dev/null 2>&1 || true
    echo 1 > /sys/block/zram0/reset >/dev/null 2>&1 || true

    if [ -w /sys/block/zram0/comp_algorithm ]; then
      if grep -qw zstd /sys/block/zram0/comp_algorithm; then
        echo zstd > /sys/block/zram0/comp_algorithm || true
      else
        local first_alg
        first_alg="$(awk '{print $1}' /sys/block/zram0/comp_algorithm 2>/dev/null || true)"
        if [ -n "${first_alg:-}" ]; then
          echo "$first_alg" > /sys/block/zram0/comp_algorithm || true
        fi
      fi
    fi

    echo $((1024 * 1024 * 1024)) > /sys/block/zram0/disksize
    mkswap -L zram0 /dev/zram0 >/dev/null
    swapon -p 100 /dev/zram0
  fi
}

configure_swapfile() {
  log "Configuring 2GB low-priority swapfile"
  local swapfile="/swapfile"
  local desired_fstab="/swapfile none swap sw,pri=10 0 0"
  local desired_size=$((2 * 1024 * 1024 * 1024))

  if [ -f "$swapfile" ]; then
    local cur_size
    cur_size="$(stat -c '%s' "$swapfile" 2>/dev/null || echo 0)"
    if [ "$cur_size" -ne "$desired_size" ]; then
      swapoff "$swapfile" >/dev/null 2>&1 || true
      rm -f "$swapfile"
    fi
  fi

  if [ ! -f "$swapfile" ]; then
    if ! fallocate -l 2G "$swapfile" 2>/dev/null; then
      dd if=/dev/zero of="$swapfile" bs=1M count=2048 status=progress
    fi
    chmod 600 "$swapfile"
    mkswap "$swapfile" >/dev/null
  fi

  if grep -Eq '^[^#].*[[:space:]]/swapfile[[:space:]]+none[[:space:]]+swap[[:space:]]+' /etc/fstab; then
    sed -i -E "s|^[^#].*[[:space:]]/swapfile[[:space:]]+none[[:space:]]+swap[[:space:]].*$|${desired_fstab}|" /etc/fstab
  else
    ensure_line_in_file /etc/fstab "$desired_fstab"
  fi

  swapon -p 10 "$swapfile" >/dev/null 2>&1 || true
}

main() {
  require_root
  require_amd64

  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "22.04" ]; then
    log "Warning: this script was written for Ubuntu 22.04; continuing anyway."
  fi

  step "Setting timezone to America/Los_Angeles"
  configure_timezone

  step "Installing base desktop, RDP, language, and input method packages"
  install_base_packages

  step "Configuring system-wide input method environment"
  configure_system_environment

  step "Configuring GNOME defaults for all users"
  configure_gnome_defaults

  step "Disabling X11 screen blanking"
  configure_xsession_blanking

  step "Forcing GNOME login path to Xorg"
  configure_gdm

  step "Tuning xrdp session startup and transport settings"
  configure_xrdp

  step "Configuring zram and swapfile"
  configure_zram
  configure_swapfile

  log "Done"
  log "A reboot is recommended."
  log "GNOME system-wide defaults will apply to new users automatically; existing users need to log out and back in."
}

main "$@"
