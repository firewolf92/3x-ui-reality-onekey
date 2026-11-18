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

更新前必须创建**可校验的完整恢复快照**，包括当前面板程序、随包提供的 Xray 程序、SQLite 数据库、面板密钥、站点与反代配置，然后再运行官方更新脚本。如备份失败或官方更新脚本无法下载，更新会安全停止。成功更新后，如本项目仓库暂时无法访问，仍保留本机已安装的管理脚本。

> 已部署过旧版本的 VPS 不要重新运行 install.sh；请先按下面的步骤启用恢复工具。

## 上游失效保护 / 完整恢复快照

**新增**：onekey-recovery 工具。它把已安装的 3x-ui 程序（包括目录内的 Xray）、面板数据、反代配置、站点及辅助命令备份到本机私有目录，并生成 SHA256 校验文件。即使 3x-ui 官方 GitHub 仓库删除，只要你在删除前将快照转存到其他设备，就仍有机会用原来的运行文件恢复。

### 新部署后立即备份

```bash
onekey-recovery create
```

输出一个类似 `/root/3xui-onekey-backups/recovery-20261118-120000-1234` 的目录。必须把**整个目录**安全复制到其他服务器或本地电脑，不要只保存 README、安装脚本或数据库。

```bash
onekey-recovery verify /root/3xui-onekey-backups/recovery-YYYYMMDD-HHMMSS-PID
```

### 已部署旧版 VPS：只启用恢复工具，不重装

在已安装本项目的 VPS 上以 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/recovery.sh -o /usr/local/sbin/onekey-recovery
bash -n /usr/local/sbin/onekey-recovery
chmod 0755 /usr/local/sbin/onekey-recovery
onekey-recovery create
```

**注意**：旧 VPS 如果还使用旧版 `onekey-update`，可以在检查新脚本后下载覆盖，以启用“更新前必须完整备份”：

```bash
curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/update.sh -o /root/onekey-update.new
bash -n /root/onekey-update.new
install -m 0755 /root/onekey-update.new /usr/local/sbin/onekey-update
```

### 新 VPS 恢复（无需原 3x-ui GitHub 仓库）

1. 准备**相同发行版及 CPU 架构**的干净 Debian/Ubuntu VPS；把之前保存的整个快照目录及 `recovery.sh` 上传到新 VPS。不要先安装 3x-ui。
2. 确保能使用系统软件源，安装 `caddy`、`haproxy` 等操作系统依赖，例如 `apt-get update && apt-get install -y caddy haproxy`；停止它们的默认服务（`systemctl stop caddy haproxy`），确认没有其他服务占用 80/443。
3. 在新 VPS 上安装本地保存的恢复工具，先验证和预检，再明确确认写入：

```bash
install -m 0755 ./recovery.sh /usr/local/sbin/onekey-recovery
onekey-recovery verify /root/recovery-YYYYMMDD-HHMMSS-PID
onekey-recovery restore /root/recovery-YYYYMMDD-HHMMSS-PID --new-ip 新VPS的公网IPv4
onekey-recovery restore /root/recovery-YYYYMMDD-HHMMSS-PID --new-ip 新VPS的公网IPv4 --apply
```

最后一步会要求在交互式终端输入 `RESTORE`。恢复脚本**拒绝覆盖已有 3x-ui 安装或正在运行的服务**，并且**不会自动修改 UFW 防火墙、DNS 或 SSH 端口**。恢复前应将域名 A 记录指向新 VPS；恢复后检查 `onekey-status`、HTTPS 证书、Reality 客户端及防火墙规则。

### 边界与安全

- 快照里有面板用户名、密码、UUID、REALITY 私钥以及可能存在的其他机密。**不要上传到公开 GitHub 仓库**，备份目录默认只有 root 可访问；请使用加密的离机存储。
- SHA256 用来检测意外损坏；它不是数字签名，不能证明第三方备份可信。只恢复自己创建、妥善保管的快照。
- 此能力避免了恢复时重新从原 3x-ui GitHub 仓库下载程序，但**不是完全断网安装**：新 VPS 仍需要发行版的软件包依赖、有效域名及 HTTPS 证书续期。不会自动镜像 GitHub Releases 到你的仓库。
- 当前仅支持本项目默认的 **SQLite** 部署；PostgreSQL 必须单独备份。新 VPS 的实际恢复效果需要在测试机验收，不能仅凭脚本静态检查视为生产可恢复。

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
- 所有私密参数只在 VPS 本机生成，不写入 GitHub；恢复快照同样不得公开。
- 首次部署会重置并启用 UFW，只放行当前 SSH 端口、80 和 443；因此仅建议在干净 VPS 上使用。
- 本项目不能保证某个 IP 永远不会被识别、限制或封锁；IP 信誉、网络路径、流量行为和服务商策略同样重要。

## 上游项目

- 3x-ui: https://github.com/MHSanaei/3x-ui
- Xray-core: https://github.com/XTLS/Xray-core
- Caddy: https://github.com/caddyserver/caddy
- HAProxy: https://github.com/haproxy/haproxy

## 许可证

MIT
