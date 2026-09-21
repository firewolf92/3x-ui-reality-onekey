# 3x-ui Reality OneKey

面向干净 Debian/Ubuntu VPS 的一键部署脚本。

默认架构：

- 3x-ui
- VLESS + REALITY + XTLS-Vision
- HAProxy 作为公网 443 的 L4 SNI 分流层
- Caddy 提供正常 HTTPS 网站与 3x-ui 面板 HTTPS
- UFW 基础防火墙
- 随机面板用户名、密码、端口、Web Base Path、UUID、Reality 密钥和 Short ID

## 为什么使用 HAProxy + Caddy

同一台 VPS 上，REALITY 和正常 HTTPS 网站都希望使用公网 443。两者不能直接同时绑定 `0.0.0.0:443`。

本项目让 HAProxy 独占公网 443：

```text
Internet :443
    |
    +-- SNI = 你的站点域名 / 面板域名 --> Caddy :8443
    |
    +-- 其他 SNI（例如 Reality target） --> Xray :2443
```

这样浏览器访问你的域名时能看到正常 HTTPS 网站，而 REALITY 客户端仍通过公网 443 连接 Xray。

为降低“节点域名在代理启动前就被错误解析”的风险，脚本生成的 Reality 客户端链接默认直接使用 **VPS IPv4** 作为服务器地址；REALITY 的 `SNI` 仍然独立使用伪装目标域名。普通网站和面板继续使用你自己的域名。

## 当前支持

- Debian 12+
- Ubuntu 22.04 / 24.04+
- amd64 / arm64（取决于 3x-ui 官方支持）
- IPv4 VPS
- 域名 A 记录直连 VPS（首次部署时不能开启 Cloudflare 橙云代理）

> 第一版故意只支持“干净 VPS”。检测到已有 x-ui、Caddy、HAProxy，或 80/443 已被占用时会直接停止，避免覆盖已有服务。

## DNS 准备

部署前创建两条 A 记录：

```text
example.com        -> VPS IPv4
panel.example.com  -> VPS IPv4
```

如果 DNS 使用 Cloudflare，首次部署请设置为 **DNS only（灰云）**。

## 安装

SSH 登录 VPS 后，以 root 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/install.sh)
```

脚本会询问：

1. 正常网站域名
2. 3x-ui 面板域名
3. ACME 联系邮箱
4. Reality target / SNI（默认 `www.microsoft.com`）

随后自动完成安装、配置与自检。

## 无人值守模式

```bash
SITE_DOMAIN=example.com \
PANEL_DOMAIN=panel.example.com \
ACME_EMAIL=you@example.com \
REALITY_SNI=www.microsoft.com \
bash <(curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/install.sh)
```

## 安装后

查看状态：

```bash
onekey-status
```

查看本机保存的完整参数（仅 root 可读）：

```bash
cat /etc/3xui-onekey/config.env
cat /etc/3xui-onekey/client-link.txt
```

## 更新

```bash
onekey-update
```

更新前会自动备份 3x-ui 数据库和反代配置，然后调用 3x-ui 官方稳定版更新脚本。

## 卸载

```bash
onekey-uninstall
```

卸载会要求输入 `DELETE` 二次确认，并先备份 3x-ui 数据库。

## 端口设计

| 端口 | 对外 | 用途 |
|---|---|---|
| 80/tcp | 是 | ACME HTTP-01 与 HTTP→HTTPS |
| 443/tcp | 是 | HAProxy TLS SNI 分流 |
| 8443/tcp | 否 | Caddy 内部 TLS |
| 2443/tcp | 否 | Xray REALITY 内部监听 |
| 随机面板端口 | 否 | 3x-ui 面板，由 Caddy 反代 |

## 安全说明

- REALITY 入站本身不需要服务器自己的 TLS 证书。
- 普通网站和面板 HTTPS 证书由 Caddy 自动申请和续期。
- 管理面板真实端口不需要对公网开放。
- 所有私密参数只在 VPS 本机生成，不写入 GitHub。
- 首次部署会重置并启用 UFW，只放行当前 SSH 端口、80 和 443；因此仅建议在干净 VPS 上使用。
- 本项目不能保证某个 IP 永远不会被识别、限制或封锁；IP 信誉、网络路径、流量行为和服务商策略同样重要。

## 上游项目

- 3x-ui: https://github.com/MHSanaei/3x-ui
- Xray-core: https://github.com/XTLS/Xray-core
- Caddy: https://github.com/caddyserver/caddy
- HAProxy: https://github.com/haproxy/haproxy

## 许可证

MIT
