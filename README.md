# 3x-ui Reality OneKey

面向全新 Debian/Ubuntu VPS 的一键部署脚本。目标是把以下组件一次配置完成，并尽量在修改系统前做前置检查：

- 3x-ui v3.8.5（默认锁定已验证版本，使用该版本官方安装器）
- VLESS + REALITY + XTLS-Vision，公网 TCP 443
- 正常可访问的 HTTPS 静态网站
- 3x-ui HTTPS 面板（独立子域名）
- Nginx 本机 TLS 后端 + Certbot 自动续期
- UFW 防火墙
- Fail2ban SSH 防护
- 安装完成后的服务、API、端口和 HTTPS 自检

## 设计结构

```text
Internet :443
    |
    v
Xray / VLESS + REALITY + Vision
    |-- 正确 Reality 客户端 -> 节点
    `-- 普通 TLS 请求 -> 127.0.0.1:8443 (Nginx TLS)
                         |-- example.com       -> 普通静态网页
                         `-- panel.example.com -> 127.0.0.1:<3x-ui随机端口>

Internet :80 -> Nginx -> ACME HTTP-01 / HTTPS 重定向
```

3x-ui 面板会被脚本改成只监听 `127.0.0.1`，随机用户名、密码、端口、Web Base Path 和 API Token 均由 3x-ui 官方无人值守安装器生成。

## 安装前准备

建议使用干净的 Debian 12/13 或 Ubuntu 22.04/24.04 VPS。安装器当前只支持 Debian/Ubuntu，并且会主动拒绝接管已有 x-ui/3x-ui。

准备两个 DNS A 记录并指向 VPS 公网 IPv4。若使用 Cloudflare，请安装期间保持 **DNS only（灰云）**；若存在 AAAA 记录，也必须与该 VPS 的公网 IPv6 一致：

```text
example.com       -> VPS_IP
panel.example.com -> VPS_IP
```

端口 80、443 需要从公网可达。若 80/443 已被其他服务占用，脚本会在安装前退出，不会强行杀进程。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/install.sh)
```

安装过程中只需要输入：

1. 普通网站域名
2. 面板域名（默认 `panel.普通网站域名`）
3. Let's Encrypt 邮箱（可留空）

也支持环境变量预填：

```bash
SITE_DOMAIN=example.com \
PANEL_DOMAIN=panel.example.com \
ACME_EMAIL=you@example.com \
bash <(curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/install.sh)
```

## 管理命令

```bash
onekey-status
onekey-status --show-secrets
onekey-update
onekey-uninstall
```

敏感结果只写入 VPS 本地 root 可读文件：

```text
/etc/x-ui/install-result.env
/etc/3x-ui-reality-onekey/secrets.env
```

GitHub 仓库不保存你的 UUID、Reality 私钥、面板密码或 API Token。

## 安全和稳定性策略

- 不覆盖已有 3x-ui/x-ui。
- 安装前检查域名 DNS 与 VPS 公网 IPv4 是否一致。
- 安装前检查 80/443/8443 端口占用。
- 首次安装默认锁定到已验证的 `3x-ui v3.8.5`，避免上游突然改变 API/字段导致脚本漂移；高级用户可用 `XUI_VERSION=vX.Y.Z` 显式覆盖。
- Reality X25519 密钥与 UUID 通过当前 3x-ui API 生成。
- 面板只监听 127.0.0.1，不直接暴露随机管理端口。
- UFW 启用前自动识别当前 SSH 端口并先放行；不会 `ufw reset`，不会清空服务器已有规则。
- Certbot 使用 webroot HTTP-01，不需要停止 Nginx续期。
- 更新前自动备份 3x-ui SQLite 数据库和本项目状态。
- 卸载前再做一次压缩备份，并默认保留系统级 Nginx/Certbot/UFW/Fail2ban 包。

## 说明

本项目目前以**全新 VPS**为主要使用场景。对于已经运行网站、Nginx/Caddy、Docker 网关或已有 x-ui/3x-ui 的服务器，不建议直接执行本安装器。

## 指定 3x-ui 版本（高级）

默认使用本项目已验证的 `v3.8.5`。只有在你明确知道新版本兼容时才建议覆盖：

```bash
XUI_VERSION=v3.8.5 SITE_DOMAIN=example.com PANEL_DOMAIN=panel.example.com \
  bash <(curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/install.sh)
```
