- 

# sing-box Argo Lite

面向无 root、低内存 NAT 小机的 VLESS + WebSocket + TLS 一键脚本。

## 工作方式

```text
客户端
  -> trycloudflare.com:443
  -> Cloudflare TLS / Quick Tunnel
  -> 127.0.0.1:40001
  -> sing-box VLESS WebSocket
```

TLS 在 Cloudflare 边缘终止，本机 sing-box 不配置证书。

## 一键安装

将 `USER` 和 `REPO` 替换为自己的 GitHub 用户名和仓库名：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/USER/REPO/main/install.sh)
```

没有 `wget` 时：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/install.sh)
```

使用配置文件：

```bash
wget -qO config.conf \
  https://raw.githubusercontent.com/USER/REPO/main/config.conf.example

bash <(wget -qO- \
  https://raw.githubusercontent.com/USER/REPO/main/install.sh) \
  -f config.conf
```

## 在线订阅

在线订阅使用 GitHub Gist，不额外运行 Web、Nginx 或订阅进程。

首次安装会询问 GitHub Token。Token 需要 `gist` 权限，并只保存在：

```text
~/.config/sb-argo/secrets.conf
```

不要把 Token 提交到 GitHub。

临时 Argo 域名改变后，脚本会更新同一个 Gist，因此订阅 URL 保持不变。GitHub Raw 缓存可能导致更新延迟数分钟。

## 管理命令

```bash
sb-argo show
sb-argo status
sb-argo restart
sb-argo logs
sb-argo stop
sb-argo update
sb-argo uninstall
```

如果 `~/.local/bin` 不在 PATH：

```bash
~/.local/bin/sb-argo show
```

## 本地订阅文件

无论是否启用 Gist，Base64 订阅都会生成到：

```text
~/.local/share/sb-argo/state/subscription.txt
```

节点详情位于：

```text
~/.local/share/sb-argo/state/node-info.txt
```

## 限制

- Quick Tunnel 重启后会更换 `trycloudflare.com` 域名。
- Gist 订阅需要 GitHub Token 才能自动更新。
- `@reboot` 是否生效取决于服务商是否运行用户 crontab。
- 某些主机会在 SSH 退出后清理用户进程，此时 `nohup` 无法保活。
- 64 MB 同时运行 sing-box 和 cloudflared 仍可能触发 OOM。
- `GOMEMLIMIT` 只限制 Go 堆目标，不是 RSS 硬限制。
- NAT 映射的 `40001` 不直接提供给客户端；客户端连接临时域名的 `443`。