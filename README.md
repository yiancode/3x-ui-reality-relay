# 3x-ui-reality-relay

新建 VPS 后一键安装 [3x-ui](https://github.com/MHSanaei/3x-ui) 并自动创建 **VLESS + TCP + REALITY** 节点；外加一个独立的**链式中转**脚本，把落地流量经中转 VPS 转发到住宅/落地节点。

全程脚本化，不用手点网页面板。仅支持 **Debian / Ubuntu**，需 root。

## 包含什么

| 脚本 | 作用 |
|------|------|
| `bootstrap.sh` | 一条命令入口：自动 `sudo` 提权并分发到下面的安装/中转脚本 |
| `setup-reality.sh` | 装 3x-ui + 建一个 VLESS+TCP+REALITY 入口，结束打印面板登录信息和 `vless://` 分享链接 |
| `setup-relay.sh` | 在中转 VPS 上建本地 REALITY 入口，并把出口链到住宅节点（粘贴住宅节点的 `vless://` 链接即可） |
| `lib.sh` | 两个脚本共用的函数库 |
| `print-quickstart.sh` | 维护者辅助：生成下文「只有 git 时的一条命令」，支持 reality / relay 两种模式 |

典型拓扑：

```
客户端 ──REALITY──> 中转VPS(setup-relay) ──REALITY──> 落地VPS(setup-reality) ──> 互联网
```

## 前置要求

- 一台 Debian / Ubuntu 服务器，root 权限
- 能访问 GitHub（脚本会拉取 3x-ui 官方安装脚本）
- 脚本会自动 `apt` 安装依赖：`curl` `sqlite3` `jq` `openssl`（`qrencode` 可选，用于打印二维码）

## 快速开始

### 0) 只有 git 时的一条命令

机器上几乎只有 `git`？落地 / 住宅 VPS 直接跑下面这一条，装好 3x-ui 并建好 REALITY 节点：

```bash
REPO_DIR="${HOME}/.3x-ui-reality-relay" && \
([ -d "$REPO_DIR/.git" ] && git -C "$REPO_DIR" fetch --depth=1 origin main && git -C "$REPO_DIR" reset --hard origin/main || git clone --depth=1 https://github.com/yiancode/3x-ui-reality-relay.git "$REPO_DIR") && \
bash "$REPO_DIR/bootstrap.sh"
```

这条命令会：拉取/更新最新代码 → 自动 `sudo` 提权 → 安装依赖 → 装 3x-ui → 建 VLESS+TCP+REALITY 节点 → 打印面板信息和节点 `vless://` 链接。

想在一条命令里自定义端口 / 伪装域名（环境变量经 `sudo -E` 透传）：

```bash
REPO_DIR="${HOME}/.3x-ui-reality-relay" && \
([ -d "$REPO_DIR/.git" ] && git -C "$REPO_DIR" fetch --depth=1 origin main && git -C "$REPO_DIR" reset --hard origin/main || git clone --depth=1 https://github.com/yiancode/3x-ui-reality-relay.git "$REPO_DIR") && \
PANEL_PORT=2053 NODE_PORT=443 REALITY_SNI=www.microsoft.com bash "$REPO_DIR/bootstrap.sh"
```

中转 VPS 一条命令（把住宅节点的 `vless://` 链接贴进去）：

```bash
REPO_DIR="${HOME}/.3x-ui-reality-relay" && \
([ -d "$REPO_DIR/.git" ] && git -C "$REPO_DIR" fetch --depth=1 origin main && git -C "$REPO_DIR" reset --hard origin/main || git clone --depth=1 https://github.com/yiancode/3x-ui-reality-relay.git "$REPO_DIR") && \
bash "$REPO_DIR/bootstrap.sh" relay 'vless://....#住宅节点'
```

### 1. 落地 / 住宅 VPS：安装 + 建节点（手动方式）

```bash
git clone https://github.com/yiancode/3x-ui-reality-relay.git
cd 3x-ui-reality-relay
sudo bash setup-reality.sh
```

跑完会打印面板地址/账号/密码，以及一条 `vless://` 节点链接，直接导入 v2rayN / Shadowrocket 等客户端即可。

想自定义端口或伪装域名：

```bash
sudo PANEL_PORT=2053 NODE_PORT=443 REALITY_SNI=www.microsoft.com bash setup-reality.sh
```

### 2. 中转 VPS：配置链式中转

把上一步（或你住宅节点）的 `vless://` 链接传进去：

```bash
sudo bash setup-relay.sh 'vless://....#住宅节点'
```

不带参数则会提示你粘贴链接。跑完打印一条**中转节点**的 `vless://`（指向中转 VPS），客户端连它，落地 IP 即为住宅 IP。

## 可配置环境变量

`setup-reality.sh`：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PANEL_PORT` | `2053` | 面板端口 |
| `PANEL_USER` | `admin` | 面板用户名 |
| `PANEL_PASS` | 随机生成 | 面板密码 |
| `PANEL_PATH` | 随机 hex | 面板访问路径 |
| `NODE_PORT` | `443` | 节点监听端口 |
| `REALITY_SNI` | `www.microsoft.com` | REALITY 伪装域名 |
| `REALITY_DEST` | `${REALITY_SNI}:443` | 回落目标 |
| `NODE_REMARK` | `reality-<主机名>` | 节点备注 |

`setup-relay.sh` 额外变量：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ENTRY_PORT` | `443` | 本机入口端口（客户端连这里） |
| `ENTRY_TAG` | `inbound-relay-in` | 入口 tag，路由规则引用 |
| `ENTRY_SNI` | `www.microsoft.com` | 本机入口伪装域名 |
| `OUT_TAG` | `relay-out` | 出口 tag |

## 工作原理

- 用 3x-ui 官方脚本安装，再用 `x-ui setting` 非交互写入固定端口/用户名 + 随机强密码。
- 通过 **API Token**（`x-ui setting -getApiToken`）调用 `panel/api/inbounds/add` 创建入口，绕过面板登录与 CSRF。
- REALITY 密钥用 `xray x25519` 现生成，UUID 取自 `/proc/sys/kernel/random/uuid`，shortId 用 `openssl rand`。
- 中转的出口与路由没有专用 API，脚本读取 `x-ui.db` 里的 `xrayTemplateConfig`，用 `jq` 注入一个 VLESS+REALITY 出口和一条「入口 tag → 出口 tag」的路由规则，写回后重启。注入是**幂等**的，并保持默认出口仍为 `direct`（只有中转入口的流量走住宅）。

> 安装版本钉定在 **v3.0.2**（`lib.sh` 的 `XUI_VERSION`，可用环境变量覆盖）。原因：v3.x 在 GitHub 上仍是 prerelease，官方 `install.sh` 不带参数只会装最新稳定版 v2.9.4，而 v2.9.4 没有 `x-ui setting -getApiToken`，本项目的 API Token 鉴权依赖它。已对照 v3.0.2 验证 API 路径、CLI 子命令与字段名。其它版本可能有差异。

## 排错

```bash
x-ui setting -show true            # 查看当前端口/路径
journalctl -u x-ui -n 50           # 看面板日志
sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='xrayTemplateConfig';"
```

- 面板连不上：确认安全组/防火墙放行了 `PANEL_PORT` 和 `NODE_PORT`。
- REALITY 握手失败：检查 `REALITY_SNI` 是否为支持 TLS1.3 且可正常访问的域名。
- 中转后落地 IP 不对：确认住宅 `vless://` 链接里的 `pbk`/`sni`/`flow` 完整。

## 安全提示

- 切勿在住宅 VPS 上搭建 Socks5 等不安全节点，容易被滥用或封号。
- 脚本生成的面板密码请妥善保存。

## 致谢

- [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui) — 底层面板
- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) — REALITY 协议实现

## License

[MIT](LICENSE)
