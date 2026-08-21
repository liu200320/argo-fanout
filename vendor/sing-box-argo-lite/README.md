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

## Telegram 节点推送

节点链接每次更新（安装完成、`sb-argo restart`、doctor 自愈后发现域名变化）都会自动发送到你的 Telegram，省去反复 `sb-argo show`。

安装时交互询问是否启用（需输入 Bot Token 和 Chat ID）；也可以直接写入配置文件：

```text
~/.config/sb-argo/config.conf     TG_NOTIFY='true'  TG_CHAT_ID='你的ID'
~/.config/sb-argo/secrets.conf    TG_BOT_TOKEN='你的Token'
```

获取方式：

- **Bot Token**：在 Telegram 联系 [@BotFather](https://t.me/BotFather)，`/newbot` 创建机器人，复制给出的 token。
- **Chat ID**：先给你的 bot 发一条消息（如 `/start`），再用 [@userinfobot](https://t.me/userinfobot) 发任意消息查询你的数字 ID。安装交互中也可自动获取。

验证推送：

```bash
sb-argo tg-test
```

注意：发送走 `api.telegram.org`，国内网络如果不通需要自行配置代理；Token 明文保存在本地 `secrets.conf`（chmod 600），不要分享给别人。

## 管理命令

```bash
sb-argo show
sb-argo status
sb-argo restart
sb-argo logs
sb-argo stop
sb-argo update
sb-argo doctor
sb-argo tg-test      # 测试 Telegram 节点推送
sb-argo uninstall
```

如果 `~/.local/bin` 不在 PATH：

```bash
~/.local/bin/sb-argo show
```

## 开机自启与定期自愈

安装器默认写入 crontab 两条任务（`crontab -l` 可查看）：

```text
@reboot     sleep 20; sb-argo start   # 开机自动启动
*/2 * * * * sb-argo doctor            # 每 2 分钟自愈检查
```

- **doctor**：发现 sing-box 或 cloudflared 挂掉会自动拉起。
  sing-box 的健康判定是**「进程存活 + 本地端口在监听」双条件**——只有进程活着
  但端口没绑上的"活死进程"（网络中断窗口期启动失败的遗留）也会被识别并重新拉起，
  不会出现链接断了几十小时、doctor 却一直报"全部正常"的情况；
  若 cloudflared 重启导致临时域名变化，自动刷新 `node-info.txt` /
  `subscription.txt`，启用了 Gist 时在线订阅同步更新。
- 关闭自愈：`ENABLE_DOCTOR=false bash <(curl ...)` 重新安装。

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