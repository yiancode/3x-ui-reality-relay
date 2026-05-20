#!/usr/bin/env bash
# lib.sh — 3x-ui 自动化脚本共享函数库
# 被 setup-reality.sh / setup-relay.sh 通过 `source` 引入。
# 仅支持 Debian / Ubuntu，需 root 运行。

# ---- 全局常量 ----
XUI_BIN="/usr/local/x-ui/x-ui"
XUI_DB="/etc/x-ui/x-ui.db"
XUI_BIN_DIR="/usr/local/x-ui/bin"
INSTALL_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"

# 运行期填充的全局变量
PANEL_SCHEME="http"   # 默认面板走 http（全新安装无 SSL 证书）
API_TOKEN=""
PUBLIC_IP=""

# ---- 输出辅助 ----
c_info()  { printf '\033[36m[*]\033[0m %s\n' "$*"; }
c_ok()    { printf '\033[32m[✓]\033[0m %s\n' "$*"; }
c_warn()  { printf '\033[33m[!]\033[0m %s\n' "$*"; }
c_err()   { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; }
die()     { c_err "$*"; exit 1; }

# ---- 环境检查 ----
require_root() {
  [ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo -i 后再执行）"
}

detect_os() {
  [ -f /etc/os-release ] || die "无法识别系统（缺少 /etc/os-release），仅支持 Debian/Ubuntu"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) c_info "系统：${PRETTY_NAME:-$ID}" ;;
    *) die "仅支持 Debian/Ubuntu，当前：${PRETTY_NAME:-$ID}" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *)             uname -m ;;
  esac
}

# ---- 依赖安装 ----
install_deps() {
  c_info "安装依赖 curl/sqlite3/jq/openssl ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || apt update -y
  apt-get install -y curl sqlite3 jq openssl ca-certificates >/dev/null 2>&1 \
    || apt-get install -y curl sqlite3 jq openssl ca-certificates \
    || die "依赖安装失败"
  c_ok "依赖就绪"
}

# ---- 3x-ui 安装 ----
is_3xui_installed() { [ -x "$XUI_BIN" ]; }

install_3xui_if_absent() {
  if is_3xui_installed; then
    c_ok "检测到已安装的 3x-ui，跳过安装"
    return 0
  fi
  c_info "下载并安装 3x-ui（官方脚本，自定义端口处自动选 n，稍后用 CLI 覆盖）..."
  # 官方脚本装完会交互询问是否自定义端口，喂多个 n 走随机端口；随后我们用 CLI 覆盖
  printf 'n\nn\nn\n' | bash <(curl -Ls "$INSTALL_URL") || die "3x-ui 安装失败"
  is_3xui_installed || die "安装后未找到 $XUI_BIN"
  c_ok "3x-ui 安装完成"
}

# ---- 面板设置（端口/用户名/密码/路径）----
# 用法：apply_panel_settings PORT USER PASS BASEPATH(带前后斜杠)
apply_panel_settings() {
  local port="$1" user="$2" pass="$3" base="$4"
  c_info "应用面板设置：port=$port user=$user webBasePath=$base"
  "$XUI_BIN" setting -port "$port" -username "$user" -password "$pass" -webBasePath "$base" >/dev/null \
    || die "x-ui setting 写入失败"
  systemctl restart x-ui >/dev/null 2>&1 || die "重启 x-ui 失败"
  c_ok "面板设置已写入并重启"
}

# 规范化 webBasePath：保证前后都有斜杠
normalize_base() {
  local b="$1"
  [ -z "$b" ] && b="/"
  [ "${b#/}" = "$b" ] && b="/$b"      # 补前导斜杠
  [ "${b%/}" = "$b" ] && b="$b/"      # 补尾部斜杠
  echo "$b"
}

# ---- API Token（绕过 CSRF，最稳的脚本鉴权）----
get_api_token() {
  API_TOKEN="$("$XUI_BIN" setting -getApiToken true 2>/dev/null | grep -Eo 'apiToken: .+' | awk '{print $2}')"
  [ -n "$API_TOKEN" ] || die "获取 API Token 失败"
  c_ok "已获取 API Token"
}

# ---- 密钥 / UUID / shortId ----
xray_bin() {
  # 直接 glob 实际二进制，避免 arch 命名差异
  local b
  for b in "$XUI_BIN_DIR"/xray-linux-*; do
    [ -x "$b" ] && { echo "$b"; return 0; }
  done
  return 1
}

# 生成 REALITY 密钥对 → REALITY_PRIVATE_KEY / REALITY_PUBLIC_KEY
gen_reality_keys() {
  local bin out
  bin="$(xray_bin)" || die "未找到 xray 二进制（$XUI_BIN_DIR/xray-linux-*）"
  out="$("$bin" x25519)" || die "生成 x25519 密钥失败"
  REALITY_PRIVATE_KEY="$(echo "$out" | grep -i 'private' | awk -F: '{print $2}' | tr -d ' ')"
  REALITY_PUBLIC_KEY="$(echo  "$out" | grep -i 'public'  | awk -F: '{print $2}' | tr -d ' ')"
  [ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || die "解析 x25519 输出失败"
}

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())'
  fi
}

gen_shortid() { openssl rand -hex 8; }

gen_password() { openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20; }

# 随机 webBasePath（无前后斜杠的 hex）
gen_basepath_hex() { openssl rand -hex 6; }

# ---- 公网 IP ----
public_ip() {
  local ip
  ip="$(curl -s --max-time 8 https://api.ipify.org)" \
    || ip="$(curl -s --max-time 8 https://ifconfig.me)" \
    || ip=""
  [ -n "$ip" ] || ip="$(curl -s --max-time 8 https://ipinfo.io/ip)"
  echo "$ip"
}

# ---- 面板就绪探测，确定 http/https ----
# 用法：wait_panel_ready PORT BASEPATH
wait_panel_ready() {
  local port="$1" base="$2" i scheme code
  c_info "等待面板端口 $port 就绪 ..."
  for i in $(seq 1 30); do
    for scheme in http https; do
      code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 4 "${scheme}://127.0.0.1:${port}${base}" 2>/dev/null)"
      if [ -n "$code" ] && [ "$code" != "000" ]; then
        PANEL_SCHEME="$scheme"
        c_ok "面板已就绪（${scheme}，HTTP $code）"
        return 0
      fi
    done
    sleep 1
  done
  die "等待面板就绪超时，请检查：journalctl -u x-ui -n 50"
}

# ---- API POST（Bearer 鉴权）----
# 用法：api_post PORT BASEPATH API_SUBPATH JSON  → 返回响应体
api_post() {
  local port="$1" base="$2" sub="$3" body="$4"
  curl -sk --max-time 15 \
    -X POST "${PANEL_SCHEME}://127.0.0.1:${port}${base}panel/api/${sub}" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d "$body"
}

# 读取 xray 模板配置（xrayTemplateConfig）
read_xray_template() {
  sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='xrayTemplateConfig';"
}

# 写回 xray 模板配置（参数为完整 JSON 字符串）
write_xray_template() {
  local json="$1" tmp
  tmp="$(mktemp)"
  printf '%s' "$json" > "$tmp"
  # 用参数化方式写入，避免引号转义问题
  sqlite3 "$XUI_DB" "UPDATE settings SET value=readfile('$tmp') WHERE key='xrayTemplateConfig';" \
    || { rm -f "$tmp"; die "写入 xrayTemplateConfig 失败"; }
  rm -f "$tmp"
}

# ---- VLESS REALITY 分享链接构建 ----
# 用法：build_vless_link IP PORT UUID PUBKEY SHORTID SNI REMARK
build_vless_link() {
  local ip="$1" port="$2" uuid="$3" pbk="$4" sid="$5" sni="$6" remark="$7"
  printf 'vless://%s@%s:%s?type=tcp&security=reality&encryption=none&pbk=%s&fp=chrome&sni=%s&sid=%s&spx=%%2F&flow=xtls-rprx-vision#%s' \
    "$uuid" "$ip" "$port" "$pbk" "$sni" "$sid" "$remark"
}

# ---- 构建 VLESS+TCP+REALITY 入口请求体 ----
# settings/streamSettings/sniffing 以 JSON 字符串内嵌（3x-ui 接受此形式）
# 用法：build_reality_inbound REMARK PORT TAG EMAIL UUID PRIV PUB SID SNI DEST
build_reality_inbound() {
  local remark="$1" port="$2" tag="$3" email="$4" uuid="$5" \
        priv="$6" pub="$7" sid="$8" sni="$9" dest="${10}"
  local settings stream sniffing
  settings="$(jq -cn --arg id "$uuid" --arg email "$email" \
    '{clients:[{id:$id,flow:"xtls-rprx-vision",email:$email,enable:true,limitIp:0,totalGB:0,expiryTime:0}],decryption:"none",fallbacks:[]}')"
  stream="$(jq -cn \
    --arg dest "$dest" --arg sni "$sni" \
    --arg priv "$priv" --arg pub "$pub" --arg sid "$sid" \
    '{network:"tcp",security:"reality",externalProxy:[],
      realitySettings:{show:false,xver:0,dest:$dest,target:$dest,serverNames:[$sni],
        privateKey:$priv,shortIds:[$sid],
        settings:{publicKey:$pub,fingerprint:"chrome",serverName:"",spiderX:"/"}},
      tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}}')"
  sniffing="$(jq -cn '{enabled:false,destOverride:["http","tls","quic","fakedns"]}')"
  jq -cn \
    --arg remark "$remark" --argjson port "$port" --arg tag "$tag" \
    --arg s "$settings" --arg ss "$stream" --arg sn "$sniffing" \
    '{remark:$remark,enable:true,listen:"",port:$port,protocol:"vless",
      expiryTime:0,total:0,tag:$tag,settings:$s,streamSettings:$ss,sniffing:$sn}'
}

# ---- 打印面板信息 ----
# 用法：print_panel_summary IP PORT BASEPATH USER PASS
print_panel_summary() {
  local ip="$1" port="$2" base="$3" user="$4" pass="$5"
  echo
  echo "============ 3x-ui 面板登录信息 ============"
  echo "  地址 : ${PANEL_SCHEME}://${ip}:${port}${base}"
  echo "  端口 : ${port}"
  echo "  路径 : ${base}"
  echo "  用户 : ${user}"
  echo "  密码 : ${pass}"
  echo "==========================================="
}
