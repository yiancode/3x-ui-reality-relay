#!/usr/bin/env bash
# setup-relay.sh — 在中转 VPS（如 DMIT / 搬瓦工 CN2 GIA）上配置链式中转
#
# 原理：客户端连本机的 VLESS+TCP+REALITY 入口 → 流量经出口转发到住宅节点。
# 你只需把住宅节点的 vless:// 分享链接（3x-ui「复制节点链接」给出的）交给脚本。
#
# 用法：
#   sudo bash setup-relay.sh 'vless://....#住宅节点'
#   sudo bash setup-relay.sh            # 不带参数则交互粘贴
#   sudo ENTRY_PORT=443 bash setup-relay.sh 'vless://...'
#
# 仅支持 Debian / Ubuntu，需 root。完成后打印中转节点链接与面板信息。
set -euo pipefail

# ===== 可配置变量 =====
PANEL_PORT="${PANEL_PORT:-2053}"
PANEL_USER="${PANEL_USER:-admin}"
PANEL_PASS="${PANEL_PASS:-}"
PANEL_PATH="${PANEL_PATH:-}"
ENTRY_PORT="${ENTRY_PORT:-443}"                 # 本机入口端口（客户端连这里）
ENTRY_TAG="${ENTRY_TAG:-inbound-relay-in}"      # 本机入口 tag，路由规则引用它
ENTRY_SNI="${ENTRY_SNI:-www.microsoft.com}"     # 本机入口伪装域名
ENTRY_DEST="${ENTRY_DEST:-${ENTRY_SNI}:443}"
ENTRY_REMARK="${ENTRY_REMARK:-relay-$(hostname -s 2>/dev/null || echo node)}"
ENTRY_EMAIL="${ENTRY_EMAIL:-relay-$(openssl rand -hex 3)}"
OUT_TAG="${OUT_TAG:-relay-out}"                 # 出口 tag

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  grep -E '^#( |$)' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

# 极简 URL 解码（够用于 spx 等字段）
urldecode() { printf '%b' "${1//%/\\x}"; }

# 解析住宅 vless:// 链接，填充全局：
#   UP_UUID UP_HOST UP_PORT UP_PBK UP_SID UP_SNI UP_FP UP_FLOW UP_SPX UP_NET
parse_vless_link() {
  local link="$1"
  case "$link" in
    vless://*) ;;
    *) die "链接必须以 vless:// 开头" ;;
  esac
  link="${link#vless://}"
  link="${link%%#*}"                 # 去掉 #备注
  local userinfo hostport query authority
  authority="${link%%\?*}"           # UUID@HOST:PORT
  query="${link#*\?}"; [ "$query" = "$link" ] && query=""   # ?后查询串
  userinfo="${authority%%@*}"        # UUID
  hostport="${authority#*@}"         # HOST:PORT
  UP_UUID="$userinfo"
  UP_HOST="${hostport%:*}"
  UP_PORT="${hostport##*:}"
  [ -n "$UP_UUID" ] && [ -n "$UP_HOST" ] && [ -n "$UP_PORT" ] || die "无法解析 UUID@HOST:PORT"

  # 解析查询参数
  UP_PBK=""; UP_SID=""; UP_SNI=""; UP_FP="chrome"; UP_FLOW=""; UP_SPX="/"; UP_NET="tcp"
  local kv k v
  local IFS='&'
  for kv in $query; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      pbk)      UP_PBK="$(urldecode "$v")" ;;
      sid)      UP_SID="$(urldecode "$v")" ;;
      sni)      UP_SNI="$(urldecode "$v")" ;;
      fp)       UP_FP="$(urldecode "$v")" ;;
      flow)     UP_FLOW="$(urldecode "$v")" ;;
      spx)      UP_SPX="$(urldecode "$v")" ;;
      type)     UP_NET="$(urldecode "$v")" ;;
    esac
  done
  [ -n "$UP_PBK" ] || die "链接缺少 pbk（REALITY 公钥）"
  [ -n "$UP_SNI" ] || c_warn "链接缺少 sni，REALITY 可能无法握手"
}

# 构建出口（xray-core 出站 REALITY 用单数字段）
build_outbound() {
  local users flow_part
  if [ -n "$UP_FLOW" ]; then
    users="$(jq -cn --arg id "$UP_UUID" --arg flow "$UP_FLOW" \
      '{id:$id,encryption:"none",flow:$flow}')"
  else
    users="$(jq -cn --arg id "$UP_UUID" '{id:$id,encryption:"none"}')"
  fi
  flow_part=""  # 占位，避免未使用告警
  : "$flow_part"
  jq -cn \
    --arg tag "$OUT_TAG" --arg addr "$UP_HOST" --argjson port "$UP_PORT" \
    --argjson user "$users" --arg net "$UP_NET" \
    --arg fp "$UP_FP" --arg sni "$UP_SNI" --arg pbk "$UP_PBK" \
    --arg sid "$UP_SID" --arg spx "$UP_SPX" \
    '{tag:$tag,protocol:"vless",
      settings:{vnext:[{address:$addr,port:$port,users:[$user]}]},
      streamSettings:{network:$net,security:"reality",
        realitySettings:{show:false,fingerprint:$fp,serverName:$sni,
          publicKey:$pbk,shortId:$sid,spiderX:$spx}}}'
}

# 把出口 + 路由规则注入 xray 模板（去重，保持 direct 为默认出口）
inject_relay() {
  local outbound rule tmpl new
  outbound="$(build_outbound)"
  rule="$(jq -cn --arg in "$ENTRY_TAG" --arg out "$OUT_TAG" \
    '{type:"field",inboundTag:[$in],outboundTag:$out}')"
  tmpl="$(read_xray_template)"
  [ -n "$tmpl" ] || die "读取 xrayTemplateConfig 为空"
  echo "$tmpl" | jq -e . >/dev/null 2>&1 || die "现有 xray 模板不是合法 JSON"
  new="$(echo "$tmpl" | jq \
    --argjson ob "$outbound" --argjson rule "$rule" --arg out "$OUT_TAG" '
      .outbounds = ((.outbounds // [] | map(select(.tag != $out))) + [$ob])
      | .routing.domainStrategy = (.routing.domainStrategy // "AsIs")
      | .routing.rules = ([$rule] + ((.routing.rules // []) | map(select(.outboundTag != $out))))
    ')"
  echo "$new" | jq -e . >/dev/null 2>&1 || die "注入后模板非法 JSON，已中止"
  write_xray_template "$new"
  c_ok "已注入出口 $OUT_TAG 与路由规则（$ENTRY_TAG → $OUT_TAG）"
}

main() {
  require_root
  detect_os
  c_info "架构：$(detect_arch)"

  # 取得住宅链接
  local link="${1:-}"
  if [ -z "$link" ]; then
    printf '请粘贴住宅节点的 vless:// 分享链接，然后回车：\n'
    read -r link
  fi
  parse_vless_link "$link"
  c_ok "住宅出口：$UP_HOST:$UP_PORT  sni=$UP_SNI  flow=${UP_FLOW:-无}"

  install_deps
  install_3xui_if_absent

  [ -n "$PANEL_PASS" ] || PANEL_PASS="$(gen_password)"
  [ -n "$PANEL_PATH" ] || PANEL_PATH="$(gen_basepath_hex)"
  local base; base="$(normalize_base "$PANEL_PATH")"
  apply_panel_settings "$PANEL_PORT" "$PANEL_USER" "$PANEL_PASS" "$base"
  wait_panel_ready "$PANEL_PORT" "$base"
  get_api_token

  # 1) 建本机入口（客户端连这里），自己的新 REALITY 密钥
  local euuid esid
  euuid="$(gen_uuid)"; esid="$(gen_shortid)"
  gen_reality_keys   # → REALITY_PRIVATE_KEY / REALITY_PUBLIC_KEY
  c_info "创建本机入口（port=$ENTRY_PORT, tag=$ENTRY_TAG）..."
  local payload resp
  payload="$(build_reality_inbound "$ENTRY_REMARK" "$ENTRY_PORT" "$ENTRY_TAG" "$ENTRY_EMAIL" \
    "$euuid" "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY" "$esid" "$ENTRY_SNI" "$ENTRY_DEST")"
  resp="$(api_post "$PANEL_PORT" "$base" "inbounds/add" "$payload")"
  echo "$resp" | jq -e '.success == true' >/dev/null 2>&1 \
    || { c_err "创建入口失败，响应：$resp"; die "请检查：journalctl -u x-ui -n 50"; }
  c_ok "本机入口创建成功"

  # 2) 注入出口 + 路由 → 重启 xray
  inject_relay
  systemctl restart x-ui >/dev/null 2>&1 || die "重启 x-ui 失败"
  c_ok "已重启 x-ui，中转生效"

  # 3) 输出中转节点链接（指向本机）
  PUBLIC_IP="$(public_ip)"; [ -n "$PUBLIC_IP" ] || PUBLIC_IP="<中转服务器IP>"
  local link_out
  link_out="$(build_vless_link "$PUBLIC_IP" "$ENTRY_PORT" "$euuid" "$REALITY_PUBLIC_KEY" "$esid" "$ENTRY_SNI" "$ENTRY_REMARK")"

  print_panel_summary "$PUBLIC_IP" "$PANEL_PORT" "$base" "$PANEL_USER" "$PANEL_PASS"
  echo
  echo "============ 中转节点（连这个，落地=住宅IP）============"
  echo "  $link_out"
  echo "======================================================="
  if command -v qrencode >/dev/null 2>&1; then
    echo; qrencode -t ansiutf8 "$link_out"
  else
    c_warn "未安装 qrencode，跳过二维码（apt install -y qrencode 可启用）"
  fi
}

# 仅在直接执行时运行 main；被 source 时不触发（便于测试/复用）
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
