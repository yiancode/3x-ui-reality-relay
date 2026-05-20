# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-05-20

3x-ui-reality-relay 首次公开发布。把 3x-ui 的网页面板手点流程脚本化为「一条命令」。

### Added

- `bootstrap.sh` — 一条命令入口：非 root 时 `sudo -E` 自我重执行（透传环境变量），
  默认走安装；支持 `relay` 子命令；`vless://` 链接可直接作为 relay 参数。
- `setup-reality.sh` — 安装 3x-ui 并创建一个 VLESS+TCP+REALITY 入口，
  结束打印面板登录信息与节点 `vless://` 分享链接。
- `setup-relay.sh` — 解析住宅 `vless://` 链接 → 建本机 REALITY 入口 →
  向 `xrayTemplateConfig` 注入 VLESS 出口与「入口 tag → 出口 tag」路由规则
  （幂等、保持 `direct` 为默认出口）→ 重启 x-ui。
- `lib.sh` — 两个安装脚本共用的函数库（环境检查、依赖安装、3x-ui 安装、
  面板设置、API Token、REALITY 密钥/UUID/shortId 生成、xray 模板读写、
  `vless://` 链接构建）。
- `print-quickstart.sh` — git-only 一键引导命令生成器，支持 reality / relay 两种模式。
- `README.md`、`LICENSE`（MIT）、`.gitignore`。

### 关键实现

- 凭据非交互写入：`x-ui setting -username U -password P -port N -webBasePath /PATH/`。
- 脚本鉴权用 Bearer Token（`x-ui setting -getApiToken true`，绕过 v3 的 CSRF），
  调 `{base}panel/api/inbounds/add` 创建入口。
- 全新安装面板默认走 http（无 SSL），脚本会探测 http/https。
- REALITY 密钥：`/usr/local/x-ui/bin/xray-linux-<arch> x25519`；
  UUID：`/proc/sys/kernel/random/uuid`；shortId：`openssl rand -hex 8`。
- 出口/路由无专用 API，存于 `settings` 表 `xrayTemplateConfig`
  （`/etc/x-ui/x-ui.db`），需读改写整份模板再重启。
- REALITY 字段差异：入口用复数 `serverNames`/`shortIds` + `privateKey`；
  出口用单数 `serverName`/`shortId` + `publicKey`。
- 默认 `flow=xtls-rprx-vision`，伪装域名默认 `www.microsoft.com`。

### 兼容性

- 仅支持 Debian / Ubuntu，需 root。
- 已对照 3x-ui `master`（v3.0.2）源码核实 API 路径、`x-ui setting` CLI 子命令与
  DB 字段名。其它分支/旧版本可能有差异。
