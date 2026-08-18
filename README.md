# argo-fanout

**一键部署 sing-box-argo-lite + fanout VPNGate 出口分流系统**

这个项目将两个开源工具整合到一个交互式安装脚本中：
- **sing-box-argo-lite**：通过 Cloudflare Argo 隧道提供无需公网 IP 的 VLESS 入站节点
- **fanout**：自动从 VPN Gate 获取免费出口节点，并将入站流量按出口分流

组合后你可以获得：
- 📡 **零配置入站**：Cloudflare 自动分配域名，无需开放端口
- 🌍 **多国出口**：从日本、韩国、美国等 VPN Gate 节点中选择出口
- 🎛️ **图形化管理**：Web 界面一键切换出口，实时查看隧道状态
- 🔒 **无日志风险**：入站和出站都在你自己的服务器上中转

---

## 📋 安装前准备

### 1. 服务器要求

| 项目 | 最低要求 | 推荐配置 |
|------|---------|---------|
| **CPU** | 1 核 | 2 核 |
| **内存** | 512 MB | 1 GB |
| **系统** | Debian 10+ / Ubuntu 20.04+ / Alpine 3.17+ | Debian 12 / Ubuntu 22.04 |
| **架构** | amd64 / arm64 | amd64 |
| **内核** | 支持 TUN 设备、网络命名空间 | 4.19+ |
| **权限** | root | root |

### 2. NAT 机器特别说明

本项目按 **NAT VPS / LXC NAT 容器**设计，节点入口使用 Cloudflare Quick Tunnel，
所以不需要服务器有独立公网 IPv4，也不需要把 sing-box 的本地端口暴露到公网。

但 NAT 机器通常有以下限制：

- 必须能创建 `/dev/net/tun` 和 network namespace；只提供普通 NAT、没有 TUN 的容器不能运行 fanout。
- sing-box 的本地端口（默认 `40001`）只监听 `127.0.0.1`，**不需要做端口映射**。
- fanout Web 管理面板默认端口 `8899`，安装时可以改成其他端口。NAT 机器如果没有入站端口映射，
  外部浏览器不能直接访问这个面板，应使用主机商端口映射，或者用 SSH 隧道访问。
- Cloudflare Argo 节点端口是客户端访问的 `443`，不是 fanout 面板端口，也不需要 NAT 入站映射。

没有端口映射时，推荐使用 SSH 隧道。假设 fanout 面板监听服务器本机 `40002`：

```bash
ssh -N -L 40002:127.0.0.1:40002 root@你的服务器
```

然后在本地浏览器打开安装完成后显示的路径：

```text
http://127.0.0.1:40002/随机路径/
```

### 3. 必须先安装 git（在线一键安装必需）

`bash <(curl ...)` 在线运行时，脚本会先把仓库 clone 到 `/opt/argo-fanout` 再继续，
**没有 git 会直接失败**。各系统安装命令：

```bash
# Debian / Ubuntu
apt update && apt install -y git

# CentOS / RHEL / Fedora
yum install -y git          # 或 dnf install -y git

# Alpine（注意：默认没有 bash，必须一起装）
apk add git bash

# Arch / Manjaro
pacman -S --noconfirm git

# openSUSE
zypper --non-interactive install git
```

> **Alpine 特别提醒**：默认 shell 是 ash，`bash <(curl ...)` 这种进程替换语法需要 bash，
> 所以除了 git 还必须装 bash，然后用 `bash` 而不是 `sh` 执行命令。

装完验证：

```bash
git --version
```

### 4. 环境自查

安装脚本会自动检查这三项，不过你也可以先手动确认，省得装到一半才报错：

```bash
# ① root 权限（必须是 0）
id -u
# 期望输出: 0

# ② TUN 设备（fanout 建 VPN 隧道必需）
[ -c /dev/net/tun ] && echo "✅ TUN 可用" || echo "❌ TUN 不可用，请找主机商开启"

# ③ 架构（只支持 amd64 / arm64）
uname -m
# 期望输出: x86_64 或 aarch64
```

如果 `②` 显示不可用，你的机器大概率是 OpenVZ / LXC 容器，需要联系主机商
**开启 TUN/TAP 设备和网络命名空间**，否则 fanout 无法创建出口隧道。

### 5. 网络要求

- ✅ 能访问 GitHub（用于下载源码和依赖）
- ✅ 能访问 Cloudflare API（用于建立 Argo 隧道）
- ✅ 能访问 VPN Gate API（用于获取出口节点列表）

如果服务器在国内，建议先配置 GitHub 代理或使用镜像加速。

### 6. 可选准备

#### 如果要发布订阅到 GitHub Gist（推荐）

1. 登录 [GitHub](https://github.com)
2. 进入 **Settings** → **Developer settings** → **Personal access tokens** → **Tokens (classic)**
3. 点击 **Generate new token** → **Generate new token (classic)**
4. 勾选 `gist` 权限，生成 Token 并保存（只显示一次）

#### 如果服务器在 OpenVZ / LXC 容器中

联系主机商**开启 TUN/TAP 设备**和**网络命名空间**支持，否则 fanout 无法创建出口隧道。

验证方法：
```bash
# 检查 TUN 设备
[ -c /dev/net/tun ] && echo "✅ TUN 设备可用" || echo "❌ TUN 设备不可用"

# 检查网络命名空间
unshare -n true 2>/dev/null && echo "✅ netns 可用" || echo "❌ netns 不可用"
```

---

## 🚀 一键安装

### 在线安装（推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/liu200320/argo-fanout/main/install.sh)
```

### 本地安装

```bash
git clone https://github.com/liu200320/argo-fanout.git
cd argo-fanout
bash install.sh
```

---

## 💬 安装中：交互式配置

安装脚本会依次询问以下参数：

### sing-box-argo-lite 配置

| 参数 | 说明 | 默认值 | 示例 |
|------|------|--------|------|
| **运行用户** | 运行 sing-box 的系统用户 | `root` | `root` 或 `sbuser` |
| **本地监听端口** | sing-box 监听的端口（fanout 会连接此端口） | `40001` | `40001` |
| **UUID** | VLESS 协议的用户 ID | 自动生成 | `12345678-1234-...` |
| **WebSocket 路径** | WS 传输的 URL 路径 | 自动生成 | `/ws-abc123` |
| **订阅节点名称** | 客户端显示的节点名 | `NAT-Argo-Fanout` | `香港-Argo` |
| **是否发布 Gist** | 是否将订阅链接发布到 GitHub Gist | `n` | `y` |
| **GitHub Token** | 如果选 y，需要输入 Token（输入不显示） | 无 | `ghp_xxxx...` |

### fanout 配置

| 参数 | 说明 | 默认值 | 示例 |
|------|------|--------|------|
| **Web 管理端口** | fanout 管理面板的 HTTP 端口 | `8899` | `8899` |

配置完成后，脚本会显示汇总信息并等待你确认，按回车键开始安装。

安装器会执行两层防护，避免误装官方 fanout 后回退到 native/Xray：

1. 使用仓库 `bin/` 中包含 SBA 后端的定制二进制；即使 Git clone 后文件权限是 `0644`，
   安装器也会主动执行 `chmod 755`，不会再因 `-x` 判断失败而下载官方旧版。
2. 服务启动参数固定为：

```text
-panel sing-box-argo-lite
```

安装后还会用 `cmp` 硬校验 `/usr/local/bin/fanout` 与仓库定制二进制完全一致；
不一致时直接停止安装，不会带着错误版本继续启动。

安装完成后可以确认：

```bash
cat /var/lib/fanout/panel_mode
ps aux | grep '[f]anout'
```

第二条命令的进程参数中应包含 `-panel sing-box-argo-lite`。

---

## ✅ 安装后：使用与管理

### 0. 放行防火墙端口（装完第一件事）

安装脚本**不会自动开防火墙**。装完 Web 面板连不上，先检查这里。

fanout Web 面板默认端口是 **8899**（安装时可改）：

```bash
# Debian / Ubuntu（ufw）
ufw allow 8899/tcp

# 或者直接用 iptables（通用）
iptables -I INPUT -p tcp --dport 8899 -j ACCEPT

# firewalld（CentOS / RHEL 8+）
firewall-cmd --permanent --add-port=8899/tcp && firewall-cmd --reload
```

> **云服务器还要过厂商安全组**：腾讯云 / 阿里云 / AWS / Vultr 等在系统防火墙之外
> 还有一层控制台安全组，8080/8899 这类端口默认是关的，需要去控制台
> 「安全组 → 入站规则」里放行 TCP 8899。
>
> **安全建议**：面板是公网控制入口，虽然自带随机路径和随机口令，更稳妥的做法是
> 安全组只对你的家庭 IP 放行；或者不对外放行，改为 SSH 隧道访问：
> `ssh -L 8899:127.0.0.1:8899 root@你的服务器` 后浏览器开 `http://127.0.0.1:8899`。

### 1. 获取节点信息

安装完成后，脚本会输出类似以下内容：

```
--- sing-box 节点信息 ---
节点链接: vless://12345678-1234-...@xxx.trycloudflare.com:443?encryption=none&security=tls&type=ws&path=%2Fws-abc#NAT-Argo-Fanout

订阅地址: https://gist.githubusercontent.com/liu200320/xxxx/raw/subscription.txt

--- fanout 管理面板 ---
管理地址:  http://123.45.67.89:8899/a1b2c3d4/
访问口令:  xyz123
终端命令:  输入 f 打开管理菜单
```

- **节点链接**：直接导入 v2rayN / Clash / Surge 等客户端
- **订阅地址**：在客户端中添加订阅（需要启用了 Gist）
- **管理地址**：浏览器访问，用于管理出口节点
- **访问口令**：登录管理面板时输入

### 2. 配置出口节点

1. 用浏览器打开 **管理地址**，输入**访问口令**登录
2. 点击页面上的 **"新建出口"** 或 **"从 VPN Gate 导入"**
3. 选择一个延迟较低的节点（通常日本、韩国节点速度较快）
4. 等待隧道建立完成（状态变为绿色 ✅）
5. 在 **"入站管理"** 中找到 `vless-ws` 入站，点击右侧的 **"绑定出口"**
6. 选择刚才建好的出口，点击 **"保存"**

### 3. 客户端连接

- 把步骤 1 中的**节点链接**复制到代理客户端（v2rayN / Clash / Surge 等）
- 或者添加**订阅地址**并更新订阅（如果启用了 Gist）
- 连接节点后，你的流量路径是：

  ```
  你的设备 → Cloudflare CDN → 你的服务器 sing-box → fanout → VPN Gate 出口 → 目标网站
  ```

### 4. 日常管理命令

在服务器终端输入以下命令管理服务：

#### fanout 管理菜单
```bash
f
```
进入交互式菜单，可以：
- 查看当前隧道状态
- 切换出口节点
- 修改 Web 面板端口 / 访问口令
- 重启 / 停止服务

#### sing-box-argo 命令
```bash
# 查看节点信息（包括链接和订阅地址）
sb-argo show

# 查看服务状态
sb-argo status

# 重启服务
sb-argo restart

# 查看日志
sb-argo logs

# 停止服务
sb-argo stop

# 更新到最新版
sb-argo update
```

#### systemd 服务管理
```bash
# fanout 服务
systemctl status fanout
systemctl restart fanout
systemctl stop fanout

# sing-box-argo 服务（如果用 root 用户安装）
systemctl status sb-argo
systemctl restart sb-argo
```

---

## 🔧 常见问题

### Q1: 安装时提示 "缺少 /dev/net/tun 设备"

**原因**：你的服务器是 OpenVZ / LXC 容器，且主机商未开启 TUN 设备。

**解决**：联系主机商工单请求开启 TUN/TAP，或更换为 KVM 虚拟化的 VPS。

### Q2: fanout 面板无法访问

NAT 机器不能直接从公网访问本地监听端口。先在服务器本机测试：

```bash
# Alpine / OpenRC
rc-service fanout status
wget -S -O - http://127.0.0.1:40002/ 2>&1 | head

# Debian / Ubuntu / systemd
systemctl status fanout --no-pager
curl -I http://127.0.0.1:8899
```

然后确认访问方式：

1. 有端口映射：在主机商控制台把外部端口映射到 fanout 实际端口。
2. 没有端口映射：使用 SSH 隧道，例如 `ssh -N -L 40002:127.0.0.1:40002 root@服务器`。
3. 如果系统防火墙启用，再放行实际面板端口：`ufw allow 40002/tcp` 或
   `iptables -I INPUT -p tcp --dport 40002 -j ACCEPT`。
4. 云服务器还需要检查控制台安全组；纯 NAT 容器则检查主机商的端口映射。

### Q3: 日志提示找不到 xray

如果日志出现：

```text
节点链接后端暂不可用: 找不到 xray 可执行文件
```

说明 fanout 仍按 native 模式启动，没有使用 sing-box-argo-lite。历史版本出现该问题的根因是：
GitHub clone 把仓库二进制检出成 `0644`，旧安装器用 `-x` 判断后误认为定制二进制不存在，
继而下载了不含 SBA 后端的官方 fanout。最新版安装器已经修复并增加二进制一致性校验。

检查：

```bash
cat /var/lib/fanout/panel_mode
ps aux | grep '[f]anout'
```

应看到：

```text
sing-box-argo-lite
-panel sing-box-argo-lite
```

Alpine / OpenRC 修复方式：

```bash
sed -i 's#command_args="-dir /var/lib/fanout"#command_args="-dir /var/lib/fanout -panel sing-box-argo-lite"#' /etc/init.d/fanout
rc-service fanout restart
tail -n 30 /var/log/fanout.log
```

推荐所有系统直接更新仓库并重新运行最新版一键安装器：

```bash
cd /opt/argo-fanout
git pull
bash install.sh
```

最新版会自动修复二进制权限、禁止回退官方版本、校验安装结果，并把
`-panel sing-box-argo-lite` 写入 systemd/OpenRC 服务。不要为了这个问题给 NAT 机器
额外安装 Xray；本组合应该使用 sing-box-argo-lite 后端。

### Q4: 节点能连上但无法上网

**原因**：入站未绑定出口，或出口隧道未建立成功。

**解决**：
1. 登录 fanout 面板，查看出口状态是否为 ✅
2. 如果出口是红色 ❌，尝试删除重建或换一个节点
3. 确认入站已绑定到出口：在"入站管理"中检查 `vless-ws` 的出口字段

### Q5: Gist 订阅无法更新

**原因**：GitHub Token 权限不足或已过期。

**解决**：
1. 重新生成 Token（确保勾选 `gist` 权限）
2. 编辑 `~/.config/sb-argo/secrets.conf`，更新 `GITHUB_TOKEN`
3. 重启 sing-box：`sb-argo restart`

### Q6: 想换一个出口节点

**方法 1**（推荐）：
1. 登录 fanout 面板
2. 点击"新建出口"，选择新节点
3. 在"入站管理"中将 `vless-ws` 重新绑定到新出口
4. 旧出口不用了可以删除

**方法 2**（终端）：
```bash
f  # 打开菜单
# 选择 "切换出口节点"
```

---

## 🗑️ 卸载

```bash
cd /opt/argo-fanout
bash uninstall.sh
```

卸载脚本会询问你要删除哪些组件：
1. 仅卸载 fanout（保留 sing-box-argo-lite）
2. 仅卸载 sing-box-argo-lite（保留 fanout）
3. 完全卸载（删除所有组件）

---

## 📦 项目结构

```
argo-fanout/
├── install.sh              # 主安装脚本
├── uninstall.sh            # 卸载脚本
├── README.md               # 本文档
├── bin/                    # 预编译的 fanout 二进制
│   ├── fanout-linux-amd64
│   └── fanout-linux-arm64
└── vendor/                 # 子项目源码
    ├── fanout/             # fanout 完整源码（含 sing-box-argo-lite 后端）
    └── sing-box-argo-lite/ # sing-box-argo-lite 安装器
```

---

## 🙏 致谢

- sing-box-argo-lite - 无 root 部署的 sing-box + Argo 隧道方案
- [fanout](https://github.com/byJoey/fanout) - VPN Gate 多出口网关
- [VPN Gate](https://www.vpngate.net/) - 提供免费的公益 VPN 节点

---

## 📄 许可证

本项目遵循 MIT 许可证。子项目的许可证请参考对应目录下的 LICENSE 文件。

---

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

如果这个项目对你有帮助，请给个 ⭐ Star 支持一下～
