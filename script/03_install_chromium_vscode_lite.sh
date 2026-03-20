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

log "Installing base dependencies"
apt-get update
apt-get install -y \
  curl \
  ca-certificates \
  gpg \
  software-properties-common \
  xdg-utils

# ✅ 统一创建目录（修复你遇到的问题）
install -d /usr/local/bin
install -d /usr/local/share/applications

# =========================================================
# ❌ 禁用 snap Chromium（彻底避免问题）
# =========================================================
log "Removing snap chromium (if exists)"
if command -v snap >/dev/null 2>&1; then
  snap remove chromium >/dev/null 2>&1 || true
fi

# =========================================================
# ✅ 安装 Chromium（非 snap）
# =========================================================
log "Installing Chromium (deb version via XtraDeb)"

curl -fsSL \
  https://launchpad.net/~xtradeb/+archive/ubuntu/apps/+files/xtradeb-apt-source_0.3_all.deb \
  -o /tmp/xtradeb.deb

apt-get install -y /tmp/xtradeb.deb
rm -f /tmp/xtradeb.deb

apt-get update
apt-get install -y chromium

# =========================================================
# 🚀 Chromium 极限低内存版本（核心）
# =========================================================
log "Creating Chromium EXTREME low-memory launcher"

cat >/usr/local/bin/chromium-lite <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

exec /usr/bin/chromium \
  --no-first-run \
  --no-default-browser-check \
  --disable-background-networking \
  --disable-background-timer-throttling \
  --disable-backgrounding-occluded-windows \
  --disable-breakpad \
  --disable-component-update \
  --disable-domain-reliability \
  --disable-extensions \
  --disable-features=Translate,BackForwardCache,MediaRouter,OptimizationHints \
  --disable-ipc-flooding-protection \
  --disable-renderer-backgrounding \
  --disable-sync \
  --disable-dev-shm-usage \
  --disable-gpu \
  --no-sandbox \
  --single-process \
  --process-per-site \
  --renderer-process-limit=2 \
  --memory-pressure-off \
  --max_old_space_size=128 \
  --js-flags="--max-old-space-size=64" \
  --disk-cache-size=33554432 \
  --media-cache-size=16777216 \
  --mute-audio \
  --no-zygote \
  --disable-software-rasterizer \
  "$@"
EOF

chmod 755 /usr/local/bin/chromium-lite

cat >/usr/local/share/applications/chromium-lite.desktop <<'EOF'
[Desktop Entry]
Name=Chromium Lite (Ultra Low Memory)
Exec=/usr/local/bin/chromium-lite %U
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF

# =========================================================
# ✅ 安装 VS Code
# =========================================================
log "Installing VS Code"

install -d /usr/share/keyrings

curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor \
  > /usr/share/keyrings/microsoft.gpg

ARCH=$(dpkg --print-architecture)

cat >/etc/apt/sources.list.d/vscode.list <<EOF
deb [arch=${ARCH} signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main
EOF

apt-get update
apt-get install -y code

# =========================================================
# 🧠 VS Code 低内存配置
# =========================================================
log "Optimizing VS Code memory usage"

if [[ -n "$TARGET_USER" && -n "$TARGET_HOME" ]]; then
  install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.config/Code/User"

  cat >"$TARGET_HOME/.config/Code/User/settings.json" <<'EOF'
{
  "telemetry.telemetryLevel": "off",
  "update.mode": "none",
  "extensions.autoUpdate": false,
  "extensions.autoCheckUpdates": false,
  "workbench.startupEditor": "none",
  "window.restoreWindows": "none",
  "editor.minimap.enabled": false,
  "files.hotExit": "off",
  "git.autofetch": false,
  "editor.renderWhitespace": "none",
  "editor.codeLens": false
}
EOF

  chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config/Code"
fi

# =========================================================
# 🚀 VS Code Lite 启动器
# =========================================================
cat >/usr/local/bin/code-lite <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/code \
  --disable-gpu \
  --disable-extensions \
  --max-memory=256 \
  "$@"
EOF

chmod 755 /usr/local/bin/code-lite

cat >/usr/local/share/applications/code-lite.desktop <<'EOF'
[Desktop Entry]
Name=VS Code Lite
Exec=/usr/local/bin/code-lite %F
Terminal=false
Type=Application
Categories=Development;IDE;
EOF

# =========================================================
log "DONE"
echo
echo "Run:"
echo "  chromium-lite   (极限低内存浏览器)"
echo "  code-lite       (低内存 VS Code)"
