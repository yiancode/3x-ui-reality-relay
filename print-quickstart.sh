#!/usr/bin/env bash
# print-quickstart.sh — 生成 README 里那条 git-only 一键引导命令
#
# 维护者辅助脚本：仓库 URL / 路径 / 入口变化时，用它重新生成一键命令，
# 避免手抄 README 抄错。
#
# 用法：
#   ./print-quickstart.sh                      # 落地/住宅：安装 3x-ui + 建 REALITY 节点
#   ./print-quickstart.sh relay                # 中转：链接处留占位符
#   ./print-quickstart.sh relay 'vless://...'  # 中转：填入真实住宅链接
#
# 不依赖 root，纯打印，不执行任何安装动作。
set -euo pipefail

REMOTE_URL="https://github.com/yiancode/3x-ui-reality-relay.git"
REPO_DIR='${HOME}/.3x-ui-reality-relay'

usage() {
  grep -E '^#( |$)' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

MODE="reality"
LINK=""
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  reality)   MODE="reality" ;;
  relay)     MODE="relay"; LINK="${2:-vless://....#住宅节点}" ;;
  "")        MODE="reality" ;;
  *)         echo "[x] 未知参数：$1" >&2; usage; exit 1 ;;
esac

# 末行：调用 bootstrap.sh，relay 模式追加子命令与链接
if [ "$MODE" = "relay" ]; then
  TAIL="bash \"\$REPO_DIR/bootstrap.sh\" relay '${LINK}'"
else
  TAIL="bash \"\$REPO_DIR/bootstrap.sh\""
fi

cat <<EOF
REPO_DIR="${REPO_DIR}" && \\
([ -d "\$REPO_DIR/.git" ] && git -C "\$REPO_DIR" fetch --depth=1 origin main && git -C "\$REPO_DIR" reset --hard origin/main || git clone --depth=1 ${REMOTE_URL} "\$REPO_DIR") && \\
${TAIL}
EOF
