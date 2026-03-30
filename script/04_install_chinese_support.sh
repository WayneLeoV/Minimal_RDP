#!/usr/bin/env bash
set -euo pipefail

############################################################
# 04_install_chinese_support.sh
#
# Objectives:
#   1) Enable Chinese display support
#   2) Enable Chinese input method support
#   3) Do not change the system default language
#   4) Do not modify locale / locale-gen / update-locale
#   5) Apply to all users:
#      - Existing users: via system-wide Xsession configuration + existing user directory completion
#      - Future new users: inherited through /etc/skel
############################################################

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "[1/6] Installing Chinese fonts and Fcitx5 packages..."
apt-get update
apt-get install -y --no-install-recommends \
  fonts-noto-cjk \
  fcitx5 \
  fcitx5-chinese-addons \
  fcitx5-frontend-gtk3 \
  fcitx5-frontend-qt5 \
  fcitx5-config-qt

echo "[2/6] Installing system-wide X session hook..."
install -d /etc/X11/Xsession.d

cat > /etc/X11/Xsession.d/99fcitx5-chinese-support <<'EOF'
#!/bin/sh

# Fcitx5 input method environment
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx
export GLFW_IM_MODULE=fcitx

# Start fcitx5 once per graphical session, per user
if [ -n "${DISPLAY:-}" ]; then
  if ! pgrep -u "$(id -u)" -x fcitx5 >/dev/null 2>&1; then
    fcitx5 -d >/dev/null 2>&1 &
  fi
fi
EOF

chmod 0755 /etc/X11/Xsession.d/99fcitx5-chinese-support

echo "[3/6] Installing system-wide shell environment hook..."
install -d /etc/profile.d

cat > /etc/profile.d/99fcitx5-chinese-support.sh <<'EOF'
#!/bin/sh
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx
export GLFW_IM_MODULE=fcitx
EOF

chmod 0644 /etc/profile.d/99fcitx5-chinese-support.sh

echo "[4/6] Preparing default files for future users under /etc/skel..."
install -d /etc/skel/.config/fcitx5

cat > /etc/skel/.config/fcitx5/profile <<'EOF'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=pinyin

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=pinyin
Layout=

[GroupOrder]
0=Default
EOF

echo "[5/6] Applying fcitx5 profile to existing normal users..."
backup_and_write_profile() {
  local home_dir="$1"
  local profile_dir="${home_dir}/.config/fcitx5"
  local profile_file="${profile_dir}/profile"

  if [[ ! -d "${home_dir}" ]]; then
    return 0
  fi

  install -d -m 0755 "${profile_dir}"

  if [[ -f "${profile_file}" ]]; then
    if grep -qE '(^|[[:space:]])pinyin([[:space:]]|$)' "${profile_file}"; then
      chown -R "$(stat -c '%U:%G' "${home_dir}")" "${profile_dir}" 2>/dev/null || true
      return 0
    fi

    cp -a "${profile_file}" "${profile_file}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cat > "${profile_file}" <<'EOF'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=pinyin

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=pinyin
Layout=

[GroupOrder]
0=Default
EOF

  return 0
}

while IFS=: read -r user _ uid _ _ home shell; do
  if [[ "${uid}" -ge 1000 && "${uid}" -lt 65534 && "${home}" == /* && "${shell}" != */nologin && "${shell}" != */false ]]; then
    backup_and_write_profile "${home}"
    chown -R "${user}:${user}" "${home}/.config/fcitx5" 2>/dev/null || true
  fi
done < <(getent passwd)

echo "[6/6] Done."
echo "Chinese display and input are now enabled system-wide."
echo "Log out and log back in for the changes to take effect."
echo "If a user already had a custom fcitx5 profile, a backup was created before replacement when needed."
