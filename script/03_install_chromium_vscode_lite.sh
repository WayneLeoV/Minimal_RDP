#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

log() {
  printf '\n[%s] %s\n' "$(date +'%F %T')" "$*"
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo or as root"
  exit 1
fi

. /etc/os-release
if [[ "${VERSION_CODENAME}" != "jammy" ]]; then
  echo "Only supports Ubuntu 22.04"
  exit 1
fi

# =========================================================
# Basic dependencies
# =========================================================
log "Preparing base directories"
install -d -m 0755 /usr/local/bin
install -d -m 0755 /usr/local/share/applications
install -d -m 0755 /usr/share/keyrings

log "Installing dependencies"
apt-get update
apt-get install -y curl ca-certificates gpg xdg-utils

# ========================================================================================================================
# Chromium (Not snap)
# ========================================================================================================================
log "Adding xtradeb repository"
curl -fsSL \
https://launchpad.net/~xtradeb/+archive/ubuntu/apps/+files/xtradeb-apt-source_0.3_all.deb \
-o /tmp/xtradeb.deb

apt-get install -y /tmp/xtradeb.deb
rm -f /tmp/xtradeb.deb

# Chromium
log "Installing Chromium (deb)"
apt-get update
apt-get install -y chromium

# =========================================================
# Chromium Lite (Globals)
# =========================================================
cat >/usr/local/bin/chromium-lite <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

USER_DATA_DIR="${HOME}/.config/chromium-lite"
mkdir -p "${USER_DATA_DIR}"

exec /usr/bin/chromium \
  --user-data-dir="${USER_DATA_DIR}" \
  --no-first-run \
  --no-default-browser-check \
  --disable-background-networking \
  --disable-component-update \
  --disable-default-apps \
  --disable-domain-reliability \
  --disable-extensions \
  --disable-features=Translate,BackForwardCache,MediaRouter \
  --disable-gpu \
  --disable-dev-shm-usage \
  --disable-sync \
  --enable-low-end-device-mode \
  --process-per-site \
  --renderer-process-limit=2 \
  --disk-cache-size=33554432 \
  --media-cache-size=16777216 \
  --mute-audio \
  --disable-renderer-backgrounding \
  --disable-software-rasterizer \
  --disable-breakpad \
  --disable-features=PaintHolding \
  "$@"
EOF

chmod 755 /usr/local/bin/chromium-lite

cat >/usr/local/share/applications/chromium-lite.desktop <<'EOF'
[Desktop Entry]
Name=Chromium Lite
Comment=Chromium with reduced memory usage
Exec=/usr/local/bin/chromium-lite %U
Type=Application
Categories=Network;WebBrowser;
EOF

# =========================================================
# Chromium Ultra Lite (Globals)
# =========================================================
cat >/usr/local/bin/chromium-ultra-lite <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Experimental only: keep this for further shrinking tests.
USER_DATA_DIR="${HOME}/.config/chromium-ultra-lite"
mkdir -p "${USER_DATA_DIR}"

exec /usr/bin/chromium \
  --user-data-dir="${USER_DATA_DIR}" \
  --no-first-run \
  --no-default-browser-check \
  --disable-background-networking \
  --disable-component-extensions-with-background-pages \
  --disable-component-update \
  --disable-default-apps \
  --disable-domain-reliability \
  --disable-extensions \
  --disable-features=Translate,BackForwardCache,MediaRouter,OptimizationHints \
  --disable-gpu \
  --disable-dev-shm-usage \
  --disable-renderer-accessibility \
  --disable-sync \
  --disable-speech-api \
  --enable-low-end-device-mode \
  --process-per-site \
  --renderer-process-limit=1 \
  --disk-cache-size=16777216 \
  --media-cache-size=8388608 \
  --mute-audio \
  --disable-renderer-backgrounding \
  --disable-software-rasterizer \
  --disable-breakpad \
  --disable-features=PaintHolding \
  "$@"
EOF
chmod 755 /usr/local/bin/chromium-ultra-lite

cat >/usr/local/share/applications/chromium-ultra-lite.desktop <<'EOF'
[Desktop Entry]
Name=Chromium Ultra Lite
Comment=Chromium with ULTRA reduced memory usage
Exec=/usr/local/bin/chromium-ultra-lite %U
Type=Application
Categories=Network;WebBrowser;
EOF


# ========================================================================================================================
# VS Code
# ========================================================================================================================
log "Installing VS Code"

curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor \
 > /usr/share/keyrings/microsoft.gpg
ARCH=$(dpkg --print-architecture)

cat >/etc/apt/sources.list.d/vscode.list <<EOF
deb [arch=${ARCH} signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main
EOF

apt-get update
apt-get install -y code

# =========================================================
# VS Code Lite (Global default)
# =========================================================
log "Configuring VS Code Lite (global)"

SKEL_DIR="/etc/skel/.config/Code-Lite/User"
install -d "$SKEL_DIR"

cat >"$SKEL_DIR/settings.json" <<'EOF'
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

# =========================================================
# Copy code's setting for other users
# =========================================================
log "Applying config to existing users"

for home in /home/*; do
  [[ -d "$home" ]] || continue

  install -d "$home/.config/Code-Lite/User"
  cp -f "$SKEL_DIR/settings.json" \
        "$home/.config/Code-Lite/User/settings.json"

  chown -R "$(basename "$home")":"$(basename "$home")" \
    "$home/.config/Code-Lite"
done

# =========================================================
# VS Code Lite Launcher (Global)
# =========================================================
cat >/usr/local/bin/code-lite <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

USER_DATA_DIR="${HOME}/.config/Code-Lite"
mkdir -p "${USER_DATA_DIR}"

exec /usr/bin/code \
  --user-data-dir="${USER_DATA_DIR}" \
  --extensions-dir="${USER_DATA_DIR}\extensions" \
  --disable-gpu \
  --disable-features=CalculateNativeWinOcclusion \
  "$@"
EOF

chmod 755 /usr/local/bin/code-lite

cat >/usr/local/share/applications/code-lite.desktop <<'EOF'
[Desktop Entry]
Name=VS Code Lite
Comment=Visual Studio Code with lower startup overhead
Exec=/usr/local/bin/code-lite %F
Type=Application
Categories=Development;
EOF

# =========================================================
# Install VS Code Extensions
# =========================================================

#log "Installing VS Code extensions (global)"

#EXT_DIR="/usr/share/code/extensions"

#EXTENSIONS=(
#  ms-vscode.cpptools
#  github.copilot
#  github.copilot-chat
#  VisualStudioExptTeam.vscodeintellicode
#  MS-CEINTL.vscode-language-pack-zh-hans
#  eamodio.gitlens
#)

#for ext in "${EXTENSIONS[@]}"; do
#  code \
#    --extensions-dir "$EXT_DIR" \
#    --install-extension "$ext" \
#    --force >/dev/null
#done

log "DONE"
echo
echo "Use:"
echo "  chromium-lite"
echo "  code-lite"
