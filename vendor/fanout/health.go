package main

import (
	"fmt"
	"log"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

const (
	healthInterval = 10 * time.Second
	healthFailures = 2 // 连续失败几次才判定掉线，避免网络抖动误杀
	healthTimeout  = 6 * time.Second
)

// WatchHealth 周期检查每条隧道是否还能出网，掉线的自动换节点重连。
// VPN Gate 是志愿者节点，运行中掉线很常见。
// 判掉线时会把绑在该隧道上的入站解绑回直连（保证节点仍可用），并推送 Telegram 提醒；
// 每条隧道掉线只提醒一次，恢复后重新绑定回 SOCKS5 出口再提醒一次。
func (m *Manager) WatchHealth() {
	fails := map[int]int{}
	notified := map[int]bool{}

	for range time.Tick(healthInterval) {
		for _, t := range m.Tunnels() {
			if t.Status != "up" {
				continue
			}
			if m.tunnelHealthy(t) {
				// 之前掉线通知过且隧道已恢复：把入站重新绑回 SOCKS5 出口
				if notified[t.Slot] {
					m.restoreBindings(t)
					notified[t.Slot] = false
				}
				fails[t.Slot] = 0
				continue
			}

			fails[t.Slot]++
			if fails[t.Slot] < healthFailures {
				log.Printf("隧道 %d (%s) 探测失败 %d 次", t.Slot, t.Node.HostName, fails[t.Slot])
				continue
			}

			log.Printf("隧道 %d (%s) 已掉线，正在换节点重连", t.Slot, t.Node.HostName)
			fails[t.Slot] = 0

			if !notified[t.Slot] {
				notified[t.Slot] = true
				// 优先把绑定迁到另一条连通出口，没有备用出口才解绑回直连：
				// 绑定始终跟着可用出口走，面板显示什么就是什么，不需要手动重绑。
				action := m.unbindToDirect(t)
				msg := fmt.Sprintf(
					"⚠️ [%s] fanout SOCKS5 出口掉线\n\n节点: %s\n槽位: %d\n本地端口: %d\n",
					nodeNameForNotify(), t.Node.HostName, t.Slot, t.Port,
				)
				if action != "" {
					msg += "\n" + action + "，正在尝试换节点重连"
				} else {
					msg += "\n正在尝试换节点重连（该出口当前没有入站绑定，节点链接不受影响）"
				}
				go sendTG(msg)
			}
			m.reconnect(t, t.Node.HostName)
		}
	}
}

// unbindToDirect 出口掉线后处理绑在它上面的入站：
// 优先整体迁到另一条连通的隧道（保证分流不中断），只有没有备用出口时才解绑回直连。
// 返回描述去向的文案，空串表示该出口没有入站绑定、无需处理。
// 失败只记日志：健康检查与通知都不应因此中断。
func (m *Manager) unbindToDirect(t *Tunnel) string {
	p, err := openPanel()
	if err != nil {
		return ""
	}
	ins, err := p.Inbounds(map[string]bool{})
	if err != nil {
		log.Printf("掉线处理失败（读取入站列表）: %v", err)
		return ""
	}
	tags := []string{}
	for _, ib := range ins {
		if ib.BoundTo == t.Node.HostName {
			tags = append(tags, ib.Tag)
		}
	}
	if len(tags) == 0 {
		return ""
	}

	// 备用出口：另一条 up 的隧道。绑定走到哪，面板就显示到哪。
	var alt *Tunnel
	for _, x := range m.Tunnels() {
		if x.Status == "up" && x.Slot != t.Slot {
			alt = x
			break
		}
	}

	moved := 0
	if alt != nil {
		for _, tag := range tags {
			if err := p.Bind(tag, alt.Node.HostName, m.Tunnels()); err != nil {
				log.Printf("掉线迁移入站 %s 到备用出口 %s 失败: %v", tag, alt.Node.HostName, err)
				continue
			}
			moved++
			log.Printf("隧道 %d 掉线，入站 %s 已切到备用出口 %s", t.Slot, tag, alt.Node.HostName)
		}
		if moved == 0 {
			return ""
		}
		m.migrated[t.Slot] = tags
		return fmt.Sprintf("已自动切到备用出口 %s", alt.Node.HostName)
	}

	for _, tag := range tags {
		if err := p.Bind(tag, "", m.Tunnels()); err != nil {
			log.Printf("掉线解绑入站 %s 失败: %v", tag, err)
			continue
		}
		moved++
		log.Printf("隧道 %d 掉线，入站 %s 已解绑回直连", t.Slot, tag)
	}
	if moved == 0 {
		return ""
	}
	m.migrated[t.Slot] = tags
	return "已自动切回直连（机器本身出口）"
}

// restoreBindings 隧道恢复后，把掉线时从它迁走的入站重新绑回这条隧道的 SOCKS5 出口。
// 节点可能在重连时换了（reconnect 会换候选节点），绑回当前实际节点。
func (m *Manager) restoreBindings(t *Tunnel) {
	p, err := openPanel()
	if err != nil {
		return
	}
	ins, err := p.Inbounds(map[string]bool{})
	if err != nil {
		log.Printf("恢复绑定失败（读取入站列表）: %v", err)
		return
	}

	// 掉线迁走的这批入站，可能被后续掉线又迁去了别处或解绑回直连，
	// 只要没绑回本隧道就重新绑回来。
	waiting := m.migrated[t.Slot]
	byTag := map[string]bool{}
	for _, tag := range waiting {
		byTag[tag] = true
	}
	cur := map[string]string{}
	for _, ib := range ins {
		cur[ib.Tag] = ib.BoundTo
	}

	rebound := 0
	for _, tag := range waiting {
		if cur[tag] == t.Node.HostName {
			continue
		}
		if err := p.Bind(tag, t.Node.HostName, m.Tunnels()); err != nil {
			log.Printf("恢复绑定入站 %s 失败: %v", tag, err)
			continue
		}
		rebound++
		log.Printf("隧道 %d 已恢复，入站 %s 重新绑定到 SOCKS5 出口", t.Slot, tag)
	}
	if len(waiting) == 0 {
		// 旧版本升上来：没有迁移记录，但有掉线时解绑回直连的入站，一并兜底绑回。
		for _, ib := range ins {
			if ib.BoundTo != "" {
				continue
			}
			if err := p.Bind(ib.Tag, t.Node.HostName, m.Tunnels()); err != nil {
				log.Printf("恢复绑定入站 %s 失败: %v", ib.Tag, err)
				continue
			}
			rebound++
			log.Printf("隧道 %d 已恢复，入站 %s 重新绑定到 SOCKS5 出口", t.Slot, ib.Tag)
		}
	}
	delete(m.migrated, t.Slot)
	if rebound > 0 {
		go sendTG(fmt.Sprintf(
			"✅ [%s] fanout SOCKS5 出口已恢复\n\n节点: %s\n槽位: %d\n本地端口: %d\n\n已切回 SOCKS5 出口",
			nodeNameForNotify(), t.Node.HostName, t.Slot, t.Port,
		))
	}
}

// nodeNameForNotify 取本机节点名称（机器名）用于通知；拿不到就兜底成"未命名机器"。
func nodeNameForNotify() string {
	if n := loadNodeName(); n != "" {
		return n
	}
	return "未命名机器"
}

// tunnelHealthy 判断隧道是否还真的走在 VPN 上。
//
// 只看"能不能出网"是不够的：netns 通过 veth 走母机 NAT，
// openvpn 死掉后照样能出网，只是出口变回了母机 IP。
// 所以要比对出口 IP 是否仍是建立隧道时拿到的那个。
func (m *Manager) tunnelHealthy(t *Tunnel) bool {
	out, err := exec.Command("ip", "netns", "exec", t.nsName(),
		"curl", "-s", "--max-time", strconv.Itoa(int(healthTimeout.Seconds())),
		"http://api.ipify.org").Output()
	if err != nil {
		return false
	}
	got := strings.TrimSpace(string(out))
	if got == "" {
		return false
	}
	// 出口 IP 变了说明 VPN 已经断开，流量退回了母机
	return got == t.ExitIP
}

// reconnect 就地把一条隧道换到别的节点上，保持槽位与端口不变，
// 这样已经分发出去的客户端配置仍然可用。
//
// oldHost 必须是本次重连前那条隧道真正绑着的节点名。调用方若已经
// 改过 t.Node（比如手动换节点），就要把改之前的名字传进来，
// 否则 rebind 找不到旧绑定，入站会掉成孤儿。
func (m *Manager) reconnect(t *Tunnel, oldHost string) {
	t.Status = "starting"
	t.Err = "正在换节点重连"
	t.ExitIP = ""

	if t.ovpn != nil && t.ovpn.Process != nil {
		_ = t.ovpn.Process.Kill()
		t.ovpn = nil
	}
	t.teardownNetns()

	go func() {
		// 通知延后到 rebind/resync 之后：那两步会把入站改绑到新节点，
		// 提前重建配置会因为入站还指着旧节点名而丢掉路由规则
		m.bringUpPersist(t, false, true)
		if t.Status != "up" {
			return
		}
		// 出站 tag 跟着节点名走，换了节点就要把原来指向它的入站重新绑过去，
		// 否则面板里的路由会指向一个已经不存在的出站。
		if t.Node.HostName != oldHost {
			if err := m.rebind(oldHost, t); err != nil {
				log.Printf("重连后同步 3x-ui 绑定失败: %v", err)
			}
			return
		}
		// 节点名没变也要重写一次出站：出口 IP 可能变了，
		// 而且上一轮换节点时留下的绑定需要重新指回来。
		if err := m.resync(t); err != nil {
			log.Printf("重连后重写 3x-ui 出站失败: %v", err)
		}
	}()
}
