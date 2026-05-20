#!/usr/bin/env bash
# bootstrap.sh — 一条命令入口：自动 root、分发到安装或中转脚本
#
# 用法：
#   bash bootstrap.sh                      # 默认：安装 3x-ui + 建 REALITY 节点
#   bash bootstrap.sh reality              # 同上（显式）
#   bash bootstrap.sh relay 'vless://...'  # 中转：传入住宅节点分享链接
#   bash bootstrap.sh 'vless://...'        # 容错：直接贴链接也当作中转
#
# 环境变量（如 PANEL_PORT / NODE_PORT / REALITY_SNI 等）会通过 sudo -E 透传。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --help 不需要 root，优先处理
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# 非 root 时用 sudo -E 重新执行自身（保留环境变量）
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$ROOT_DIR/bootstrap.sh" "$@"
  fi
  echo "[x] 需要 root 权限，且未找到 sudo。请切到 root 后重试。" >&2
  exit 1
fi

MODE="reality"
case "${1:-}" in
  reality)   MODE="reality"; shift ;;
  relay)     MODE="relay";   shift ;;
  vless://*) MODE="relay" ;;          # 不 shift，链接作为参数传下去
  "")        MODE="reality" ;;
  *) echo "[x] 未知参数：$1" >&2; usage; exit 1 ;;
esac

case "$MODE" in
  reality) exec bash "$ROOT_DIR/setup-reality.sh" "$@" ;;
  relay)   exec bash "$ROOT_DIR/setup-relay.sh" "$@" ;;
esac
