#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

TOTAL_STEPS=7
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

detect_chrome_bin() {
  if command -v google-chrome >/dev/null 2>&1; then
    command -v google-chrome
    return 0
  fi
  if command -v google-chrome-stable >/dev/null 2>&1; then
    command -v google-chrome-stable
    return 0
  fi
  if [ -x /usr/bin/google-chrome ]; then
    printf '%s\n' /usr/bin/google-chrome
    return 0
  fi
  if [ -x /usr/bin/google-chrome-stable ]; then
    printf '%s\n' /usr/bin/google-chrome-stable
    return 0
  fi

  echo "Google Chrome binary not found." >&2
  exit 1
}

detect_code_bin() {
  if command -v code >/dev/null 2>&1; then
    command -v code
    return 0
  fi
  if command -v code-insiders >/dev/null 2>&1; then
    command -v code-insiders
    return 0
  fi
  if [ -x /usr/bin/code ]; then
    printf '%s\n' /usr/bin/code
    return 0
  fi
  if [ -x /usr/bin/code-insiders ]; then
    printf '%s\n' /usr/bin/code-insiders
    return 0
  fi

  echo "Visual Studio Code binary not found." >&2
  exit 1
}

install_base_dependencies() {
  step "Installing base dependencies"
  apt-get update
  apt-get install -y \
    ca-certificates \
    curl \
    gpg \
    xdg-utils \
    desktop-file-utils
}

install_chrome() {
  step "Installing Google Chrome"
  local tmp="/tmp/google-chrome-stable_current_amd64.deb"
  curl -fL --retry 3 --retry-delay 2 \
    -o "$tmp" \
    "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
  apt-get install -y "$tmp"
  rm -f "$tmp"
}

write_chrome_launcher() {
  local launcher_path="$1"
  local desktop_path="$2"
  local launcher_name="$3"
  local comment="$4"
  local profile_dir="$5"
  local renderer_limit="$6"
  local disk_cache_size="$7"
  local media_cache_size="$8"
  local extra_flags="$9"

  local chrome_bin
  chrome_bin="$(detect_chrome_bin)"

  cat >"$launcher_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

USER_DATA_DIR="\${HOME}/.config/${profile_dir}"
mkdir -p "\${USER_DATA_DIR}"

exec "${chrome_bin}" \
  --user-data-dir="\${USER_DATA_DIR}" \
  --no-first-run \
  --no-default-browser-check \
  --disable-background-networking \
  --disable-component-update \
  --disable-default-apps \
  --disable-domain-reliability \
  --disable-extensions \
  --disable-features=Translate,BackForwardCache,MediaRouter,PaintHolding \
  --disable-gpu \
  --disable-dev-shm-usage \
  --disable-sync \
  --enable-low-end-device-mode \
  --process-per-site \
  --renderer-process-limit=${renderer_limit} \
  --disk-cache-size=${disk_cache_size} \
  --media-cache-size=${media_cache_size} \
  --mute-audio \
  --disable-renderer-backgrounding \
  --disable-software-rasterizer \
  --disable-breakpad \
  ${extra_flags} \
  "\$@"
EOF
  chmod 0755 "$launcher_path"

  cat >"$desktop_path" <<EOF
[Desktop Entry]
Name=${launcher_name}
Comment=${comment}
Exec=${launcher_path} %U
Type=Application
Categories=Network;WebBrowser;
Terminal=false
StartupNotify=true
Icon=google-chrome
EOF
}

configure_chrome_launchers() {
  step "Creating Chrome Lite and Ultra Lite launchers"
  install -d -m 0755 /usr/local/bin
  install -d -m 0755 /usr/local/share/applications

  write_chrome_launcher \
    /usr/local/bin/google-chrome-lite \
    /usr/local/share/applications/google-chrome-lite.desktop \
    "Google Chrome Lite" \
    "Google Chrome with reduced memory usage" \
    "google-chrome-lite" \
    2 \
    33554432 \
    16777216 \
    "--disable-features=PaintHolding"

  write_chrome_launcher \
    /usr/local/bin/google-chrome-ultra-lite \
    /usr/local/share/applications/google-chrome-ultra-lite.desktop \
    "Google Chrome Ultra Lite" \
    "Google Chrome with ultra reduced memory usage" \
    "google-chrome-ultra-lite" \
    1 \
    16777216 \
    8388608 \
    "--disable-features=OptimizationHints,PaintHolding --disable-renderer-accessibility --disable-speech-api"
}

install_vscode() {
  step "Installing Visual Studio Code"
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    > /usr/share/keyrings/microsoft.gpg

  local arch
  arch="$(dpkg --print-architecture)"

  cat >/etc/apt/sources.list.d/vscode.list <<EOF
deb [arch=${arch} signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main
EOF

  apt-get update
  apt-get install -y code
}

write_vscode_lite_settings() {
  local target_dir="$1"
  install -d -m 0755 "$target_dir"

  cat >"$target_dir/settings.json" <<'EOF'
{
  "telemetry.telemetryLevel": "off",
  "workbench.enableExperiments": false,
  "update.mode": "none",
  "extensions.autoUpdate": false,
  "extensions.autoCheckUpdates": false,

  "workbench.startupEditor": "none",
  "window.restoreWindows": "none",
  "files.hotExit": "off",
  "git.autofetch": false,

  "editor.minimap.enabled": false,
  "editor.codeLens": false,
  "editor.semanticHighlighting.enabled": false,
  "editor.glyphMargin": false,
  "breadcrumbs.enabled": false,

  "editor.cursorSmoothCaretAnimation": "off",
  "editor.smoothScrolling": false,
  "editor.renderWhitespace": "none",

  "explorer.decorations.badges": false,
  "explorer.decorations.colors": false
}
EOF
}

copy_vscode_lite_settings_to_existing_users() {
  step "Seeding VS Code Lite settings for existing users"
  local skel_dir="/etc/skel/.config/Code-Lite/User"
  write_vscode_lite_settings "$skel_dir"

  for home in /home/*; do
    [ -d "$home" ] || continue

    local user
    user="$(basename "$home")"

    install -d -m 0755 "$home/.config/Code-Lite/User"
    cp -f "$skel_dir/settings.json" "$home/.config/Code-Lite/User/settings.json"
    chown -R "${user}:${user}" "$home/.config/Code-Lite"
  done
}

write_vscode_launcher() {
  local launcher_path="$1"
  local desktop_path="$2"
  local launcher_name="$3"
  local comment="$4"
  local profile_dir="$5"
  local code_bin
  code_bin="$(detect_code_bin)"

  cat >"$launcher_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

USER_DATA_DIR="\${HOME}/.config/${profile_dir}"
mkdir -p "\${USER_DATA_DIR}"
mkdir -p "\${USER_DATA_DIR}/extensions"

exec "${code_bin}" \
  --user-data-dir="\${USER_DATA_DIR}" \
  --extensions-dir="\${USER_DATA_DIR}/extensions" \
  --disable-gpu \
  --disable-features=CalculateNativeWinOcclusion \
  "\$@"
EOF
  chmod 0755 "$launcher_path"

  cat >"$desktop_path" <<EOF
[Desktop Entry]
Name=${launcher_name}
Comment=${comment}
Exec=${launcher_path} %F
Type=Application
Categories=Development;IDE;
Icon=vscode
Terminal=false
StartupNotify=true
EOF
}

configure_vscode_launcher() {
  step "Creating VS Code Lite launcher and desktop entry"
  install -d -m 0755 /usr/local/bin
  install -d -m 0755 /usr/local/share/applications

  write_vscode_launcher \
    /usr/local/bin/code-lite \
    /usr/local/share/applications/code-lite.desktop \
    "VS Code Lite" \
    "Visual Studio Code with lower startup overhead" \
    "Code-Lite"

  copy_vscode_lite_settings_to_existing_users
}

refresh_desktop_database() {
  step "Refreshing desktop database"
  update-desktop-database /usr/local/share/applications >/dev/null 2>&1 || true
}

main() {
  require_root
  require_amd64

  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "22.04" ]; then
    log "Warning: this script was written for Ubuntu 22.04; continuing anyway."
  fi

  install_base_dependencies
  install_chrome
  configure_chrome_launchers
  install_vscode
  configure_vscode_launcher
  refresh_desktop_database

  log "Done"
  log "Chrome Lite, Chrome Ultra Lite, and VS Code Lite are now available from the application menu."
}

main "$@"
