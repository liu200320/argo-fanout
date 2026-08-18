package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// SBA 对接 sing-box-argo-lite 装出来的用户级 sing-box。
//
// sing-box-argo-lite 面向无 root 的 NAT 小机：sing-box 以普通用户身份跑在
// nohup 下，配置固定落在 ~/.config/sb-argo/sing-box.json，只有一个 VLESS+WS
// 入站监听 127.0.0.1，TLS 由 Cloudflare Quick Tunnel 在边缘终止。
//
// fanout 在这个后端下不新建/删除节点，只往同一份配置里注入 fanout- 前缀的
// socks 出站和 route 规则，决定这个入站走哪条家宽出口。
// sing-box 的字段名与 Xray 不同：出站是 socks/server/server_port，
// 路由在 route.rules 里用 inbound/outbound 而不是 inboundTag/outboundTag。
type SBA struct {
	cfgPath  string // ~/.config/sb-argo/sing-box.json
	stateDir string // ~/.local/share/sb-argo/state
	binPath  string // ~/.local/share/sb-argo/bin/sing-box
	owner    string // 配置属主用户名，重启进程时要切回它
	homeDir  string
	sbMemory string // GOMEMLIMIT，与 sb-argo 保存的配置保持一致

	// restart 单独拎出来，测试里可以换成不真的去动进程
	restart func() error
}

const (
	sbaConfigRel = ".config/sb-argo/sing-box.json"
	sbaSavedRel  = ".config/sb-argo/config.conf"
	sbaStateRel  = ".local/share/sb-argo/state"
	sbaBinRel    = ".local/share/sb-argo/bin/sing-box"
)

// DetectSBA 找出本机由 sing-box-argo-lite 接管的那份配置。
//
// sb-argo 装在用户目录而不是系统路径，所以要扫 root 和 /home 下的候选。
// 只有配置可读可解析才认，避免把残留目录当成一次可用的部署。
func DetectSBA() (*SBA, error) {
	homes, err := sbaCandidateHomes()
	if err != nil {
		return nil, err
	}
	var lastErr error
	for _, home := range homes {
		cfg := filepath.Join(home, sbaConfigRel)
		if _, err := os.Stat(cfg); err != nil {
			continue
		}
		s := &SBA{
			cfgPath:  cfg,
			stateDir: filepath.Join(home, sbaStateRel),
			binPath:  filepath.Join(home, sbaBinRel),
			homeDir:  home,
			owner:    sbaOwnerOf(home, cfg),
			sbMemory: sbaSavedMemory(filepath.Join(home, sbaSavedRel)),
		}
		if _, err := s.loadCfg(); err != nil {
			lastErr = err
			continue
		}
		s.restart = s.restartSingBox
		return s, nil
	}
	if lastErr != nil {
		return nil, lastErr
	}
	return nil, fmt.Errorf("未发现 sing-box-argo-lite 配置（找过 ~/%s）", sbaConfigRel)
}

// sbaCandidateHomes 列出可能装了 sb-argo 的家目录，root 优先。
func sbaCandidateHomes() ([]string, error) {
	homes := []string{"/root"}
	entries, err := os.ReadDir("/home")
	if err == nil {
		for _, e := range entries {
			if e.IsDir() {
				homes = append(homes, filepath.Join("/home", e.Name()))
			}
		}
	}
	if home := os.Getenv("HOME"); home != "" {
		homes = append(homes, home)
	}
	seen := map[string]bool{}
	out := make([]string, 0, len(homes))
	for _, h := range homes {
		if seen[h] {
			continue
		}
		seen[h] = true
		out = append(out, h)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("没有可检查的家目录")
	}
	return out, nil
}

// sbaOwnerOf 推断配置属主。/home/<name> 直接取目录名，/root 就是 root。
//
// fanout 以 root 运行，重启 sing-box 时必须切回属主：用 root 起进程会把
// 日志和 pid 文件的属主改掉，之后用户自己的 sb-argo 命令就管不动它了。
func sbaOwnerOf(home, cfgPath string) string {
	if home == "/root" {
		return "root"
	}
	if strings.HasPrefix(home, "/home/") {
		name := strings.TrimPrefix(home, "/home/")
		if name != "" && !strings.Contains(name, "/") {
			return name
		}
	}
	// 兜底：用配置文件的 uid 反查用户名
	if out, err := exec.Command("stat", "-c", "%U", cfgPath).Output(); err == nil {
		if name := strings.TrimSpace(string(out)); name != "" {
			return name
		}
	}
	return "root"
}

// sbaSavedMemory 读 sb-argo 自己保存的 SB_MEMORY，重启时沿用同样的堆上限。
func sbaSavedMemory(savedPath string) string {
	blob, err := os.ReadFile(savedPath)
	if err != nil {
		return "18MiB"
	}
	for _, line := range strings.Split(string(blob), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "SB_MEMORY=") {
			continue
		}
		v := strings.TrimPrefix(line, "SB_MEMORY=")
		v = strings.Trim(v, "'\"")
		if v != "" {
			return v
		}
	}
	return "18MiB"
}

func (s *SBA) Kind() string { return "sing-box-argo-lite" }

func (s *SBA) Describe() string {
	return fmt.Sprintf("sing-box-argo-lite 接管（用户 %s，配置 %s）", s.owner, s.cfgPath)
}

func (s *SBA) loadCfg() (map[string]any, error) {
	blob, err := os.ReadFile(s.cfgPath)
	if err != nil {
		return nil, fmt.Errorf("读取 %s 失败: %w", s.cfgPath, err)
	}
	var cfg map[string]any
	if err := json.Unmarshal(blob, &cfg); err != nil {
		return nil, fmt.Errorf("解析 %s 失败: %w", s.cfgPath, err)
	}
	return cfg, nil
}

// saveCfg 写回配置并只重启 sing-box。
//
// 先写临时文件、校验、再原子改名：配置写坏时 sing-box 起不来，
// 而 Argo 隧道还在，客户端会连到一个空端口上。
// 临时文件的属主要跟着改回去，否则用户下次自己改配置会被拒。
func (s *SBA) saveCfg(cfg map[string]any) error {
	blob, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("序列化配置失败: %w", err)
	}
	tmp := s.cfgPath + ".fanout.tmp"
	if err := os.WriteFile(tmp, blob, 0600); err != nil {
		return fmt.Errorf("写入临时配置失败: %w", err)
	}
	s.chownToOwner(tmp)
	if err := s.checkConfig(tmp); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, s.cfgPath); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("替换配置失败: %w", err)
	}
	s.chownToOwner(s.cfgPath)
	if s.restart == nil {
		return s.restartSingBox()
	}
	return s.restart()
}

func (s *SBA) chownToOwner(path string) {
	if s.owner == "" || s.owner == "root" {
		return
	}
	_ = exec.Command("chown", s.owner+":", path).Run()
}

// checkConfig 用 sing-box 自己的校验器过一遍配置。二进制不在就跳过校验。
func (s *SBA) checkConfig(path string) error {
	if _, err := os.Stat(s.binPath); err != nil {
		return nil
	}
	cmd := exec.Command(s.binPath, "check", "-c", path)
	cmd.Env = append(os.Environ(), "ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("sing-box 配置校验失败: %s", trimOutput(out))
	}
	return nil
}

// restartSingBox 只重启 sing-box，不动 cloudflared。
//
// sb-argo restart 会把 cloudflared 一起重启，那样 trycloudflare 临时域名会换掉，
// 已分发出去的节点链接全部失效。这里保留隧道，只换掉后面的 sing-box 进程，
// 客户端最多断一下重连，地址和 UUID 都不变。
func (s *SBA) restartSingBox() error {
	pidFile := filepath.Join(s.stateDir, "sing-box.pid")
	logFile := filepath.Join(s.homeDir, ".local/share/sb-argo/logs/sing-box.log")

	if old := readPIDFile(pidFile); old > 0 {
		_ = exec.Command("kill", strconv.Itoa(old)).Run()
		for i := 0; i < 10; i++ {
			if exec.Command("kill", "-0", strconv.Itoa(old)).Run() != nil {
				break
			}
			time.Sleep(300 * time.Millisecond)
		}
	}

	mem := s.sbMemory
	if mem == "" {
		mem = "18MiB"
	}
	// 与 sb-argo 的启动参数保持一致：低内存机器上这些 Go 运行时开关是必须的
	script := fmt.Sprintf(
		"nohup env GOMAXPROCS=1 GOMEMLIMIT=%s GOGC=25 GODEBUG=madvdontneed=1 "+
			"ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true "+
			"%s run -c %s </dev/null >>%s 2>&1 & echo $! > %s",
		shellQuote(mem), shellQuote(s.binPath), shellQuote(s.cfgPath),
		shellQuote(logFile), shellQuote(pidFile),
	)

	var cmd *exec.Cmd
	if s.owner == "" || s.owner == "root" {
		cmd = exec.Command("sh", "-c", script)
	} else {
		cmd = exec.Command("su", "-s", "/bin/sh", s.owner, "-c", script)
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("重启 sing-box 失败: %s", trimOutput(out))
	}

	time.Sleep(600 * time.Millisecond)
	if pid := readPIDFile(pidFile); pid > 0 {
		if exec.Command("kill", "-0", strconv.Itoa(pid)).Run() != nil {
			return fmt.Errorf("sing-box 启动后立刻退出，详见 %s", logFile)
		}
	}
	return nil
}

func readPIDFile(path string) int {
	blob, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(blob)))
	if err != nil || pid <= 0 {
		return 0
	}
	return pid
}

// shellQuote 把值包成单引号形式，避免路径里的空格或特殊字符拆坏命令。
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// sbaInboundTag 取 inbound 的 tag，没写就按协议+端口兜底。
func sbaInboundTag(m map[string]any) string {
	if tag, _ := m["tag"].(string); tag != "" {
		return tag
	}
	typ, _ := m["type"].(string)
	return fmt.Sprintf("in-%s-%d", typ, jsonInt(m["listen_port"]))
}

// Inbounds 列出 sb-argo 生成的入站及当前绑定的出口。
func (s *SBA) Inbounds(live map[string]bool) ([]Inbound, error) {
	cfg, err := s.loadCfg()
	if err != nil {
		return nil, err
	}
	bound := s.boundInbounds(cfg)

	rawIns, _ := cfg["inbounds"].([]any)
	out := make([]Inbound, 0, len(rawIns))
	for _, raw := range rawIns {
		m, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		typ, _ := m["type"].(string)
		// 只列代理入站，tun/direct/mixed 这类不是节点
		switch typ {
		case "vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic":
		default:
			continue
		}
		tag := sbaInboundTag(m)
		port := jsonInt(m["listen_port"])
		out = append(out, Inbound{
			ID:       port, // sb-argo 没有数值 ID，用监听端口做稳定标识
			Port:     port,
			Protocol: typ,
			Remark:   tag,
			Enable:   true,
			Tag:      tag,
			BoundTo:  bound[tag],
			BoundUp:  live[bound[tag]],
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Port < out[j].Port })
	return out, nil
}

// boundInbounds 从 route.rules 里还原 inbound tag -> 节点主机名 的绑定。
func (s *SBA) boundInbounds(cfg map[string]any) map[string]string {
	bound := map[string]string{}
	route, _ := cfg["route"].(map[string]any)
	if route == nil {
		return bound
	}
	rules, _ := route["rules"].([]any)
	for _, r := range rules {
		m, ok := r.(map[string]any)
		if !ok {
			continue
		}
		// sing-box 的字段是 outbound（字符串），不是 Xray 的 outboundTag
		tag, _ := m["outbound"].(string)
		if !strings.HasPrefix(tag, xuiTagPrefix) {
			continue
		}
		host := strings.TrimPrefix(tag, xuiTagPrefix)
		if isAllDigits(host) {
			continue
		}
		for _, it := range toStringSlice(m["inbound"]) {
			bound[it] = host
		}
	}
	return bound
}

// syncOutbounds 让配置里的 fanout- 出站与当前连通的隧道一致，
// 保留 sb-argo 自己的 direct 出站。
func (s *SBA) syncOutbounds(cfg map[string]any, tunnels []*Tunnel) {
	outbounds, _ := cfg["outbounds"].([]any)
	kept := make([]any, 0, len(outbounds))
	for _, ob := range outbounds {
		m, ok := ob.(map[string]any)
		if !ok {
			kept = append(kept, ob)
			continue
		}
		tag, _ := m["tag"].(string)
		if !strings.HasPrefix(tag, xuiTagPrefix) {
			sbaForceIPv4(m)
			kept = append(kept, ob)
		}
	}
	for _, t := range tunnels {
		if t.Status != "up" {
			continue
		}
		kept = append(kept, sbaSocksOutbound(t))
	}
	cfg["outbounds"] = kept
}

// sbaSocksOutbound 拼一条 sing-box 形态的 socks 出站。
//
// 字段名与 Xray 完全不同：sing-box 用 server / server_port / username / password
// 平铺在出站对象上，没有 settings.servers 这层。
func sbaSocksOutbound(t *Tunnel) map[string]any {
	cred := t.credential()
	ob := map[string]any{
		"type":        "socks",
		"tag":         tunnelTag(t),
		"server":      "127.0.0.1",
		"server_port": t.Port,
		"version":     "5",
	}
	if cred.User != "" {
		ob["username"] = cred.User
		ob["password"] = cred.Pass
	}
	return ob
}

// sbaForceIPv4 让 direct 出站只走 IPv4。
//
// 隧道内没有 IPv6，没被规则匹配上的流量会走 direct 直连；
// 母机有全局 IPv6 时这部分会从 IPv6 出去，暴露真实地址。
func sbaForceIPv4(outbound map[string]any) {
	if typ, _ := outbound["type"].(string); typ != "direct" {
		return
	}
	outbound["domain_strategy"] = "ipv4_only"
}

// Bind 把某个入站的流量导向指定隧道。hostname 留空表示解绑，恢复走 direct。
func (s *SBA) Bind(inboundTag string, hostname string, tunnels []*Tunnel) error {
	var target *Tunnel
	if hostname != "" {
		for _, t := range tunnels {
			if t.Node.HostName == hostname {
				target = t
				break
			}
		}
		if target == nil {
			return fmt.Errorf("节点 %s 没有运行中的隧道", hostname)
		}
		if target.Status != "up" {
			return fmt.Errorf("节点 %s 的隧道还没连通（当前 %s）", hostname, target.Status)
		}
	}

	live := map[string]bool{}
	for _, t := range tunnels {
		if t.Status == "up" {
			live[sanitizeTag(t.Node.HostName)] = true
		}
	}
	current, err := s.Inbounds(live)
	if err != nil {
		return err
	}
	knownTags := map[string]bool{}
	for _, ib := range current {
		knownTags[ib.Tag] = true
	}
	if !knownTags[inboundTag] {
		return fmt.Errorf("入站 %s 不存在", inboundTag)
	}

	cfg, err := s.loadCfg()
	if err != nil {
		return err
	}
	s.syncOutbounds(cfg, tunnels)

	route, _ := cfg["route"].(map[string]any)
	if route == nil {
		route = map[string]any{}
	}
	rules, _ := route["rules"].([]any)

	cleaned := make([]any, 0, len(rules)+1)
	for _, r := range rules {
		m, ok := r.(map[string]any)
		if !ok {
			cleaned = append(cleaned, r)
			continue
		}
		outTag, _ := m["outbound"].(string)
		if !strings.HasPrefix(outTag, xuiTagPrefix) {
			cleaned = append(cleaned, r)
			continue
		}
		remain := []any{}
		for _, it := range toStringSlice(m["inbound"]) {
			if it != inboundTag && knownTags[it] {
				remain = append(remain, it)
			}
		}
		if len(remain) > 0 {
			m["inbound"] = remain
			cleaned = append(cleaned, m)
		}
	}

	if target != nil {
		cleaned = append(cleaned, map[string]any{
			"inbound":  []any{inboundTag},
			"outbound": tunnelTag(target),
		})
	}

	route["rules"] = cleaned
	cfg["route"] = route
	return s.saveCfg(cfg)
}

// Rebind 把绑在 oldHost 上的入站整体改绑到 target，用于换节点时批量迁移。
func (s *SBA) Rebind(oldHost string, target *Tunnel, tunnels []*Tunnel) error {
	if target == nil {
		return fmt.Errorf("目标节点为空")
	}
	cfg, err := s.loadCfg()
	if err != nil {
		return err
	}
	bound := s.boundInbounds(cfg)
	moved := 0
	for tag, host := range bound {
		if host != oldHost {
			continue
		}
		if err := s.Bind(tag, target.Node.HostName, tunnels); err != nil {
			return err
		}
		moved++
	}
	if moved == 0 {
		return fmt.Errorf("没有入站绑在 %s 上", oldHost)
	}
	return nil
}

// ResyncOutbound 隧道集合变化后重刷出站。
func (s *SBA) ResyncOutbound(t *Tunnel, tunnels []*Tunnel) error {
	return s.OnTunnelsChanged(tunnels)
}

// OnTunnelsChanged 在隧道集合变化后重写 fanout- 出站并重启 sing-box。
func (s *SBA) OnTunnelsChanged(tunnels []*Tunnel) error {
	cfg, err := s.loadCfg()
	if err != nil {
		return err
	}
	s.syncOutbounds(cfg, tunnels)
	return s.saveCfg(cfg)
}

// InboundDetail 返回入站详情。
//
// 节点链接由 sb-argo 生成（地址是 trycloudflare 临时域名，fanout 无从推导），
// 这里直接把它写在 state/node-info.txt 里的那条读出来展示。
func (s *SBA) InboundDetail(id int, publicHost string) (*InboundDetail, error) {
	ins, err := s.Inbounds(map[string]bool{})
	if err != nil {
		return nil, err
	}
	for _, ib := range ins {
		if ib.ID != id {
			continue
		}
		detail := &InboundDetail{
			Inbound: ib,
			Listen:  "127.0.0.1",
			Network: "ws",
			TLS:     "由 Cloudflare Argo 边缘终止",
		}
		if link := s.nodeLink(); link != "" {
			detail.Links = []string{link}
		}
		return detail, nil
	}
	return nil, fmt.Errorf("入站 %d 不存在", id)
}

// InboundLinks 回读 sb-argo 生成的节点链接，供导出使用。
func (s *SBA) InboundLinks(ids []int, publicHost string) ([]string, error) {
	link := s.nodeLink()
	if link == "" {
		return nil, nil
	}
	return []string{link}, nil
}

// nodeLink 从 sb-argo 的 node-info.txt 里取那条节点链接。
func (s *SBA) nodeLink() string {
	blob, err := os.ReadFile(filepath.Join(s.stateDir, "node-info.txt"))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(blob), "\n") {
		line = strings.TrimSpace(line)
		for _, prefix := range []string{"vless://", "vmess://", "trojan://"} {
			if strings.HasPrefix(line, prefix) {
				return line
			}
		}
	}
	return ""
}

// ---- 以下操作在这个后端下禁用：节点由 sb-argo 管，fanout 只改路由 ----

var errSBAReadOnly = fmt.Errorf(
	"sing-box-argo-lite 模式下节点由 sb-argo 管理（UUID、路径、端口去 sb-argo 改），" +
		"fanout 只能改路由（绑定出口）")

func (s *SBA) CreateInbound(spec NewInboundSpec, tunnels []*Tunnel) (*CreatedInbound, error) {
	return nil, errSBAReadOnly
}

func (s *SBA) CloneToTunnels(templateID int, hosts []string, tunnels []*Tunnel) ([]int, error) {
	return nil, errSBAReadOnly
}

func (s *SBA) DeleteInbounds(ids []int, tunnels []*Tunnel) error { return errSBAReadOnly }

func (s *SBA) UpdateInbound(id int, patch InboundPatch, tunnels []*Tunnel) error {
	return errSBAReadOnly
}

func (s *SBA) AddClient(id int, email string, tunnels []*Tunnel) error    { return errSBAReadOnly }
func (s *SBA) DeleteClient(id int, email string, tunnels []*Tunnel) error { return errSBAReadOnly }
func (s *SBA) ResetClient(id int, email string, tunnels []*Tunnel) error  { return errSBAReadOnly }

// Close 无自管进程，空实现。sing-box 归 sb-argo 管，不该被 fanout 停掉。
func (s *SBA) Close() {}
