# fanout

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

把 VPN Gate 的公共节点变成本地 SOCKS5 端口：一个端口一个出口 IP。
再给每个出口挂一个节点链接，客户端连哪个端口就从哪个国家出去。

节点链接有四种管法：同机装了 3x-ui、xray-cf-lite 或 sing-box-argo-lite 就接管它们的入站，
都没装则 fanout 自己跑 Xray，建站、改站、发链接都在同一个界面里完成。

![主界面](https://images.joeyblog.net/2026/7/27/fanout-dashboard.png)

四条隧道跑在一台机器上，四个端口对应四个国家的出口，母机自己的 IP 不受影响：

![出口验证](https://images.joeyblog.net/2026/7/26/fanout-6-exit-ip.png)

## 原理

每个节点跑在独立的 network namespace 里，netns 内启动官方 openvpn 客户端。
SOCKS5 监听在母机，出站连接用 `setns` 切进对应 netns 建立。

这样做的好处：VPN 的路由劫持只影响自己的 netns，不会切断母机的网络；
多个节点互不干扰，各自一个出口 IP。

```
客户端 ──> 母机 SOCKS5 :随机端口 ──> netns foN ──> openvpn ──> VPN Gate 节点
```

## 安装

需要 root，Linux（依赖 netns）。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/byJoey/fanout/main/install.sh)
```

会自动下载对应架构的预编译二进制。也可以 clone 仓库后在源码目录运行同一个脚本，
那样会从源码编译（需要 Go 1.21+）。

依赖（openvpn / curl / openssl / iproute / iptables）会按发行版自动装，
apt、dnf、yum、pacman、apk、zypper 都认。没装 3x-ui 时还会顺带下载一份
Xray 到 `/var/lib/fanout/bin/`，装了则跳过，入站交给面板管。

服务用 systemd 或 OpenRC 都能装，装完自动开机自启。

**Alpine** 默认不带 bash，先装一下：

```bash
apk add bash curl
bash <(curl -fsSL https://raw.githubusercontent.com/byJoey/fanout/main/install.sh)
```

另外 fanout 要在 netns 里跑 openvpn，**宿主必须放开 `/dev/net/tun`**。
不少 LXC 小鸡没给这个权限，`ls /dev/net/tun` 不存在且 `mknod` 报
Operation not permitted 的话，这台机器用不了，跟发行版无关。

装完敲 `f` 打开管理菜单：

![管理菜单](https://images.joeyblog.net/2026/7/26/fanout-7-menu.png)

装完会打印管理界面地址、访问路径和口令：

```
管理界面  http://<你的IP>:8899/gwPuWHvaNr/
访问口令  f81120ac328d11c11b
```

路径和口令都是随机生成的，分别存在 `/var/lib/fanout/basepath` 和
`/var/lib/fanout/password`。路径不对一律返回 404，扫端口的看不到这里跑着什么。

## 使用

界面以**出口**为单位：一行就是一条隧道加上挂在它上面的节点链接。

点「新建出口」，选地区和数量，再选一个已有节点作模板，提交后 fanout 会并行
拉起隧道、为每个出口复制一份节点链接并绑好，进度按目标逐条回报。原来要手点
五步跨两栏的事，现在一次点击十几秒完成。

![新建出口](https://images.joeyblog.net/2026/7/27/fanout-wizard.png)

每行右侧两个按钮：换一个节点（出口 IP 变、端口不变，已分发的客户端配置不用改），
或者停掉这个出口。

点节点名进详情，可以改端口、备注、启停，管理客户端，以及改绑到别的出口：

![节点详情](https://images.joeyblog.net/2026/7/27/fanout-detail.png)

一个入站可以挂多套客户端凭据，分发给不同的人；每套都能单独重置，
重置后旧链接立即失效。

「导出链接」一次性拿到所有节点链接：

![导出链接](https://images.joeyblog.net/2026/7/27/fanout-export.png)

### 节点链接从哪来

同机装了 3x-ui 就直接接管面板里的入站，面板端口、路径、API token 全自动探测，
开了 SSL 也能识别。没装 3x-ui 时 fanout 自己跑一个 Xray，界面上多一个「新建节点」
按钮，可以选协议（VLESS / VMess / Trojan）、传输（TCP / WebSocket / gRPC /
HTTPUpgrade / XHTTP）和安全层（无 / TLS / REALITY）。

![新建节点](https://images.joeyblog.net/2026/7/27/fanout-newnode.png)

REALITY 的密钥对和 shortId 自动生成；TLS 不填证书就生成自签的，分享链接会带上
证书指纹让客户端固定信任。也可以填自己的证书路径。

接管 3x-ui 和自建这两种模式下，改端口、启停、加删客户端、绑定出口的操作完全一致，
用起来没有区别。

装了 [xray-cf-lite](https://github.com/byJoey/xray-cf-lite) 的机器会自动接管它生成的
三个节点。这个模式下节点归 xray-cf-lite 管，fanout 只负责给每个节点指定走哪条出口，
所以界面上不提供新建、删除和改节点的入口——想改端口或 UUID 去 xray-cf-lite 那边改。
两边共用同一份 Xray 配置，fanout 只往里加自己前缀的出站和分流规则，互不覆盖。

装了 sing-box-argo-lite（`sb-argo`）的机器同理：fanout 接管它那个 VLESS+WS 入站，
只决定它走哪条家宽出口。这个后端有几点和 xray-cf-lite 不同：

- 配置是 sing-box 而不是 Xray，字段形态不一样：出站写 `type/server/server_port`，
  路由写 `route.rules[].inbound/outbound`。fanout 按 sing-box 的写法注入。
- sb-argo 装在用户目录、不起系统服务，fanout 会在 `/root` 和 `/home/*` 下找
  `~/.config/sb-argo/sing-box.json`，并以配置属主的身份重启 sing-box。
- 只重启 sing-box，不动 cloudflared：`sb-argo restart` 会换掉 trycloudflare
  临时域名，已分发的节点链接会全部失效，所以这里保留隧道只换后面的进程。
- 节点链接是 Argo 临时域名，fanout 推不出来，界面里显示的是 sb-argo 写在
  `~/.local/share/sb-argo/state/node-info.txt` 里的那一条。
- 写回配置前先跑一次 `sing-box check`，坏配置不会被写进去——那会让 sing-box 起不来，
  而隧道还在，客户端会连到一个空端口上。

后端在设置面板里可以随时切换，本机没装的会置灰并说明原因；也可以用
`-panel 3x-ui` / `-panel native` / `-panel xray-cf-lite` / `-panel sing-box-argo-lite`
启动参数固定。界面里选过之后会记住，重启仍然生效。

注意 fanout 本身需要 root（要建 netns、改 iptables、要 `/dev/net/tun`），
而 sb-argo 是无 root 部署。两者可以共存在同一台机器上：sb-argo 继续用普通用户跑，
fanout 以 root 跑并去改那份用户配置。纯粹无 root 的环境跑不了 fanout。

## 运维

装完后敲 `f` 打开管理菜单：启停、看日志、查隧道、改端口/口令/访问路径、更新、卸载。

```
  状态      运行中
  版本      fanout v0.1.1
  开机自启  enabled

  管理地址  http://1.2.3.4:8899/gwPuWHvaNr/
  访问口令  f81120ac328d11c11b

   1) 启动          2) 停止
   3) 重启          4) 查看日志
   5) 隧道列表      6) 连接信息
   7) 改端口        8) 改口令
   9) 改访问路径   10) 开机自启开关
  11) 更新         12) 卸载
```

也可以直接带参数用：

```bash
f info       # 连接信息
f list       # 隧道列表
f restart    # 重启
f log        # 跟踪日志
f update     # 更新到最新版
f uninstall  # 卸载
```

隧道状态存在 `/var/lib/fanout/state.json`，重启后自动恢复，端口保持不变。

健康检查每 10 秒跑一次，确认隧道是否还真的走在 VPN 上——openvpn 挂掉后
netns 仍能经母机 NAT 出网，只看通不通会漏判，所以要比对出口 IP。判掉线做了
三重防抖，避免志愿者节点抖动被误判成掉线：

1. 同时打 3 个 HTTPS 出口 IP 接口，任一成功即视为能出网；
2. 强制 IPv4 + HTTPS，避免被劫持或 IPv6 导致探测结果与建隧道时对不上；
3. 出口 IP 与建隧道时不同不算掉线（节点常有多出口/负载均衡），只有出口 IP
   退回母机自己的公网 IP（openvpn 真断了）或 3 个接口全失败才算。

**连续 3 次失败（约 30 秒）才判定掉线**，然后自动换节点重连，槽位和端口不变，
原先指向它的节点链接会自动改绑过去。掉线通知会写明"已确认出口不可用"及确认
结果（接口全失败 / 退回母机），不是网络抖动误报。确认原因是**中文汇总**的，
不会出现 signal: killed 这类英文底层错误（例如"全部 3 个探测接口失败：
探测超时无响应（8 秒内无数据返回，探测进程被强制结束）"）。

### 出口掉线的自动切换与 Telegram 通知

判定掉线后除了换节点重连，还会：

1. **自动切回直连 / 迁到备用出口**：把绑定在该出口上的入站解绑（回落到机器本身的
   直连出口）或整体迁到另一条连通的出口，节点链接保持可用。
2. **自动切回 SOCKS5**：隧道恢复后入站自动重新绑回到 SOCKS5 出口。
3. **Telegram 通知**：掉线/恢复各推一条，消息带机器名（`FANOUT_NODE_NAME`
   环境变量，或 `~/.config/sb-argo/config.conf` 的 `NODE_NAME`）。
   恢复通知**无论该出口有没有入站绑定都会推**——有绑定写"已切回 SOCKS5 出口"，
   没绑定写"已恢复正常出网"，保证掉线 ⚠️ 之后必有恢复 ✅。

要启用 TG 通知需配置 Bot Token / Chat ID：优先读环境变量
`FANOUT_TG_BOT_TOKEN` / `FANOUT_TG_CHAT_ID`，否则读
`~/.config/sb-argo/secrets.conf` 的 `TG_BOT_TOKEN` 与
`~/.config/sb-argo/config.conf` 的 `TG_CHAT_ID`。没配置则只自动切换、不推送。

## 已知限制

- 只转发 TCP。SOCKS5 收到域名时在本机解析，隧道内不跑 UDP/DNS。
- VPN Gate 是志愿者节点，有相当比例已下线或满员（`AUTH_FAILED`）。
  启动时连不上会自动顺着同地区候选往下试，最多 6 个。
- 管理界面只有随机路径 + 口令登录，没有 HTTPS。放公网建议前面套一层反代。

## 许可

[MIT](LICENSE)。

节点来自 [VPN Gate](https://www.vpngate.net/)（筑波大学的学术实验项目），
本工具只是调用其公开的节点列表并用官方 openvpn 客户端连接，不修改也不代理其服务。
使用时请遵守 VPN Gate 的条款和你所在地的法律。

## 交流

- 交流群：<https://t.me/+ft-zI76oovgwNmRh>
- 视频教程：<https://youtube.com/@joeyblog>
- 博客：<https://joeyblog.net>

用着有问题、或者想要什么功能，去群里说或提 issue。
