# 3x-ui 上游删除保护：固定版本安装资源镜像

此目录属于 OneKey 项目的**安装资源镜像方案**，不是 3x-ui 的官方仓库，也不是一个 GitHub 原生 Fork。
当前 GitHub 连接没有 Fork 仓库操作，因此只在本仓库保存一份独立可下载的上游 GPL-3.0 源码与安装资源镜像。

## 固定版本及保存的内容

- 上游来源：`MHSanaei/3x-ui`，固定 `v3.11.0`。
- 镜像 Release：`mirror-3xui-v3.11.0`（本项目 GitHub Releases）。
- Linux `amd64`、`arm64` 两种架构的 `x-ui-linux-*.tar.gz` 和官方 `.sha256`。
- 与该版本匹配的 `x-ui.sh`、`x-ui.rc`、systemd unit、`LICENSE`。
- **完整上游源码压缩包** `3x-ui-source-v3.11.0.tar.gz`，保留 GPL-3.0 开源义务。
- 固定版本安装器 `install.sh`：改写上游下载地址到**本项目自己的 Release**，并保留原版 `install-upstream.sh` 用于对比。
- `manifest.sha256`：所有发布内容的校验清单。

镜像工作流先验证上游官方压缩包的 SHA256 sidecar，生成修订安装器后检查 Bash 语法，再发布。已有的相同镜像标签禁止静默覆盖，防止版本漂移。

## 新 VPS 的使用方法

默认 `ONEKEY_3XUI_SOURCE=auto`：先检查固定版官方资源是否可达，不可达时再检查自有镜像；**源选择发生在运行 3x-ui 安装器之前**，绝不在官方安装部分失败后自动二次覆盖。

要强制完全不读取原 3x-ui 仓库安装资源（例如模拟上游仓库删除），在干净 Ubuntu/Debian VPS 上执行：

```bash
curl -fLSs https://raw.githubusercontent.com/firewolf92/3x-ui-reality-onekey/main/install.sh -o /root/onekey-install.sh
bash -n /root/onekey-install.sh
ONEKEY_3XUI_SOURCE=mirror bash /root/onekey-install.sh
```

你仍需提前准备两条指向 VPS 的 DNS A 记录、TCP 80/443、可靠的 SSH 登录，以及可访问的软件包源与证书签发网络。镜像不能替代 Ubuntu/Debian APT、Caddy 软件仓库或 ACME CA。

如果 `mirror-3xui-v3.11.0` Release 不存在或校验失败，脚本会拒绝安装，不会假装已完成“上游删除保护”。`auto` 模式仅在官方文件**事前可达性检查失败**时自动改用镜像；官方安装进行一半后失败时必须先检查和恢复，不得直接重试。

## 许可与安全边界

上游 3x-ui GPL-3.0 的源码、许可证和二进制来自上游对应 Tag，镜像只用于保存发行资源。使用和再分发须遵循该软件的 GPL-3.0 义务。本项目独立编写的 OneKey 脚本维持自身的许可证说明，但本镜像中由上游衍生的安装器适用 GPL-3.0。

此镜像是**固定已知版本**，不会自动吸收上游未来安全补丁。软件更新脚本目前仍依赖官方源，上游删除后应使用新发布、经安全审核的镜像版本或恢复快照，不要直接使用失效的上游更新链接。

此方案尚需在可丢弃的全新 VPS 上执行 `ONEKEY_3XUI_SOURCE=mirror` 完整安装，并单独测试外部客户端 REALITY 连接、`onekey-recovery verify`、异机恢复/回滚，才能宣称生产级上游断连恢复通过。GitHub Actions 检查不等于此项实机验收。
