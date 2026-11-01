# XrayR

Vergelab 的 XrayR 发布与安装仓库。

项目主页：https://github.com/Vergelab/XrayR

## 安装

需要 root。脚本会安装 `ca-certificates`、`curl`、`unzip` 和 `tar`，再从 GitHub Release 下载与当前 CPU 架构对应的安装包。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Vergelab/xrayr-release/master/install.sh)
```

指定版本时，`0.1` 和 `v0.1` 是同一个版本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Vergelab/xrayr-release/master/install.sh) 0.1
bash <(curl -fsSL https://raw.githubusercontent.com/Vergelab/xrayr-release/master/install.sh) v0.1
```

未写版本号时，脚本跟随 GitHub Releases 的 `latest`。GitHub 的 `latest` 不包含预发布版本；当前预发布标签 `v0.1` 不会被当成最新版，需要显式指定。

安装完成后执行 `XrayR`（或 `xrayr`）打开管理菜单。配置目录是 `/etc/XrayR`（权限 `700`），`config.yml` 权限是 `600`。

发布包若附带 `XrayR-linux-<arch>.zip.sha256`（内容为 `sha256sum` 格式），安装时会校验。没有该文件时会警告并继续；校验和不匹配则中止，且不会改动已有安装。

## 更新

```bash
XrayR update
XrayR update 0.1
XrayR update v0.1
```

更新会先把新包下载到临时目录，用 `unzip -t` 和 `./XrayR version` 检查，通过后才停止服务并替换 `/usr/local/XrayR`。下载或校验失败时，正在运行的安装和管理脚本都保持原样。若新版本启动失败，会自动恢复 `/usr/local/XrayR.bak` 并重新启动。

完成提示里的版本号是实际安装的发布标签。

## 卸载

```bash
XrayR uninstall
```

会停止服务，并删除程序目录、systemd 单元、`/usr/bin/XrayR` 和 `/usr/bin/xrayr`。删除 `/etc/XrayR` 之前会询问是否备份到 `/root/XrayR-config-backup-<日期>.tar.gz`，直接回车表示备份。

## 日志

```bash
XrayR log
```

先显示 `journalctl -u XrayR -n 200 --no-pager`。如果 `config.yml` 里的 `ErrorPath` 不是空值，还会输出该文件末尾，然后回到菜单。

## 启用 BBR

管理菜单第 11 项，或：

```bash
XrayR bbr
```

只把下面两项写入 `/etc/sysctl.d/99-bbr.conf` 并执行 `sysctl --system`，不会安装新内核：

```text
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
```

内核版本低于 4.9 时会提示可能无法启用。命令结束时会打印当前拥塞控制算法。

## 已有节点的一次性升级

如果机器上还是旧的管理脚本，不要执行旧的 `XrayR update_shell`。旧脚本在下载失败时会把 `/usr/bin/XrayR` 截成 0 字节。请改用：

```bash
curl -fsSL https://raw.githubusercontent.com/Vergelab/xrayr-release/master/XrayR.sh -o /tmp/XrayR.sh && bash -n /tmp/XrayR.sh && install -m755 /tmp/XrayR.sh /usr/bin/XrayR
```

确认新脚本可用之后，再用 `XrayR update` 更新程序。

## Docker

`docker-compose.yml` 里的 `ghcr.io/vergelab/xrayr:latest` 尚未发布，拉取会失败。镜像上线之前不支持 Docker，请使用上面的安装脚本。

## License

本仓库以 MPL-2.0 发布，衍生自 XrayR。
