#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# fix-xrdp-gnome-keyring.sh
#
# 目标：
#   1) 修复 Ubuntu 22.04 + GNOME + XRDP 下频繁出现的
#      "Authentication required / Default keyring is locked" 提示
#   2) 对所有通过 XRDP 登录的用户生效
#   3) 对未来新建用户也生效
#
# 原理：
#   - 在 /etc/pam.d/xrdp-sesman 中加入 pam_gnome_keyring.so
#   - 使用 auto_start 让 keyring 在登录时自动解锁
#   - 移除 any only_if=... 限制，避免只对 gdm/xdm 生效
#
# 适用：
#   - Ubuntu 22.04
#   - XRDP + GNOME
#
# 运行：
#   sudo bash fix-xrdp-gnome-keyring.sh
###############################################################################

TARGET_FILES=(
  "/etc/pam.d/xrdp-sesman"
)

BACKUP_ROOT="/var/backups/xrdp-gnome-keyring"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"

mkdir -p "$BACKUP_DIR"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 执行：sudo bash $0" >&2
    exit 1
  fi
}

backup_files() {
  for f in "${TARGET_FILES[@]}"; do
    if [[ -f "$f" ]]; then
      cp -a "$f" "${BACKUP_DIR}/$(basename "$f")"
    fi
  done
}

restore_on_error() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo
    echo "发生错误，正在回滚备份..."
    for f in "${TARGET_FILES[@]}"; do
      local b="${BACKUP_DIR}/$(basename "$f")"
      if [[ -f "$b" ]]; then
        cp -a "$b" "$f"
      fi
    done
    echo "回滚完成，备份保存在：$BACKUP_DIR"
  fi
  exit $rc
}

install_packages() {
  if ! dpkg -s libpam-gnome-keyring >/dev/null 2>&1; then
    echo "检测到 libpam-gnome-keyring 未安装，正在安装..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libpam-gnome-keyring gnome-keyring
  fi
}

patch_pam_file() {
  local file="$1"

  [[ -f "$file" ]] || return 0

  python3 - "$file" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="ignore")

original = text
text = text.replace("\r\n", "\n")

# 先删除所有旧的 gnome-keyring 行，避免重复或 only_if 限制残留
text = re.sub(r'(?m)^\s*auth\s+.*pam_gnome_keyring\.so.*\n?', '', text)
text = re.sub(r'(?m)^\s*session\s+.*pam_gnome_keyring\.so.*\n?', '', text)

def ensure_after_anchor(src: str, anchors, line: str) -> str:
    if line in src:
        return src
    for pat in anchors:
        m = re.search(pat, src, flags=re.M)
        if m:
            return src[:m.end()] + "\n" + line + src[m.end():]
    return src.rstrip("\n") + "\n" + line + "\n"

# 在 xrdp-sesman 的 auth/session 阶段分别注入
text = ensure_after_anchor(
    text,
    [
        r'^\s*@include\s+common-auth\s*$',
        r'^\s*auth\s+required\s+pam_unix\.so\s*$',
        r'^\s*auth\s+include\s+common-auth\s*$',
    ],
    'auth optional pam_gnome_keyring.so auto_start'
)

text = ensure_after_anchor(
    text,
    [
        r'^\s*@include\s+common-session\s*$',
        r'^\s*session\s+include\s+login\s*$',
        r'^\s*session\s+required\s+pam_unix\.so\s*$',
    ],
    'session optional pam_gnome_keyring.so auto_start'
)

if text != original:
    path.write_text(text, encoding="utf-8")
PY
}

restart_services() {
  echo "重启 XRDP 服务..."
  systemctl restart xrdp-sesman.service 2>/dev/null || true
  systemctl restart xrdp.service 2>/dev/null || true
}

show_result() {
  echo
  echo "已完成。当前备份目录：$BACKUP_DIR"
  echo
  echo "当前 xrdp-sesman 中的 gnome-keyring 相关行："
  grep -n "pam_gnome_keyring\.so" /etc/pam.d/xrdp-sesman || true
  echo
  echo "请重新发起一次 RDP 登录测试。"
}

need_root
trap restore_on_error EXIT

backup_files
install_packages
patch_pam_file "/etc/pam.d/xrdp-sesman"
restart_services
show_result

trap - EXIT
exit 0
