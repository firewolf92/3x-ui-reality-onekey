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

随后自动完成安装、配置与自检。健康检查会为首次 HTTPS 证书签发预留重试时间。首次安装需要通过 SSH 登录；如果系统无法自动识别 SSH 端口，必须显式设置 `ONEKEY_SSH_PORT=实际端口`，**不会再假定 SSH 一定是 22**。

### 3x-ui 安装成功但一键脚本自动配置失败：安全续装

3x-ui v3.11.0 起，登录和修改入站配置需要会话 Cookie 与 `X-CSRF-Token`。最新版安装脚本已在登录前取得 CSRF Token，并在登录成功后重新取得 Token，再使用它创建 Reality 入站。

**特别适用场景**：官方安装已经显示 `x-ui ... installation finished`，但是 OneKey 在自动登录阶段返回 HTTP 403，尚未创建 Reality 入站，也未创建本项目的站点/配置。

**不要重装 x-ui、不要运行 `--cleanup-failed`、不要把 `/etc/x-ui/install-result.env` 的内容分享出去。** 该文件包含管理员密码等机密。

用 root 在 VPS 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/install.sh -o /root/onekey-install.sh
bash -n /root/onekey-install.sh

# 不修改系统的只读检查
systemctl is-active x-ui
test -s /etc/x-ui/install-result.env && echo "3x-ui 安装凭据存在"
test -f /etc/3xui-onekey/.installation-incomplete && echo "OneKey 未完成标记存在"

# 复用已经安装好的面板，从自动配置步骤继续
bash /root/onekey-install.sh --resume-failed
```

续装时重新输入**原计划的站点域名、面板域名和证书邮箱**，Reality SNI 可直接使用默认值。脚本会从 root 保护的官方安装凭据文件读取原来的用户名、密码、端口与面板路径，不会再执行 `apt-get` 或重新安装 3x-ui。续装前会验证当前部署状态、DNS、SSH 端口，并检查入站 2443 是否已存在，以免重复创建。

**使用范围有限**：该入口只适用于 OneKey 在创建 Reality 入站、站点和项目配置之前中断的阶段。如果项目配置、站点或入站已写入，则会拒绝重复续装，应停止操作并人工排查。没有承诺任何中断状态都能自动恢复。还没有在真实 VPS 上完成续装验收。

### Reality 入站已经创建、Caddyfile 验证失败：第二阶段恢复

在 `--resume-failed` 成功创建 Reality 入站后，如果看到类似

```text
/etc/caddy/Caddyfile:7: Unexpected '}' because no matching opening brace
```

**不要再运行普通安装或 `--resume-failed`，更不要运行 `--cleanup-failed`**。此时原有 Reality UUID/密钥/入站必须保留，重新创建会导致客户端参数变化。

本项目提供独立的 `resume-caddy.sh`，不会重新安装 3x-ui，也不会重新创建或修改任何入站。它会验证上次的失败状态、原站点、3x-ui 原凭据、入站 2443 的详细数据及新生成的 Caddyfile，并从原入站中读取 UUID、Short ID 和公钥。检查异常会拒绝续装。

在 VPS 的 root 终端执行，**先只读检查**：

```bash
curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/install.sh -o /root/install.sh
curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/resume-caddy.sh -o /root/resume-caddy.sh
bash -n /root/install.sh
bash -n /root/resume-caddy.sh
bash /root/resume-caddy.sh --check
```

请按首次安装时的内容重新输入两个域名和证书邮箱；SNI 保持一致。**预检通过且确认是同一台干净 VPS 后**，再执行：

```bash
bash /root/resume-caddy.sh --apply
```

此步骤必须再输入 `RESUME` 才会写入配置。正式执行前会把 Caddyfile、HAProxy 原有配置与 SQLite 数据库备份到 root 私有目录，然后配置 Caddy/HAProxy/UFW，保存客户端链接和完整快照。

若 `--check` 提示原入站公钥缺失、面板数据不符、端口异常，或服务器已经有其他站点/代理服务，请勿强行绕过检查，应先人工排查。脚本是为本项目此特定 Caddy 中断阶段编写，仍需在实际 VPS 上验收。

### 安装中断后的安全处理

安装脚本会记录“尚未完成”的状态。如果部署中途失败，**不要直接反复执行安装命令**。优先保存终端日志并排查原因；确认需要放弃这次安装后，再下载当前脚本并在交互式 root 终端中清理：

```bash
curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/install.sh -o /root/onekey-install.sh
bash -n /root/onekey-install.sh
bash /root/onekey-install.sh --cleanup-failed
```

输入 `CLEANUP` 后会为部分安装文件创建本地备份，并停止/清理这次未完成的 3x-ui/Caddy/HAProxy 配置。**这是明确的人为破坏性清理，不是自动回滚**；它会尝试卸载本次安装引入的 `caddy`、`haproxy` 软件包，以免残留 systemd 服务阻止再次安装；不会执行 `apt autoremove`，也不会重置 UFW。仅当该工具留下了未完成安装标记时才能使用。完整清理后再考虑重新部署。



## 无人值守模式

```bash
SITE_DOMAIN=example.com \
PANEL_DOMAIN=panel.example.com \
ACME_EMAIL=you@example.com \
REALITY_SNI=www.microsoft.com \
bash <(curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/install.sh)
```

## 安装后

查看状态（检查失败时返回非零退出码，适合自动监控）：

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

### 更新失败时人工回滚

更新前命令会打印 `/root/3xui-onekey-backups/recovery-...` 的**确切目录路径**。如果上游更新导致面板或 Xray 无法正常运行，可以使用该目录执行预检与人工回滚：

```bash
onekey-recovery rollback /root/3xui-onekey-backups/recovery-YYYYMMDD-HHMMSS-PID
onekey-recovery rollback /root/3xui-onekey-backups/recovery-YYYYMMDD-HHMMSS-PID --apply
```

第二条必须交互输入 `ROLLBACK` 才会执行。回滚仅恢复 **3x-ui 程序、CLI、SQLite 数据库和 x-ui systemd 服务**，不会修改 Caddy/HAProxy、DNS、UFW；执行前会另存当前残留状态，且不会自动清除旧程序目录。回滚不是事务式自动修复；如果故障涉及操作系统或代理配置，仍可能需要人工处理。



## 上游失效保护 / 完整恢复快照

**新增**：onekey-recovery 工具。它把已安装的 3x-ui 程序（包括目录内的 Xray）、面板数据、反代配置、站点及辅助命令备份到本机私有目录，并生成 SHA256 校验文件。即使 3x-ui 官方 GitHub 仓库删除，只要你在删除前将快照转存到其他设备，就仍有机会用原来的运行文件恢复。

### 新部署后立即备份

新部署健康检查通过后，会**自动尝试创建第一份恢复快照**；如果创建失败，会显示警告但不会中断已经运行的服务。建议再手动执行一次确认：

```bash
onekey-recovery create
```

输出一个类似 `/root/3xui-onekey-backups/recovery-20261118-120000-1234` 的目录。备份目录内同时包含 **recovery.sh 恢复脚本副本**、元数据和校验文件；必须把**整个目录**安全复制到其他服务器或本地电脑。即使 GitHub 仓库以后被删除，也可以直接使用这份恢复脚本。

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

升级恢复助手后，请重新创建一份最新快照：旧格式快照若没有 `os_version` 元数据，新版恢复/回滚会拒绝自动应用，以防在不兼容系统上误恢复。

**注意**：旧 VPS 如果还使用旧版 `onekey-update`，可以在检查新脚本后下载覆盖，以启用“更新前必须完整备份”：

```bash
curl -fsSL https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/update.sh -o /root/onekey-update.new
bash -n /root/onekey-update.new
install -m 0755 /root/onekey-update.new /usr/local/sbin/onekey-update
```

### 新 VPS 恢复（无需原 3x-ui GitHub 仓库）

1. 准备**相同发行版、系统版本及 CPU 架构**的干净 Debian/Ubuntu VPS；把之前保存的整个快照目录（自带 `recovery.sh`）上传到新 VPS。不要先安装 3x-ui。
2. 确保能使用系统软件源，安装 `caddy`、`haproxy` 等操作系统依赖，例如 `apt-get update && apt-get install -y caddy haproxy python3`；停止它们的默认服务（`systemctl stop caddy haproxy`），确认没有其他服务占用 80/443。
3. 在新 VPS 上安装本地保存的恢复工具，先验证和预检，再明确确认写入：

```bash
install -m 0755 /root/recovery-YYYYMMDD-HHMMSS-PID/recovery.sh /usr/local/sbin/onekey-recovery
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

卸载会要求输入 `DELETE` 确认；正式删除之前必须成功创建**完整恢复快照**，否则会停止卸载。备份目录和 `onekey-recovery` 工具会保留，方便后续恢复。

## 稳定版验收边界

GitHub Actions 自动执行 Bash 语法、ShellCheck 以及备份完整性、损坏文件、越界符号链接、系统版本不匹配和恢复预检测试。**这些测试不等于真实 VPS 部署通过**，尤其未证明证书申请、REALITY 客户端连接、系统服务恢复或升级回滚都可在每一种服务器环境正常工作。

在打正式稳定标签之前，建议使用可销毁的 Debian/Ubuntu VPS 完成以下验收：

1. 通过全新域名和 VPS 完成安装，核对 `onekey-status` 退出码、网站 HTTPS、面板登录与独立客户端的 REALITY 连接。
2. 执行 `onekey-recovery create`、`verify`，把备份复制到另一台相同系统版本/架构的测试 VPS，实际完成 `restore --apply` 并验证客户端可用。
3. 在测试 VPS 上执行 `onekey-update`，使用升级前备份验证 `rollback --apply`；在可丢弃机器上测试失败安装清理和卸载。

未完成上述实机验收前，本仓库应视为**代码检查通过的候选版**，不能宣称生产恢复已验证。

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
- 首次部署会重置并启用 UFW，只放行已确认的 SSH 端口、80 和 443；无法确定 SSH 端口时会拒绝执行，需先设置 `ONEKEY_SSH_PORT`。因此仅建议在干净 VPS 上使用。
- 本项目不能保证某个 IP 永远不会被识别、限制或封锁；IP 信誉、网络路径、流量行为和服务商策略同样重要。

## 上游项目

- 3x-ui: https://github.com/MHSanaei/3x-ui
- Xray-core: https://github.com/XTLS/Xray-core
- Caddy: https://github.com/caddyserver/caddy
- HAProxy: https://github.com/haproxy/haproxy

## 许可证

MIT
