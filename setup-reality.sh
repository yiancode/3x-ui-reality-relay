#!/usr/bin/env bash
# setup-reality.sh — 新建 VPS 一键安装 3x-ui 并创建 VLESS + TCP + REALITY 节点
#
# 用法：
#   sudo bash setup-reality.sh
#   sudo PANEL_PORT=2053 NODE_PORT=443 REALITY_SNI=www.microsoft.com bash setup-reality.sh
#
# 仅支持 Debian / Ubuntu，需 root。完成后打印面板登录信息与节点分享链接。
set -euo pipefail

# ===== 可配置变量（环境变量可覆盖）=====
PANEL_PORT="${PANEL_PORT:-2053}"          # 面板端口
PANEL_USER="${PANEL_USER:-admin}"         # 面板用户名
PANEL_PASS="${PANEL_PASS:-}"              # 面板密码（留空=随机生成）
PANEL_PATH="${PANEL_PATH:-}"              # 面板路径（留空=随机 hex）
NODE_PORT="${NODE_PORT:-443}"             # 节点监听端口
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"        # 伪装域名（SNI）
REALITY_DEST="${REALITY_DEST:-${REALITY_SNI}:443}"      # 回落目标
NODE_REMARK="${NODE_REMARK:-reality-$(hostname -s 2>/dev/null || echo node)}"
NODE_TAG="${NODE_TAG:-inbound-reality}"
NODE_EMAIL="${NODE_EMAIL:-user-$(openssl rand -hex 3)}"

# ===== 引入共享库 =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  grep -E '^#( |$)' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

main() {
  require_root
  detect_os
  c_info "架构：$(detect_arch)"
  install_deps
  install_3xui_if_absent

  # 凭据补全
  [ -n "$PANEL_PASS" ] || PANEL_PASS="$(gen_password)"
  [ -n "$PANEL_PATH" ] || PANEL_PATH="$(gen_basepath_hex)"
  local base; base="$(normalize_base "$PANEL_PATH")"

  apply_panel_settings "$PANEL_PORT" "$PANEL_USER" "$PANEL_PASS" "$base"
  wait_panel_ready "$PANEL_PORT" "$base"
  get_api_token

  # 生成节点参数
  local uuid sid
  uuid="$(gen_uuid)"
  sid="$(gen_shortid)"
  gen_reality_keys   # → REALITY_PRIVATE_KEY / REALITY_PUBLIC_KEY

  c_info "创建 VLESS + TCP + REALITY 入口（port=$NODE_PORT, tag=$NODE_TAG）..."
  local payload resp
  payload="$(build_reality_inbound "$NODE_REMARK" "$NODE_PORT" "$NODE_TAG" "$NODE_EMAIL" \
    "$uuid" "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY" "$sid" "$REALITY_SNI" "$REALITY_DEST")"
  resp="$(api_post "$PANEL_PORT" "$base" "inbounds/add" "$payload")"
  if ! echo "$resp" | jq -e '.success == true' >/dev/null 2>&1; then
    c_err "创建入口失败，响应：$resp"
    die "请检查面板日志：journalctl -u x-ui -n 50"
  fi
  c_ok "入口创建成功"

  PUBLIC_IP="$(public_ip)"; [ -n "$PUBLIC_IP" ] || PUBLIC_IP="<你的服务器IP>"
  local link
  link="$(build_vless_link "$PUBLIC_IP" "$NODE_PORT" "$uuid" "$REALITY_PUBLIC_KEY" "$sid" "$REALITY_SNI" "$NODE_REMARK")"

  print_panel_summary "$PUBLIC_IP" "$PANEL_PORT" "$base" "$PANEL_USER" "$PANEL_PASS"
  echo
  echo "============ VLESS + TCP + REALITY 节点 ============"
  echo "  $link"
  echo "===================================================="
  if command -v qrencode >/dev/null 2>&1; then
    echo; qrencode -t ansiutf8 "$link"
  else
    c_warn "未安装 qrencode，跳过二维码（apt install -y qrencode 可启用）"
  fi
}

# 仅在直接执行时运行 main；被 source 时不触发（便于测试/复用）
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
