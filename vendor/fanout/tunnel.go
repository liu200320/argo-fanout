package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// SocksCred 是一条隧道的 SOCKS5 访问凭据。
//
// 每条隧道一套独立凭据：泄露一条不会连累其他出口，
// 换节点时也能只重置这一条而不影响已分发的其他配置。
type SocksCred struct {
	User string `json:"user"`
	Pass string `json:"pass"`
}

// Tunnel 是一条运行中的隧道：一个 netns + 一个 openvpn 进程 + 一个本地 SOCKS5 端口。
type Tunnel struct {
	Slot   int       `json:"slot"`
	Port   int       `json:"port"`
	Node   Node      `json:"node"`
	Status string    `json:"status"` // starting | up | failed | stopped
	ExitIP string    `json:"exit_ip"`
	Err    string    `json:"err,omitempty"`
	Since  time.Time `json:"since"`
	Cred   SocksCred `json:"cred"`

	ns       string
	listener net.Listener
	ovpn     *exec.Cmd
	mu       sync.Mutex
}

func (t *Tunnel) nsName() string { return fmt.Sprintf("fo%d", t.Slot) }
func (t *Tunnel) subnet() string { return fmt.Sprintf("10.99.%d", t.Slot) }

func run(name string, args ...string) error {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %v: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

// runQuiet 执行清理类命令，忽略"本来就不存在"这类错误。
func runQuiet(name string, args ...string) {
	_ = exec.Command(name, args...).Run()
}

// setupNetns 建立 netns 与 veth 链路，并配好 NAT 与转发放行。
func (t *Tunnel) setupNetns() error {
	ns, sub := t.nsName(), t.subnet()
	veth, peer := fmt.Sprintf("fov%d", t.Slot), fmt.Sprintf("fop%d", t.Slot)

	t.teardownNetns()

	if err := run("ip", "netns", "add", ns); err != nil {
		return err
	}
	if err := run("ip", "netns", "exec", ns, "ip", "link", "set", "lo", "up"); err != nil {
		return err
	}
	if err := run("ip", "link", "add", veth, "type", "veth", "peer", "name", peer); err != nil {
		return err
	}
	if err := run("ip", "link", "set", peer, "netns", ns); err != nil {
		return err
	}
	if err := run("ip", "addr", "add", sub+".1/30", "dev", veth); err != nil {
		return err
	}
	if err := run("ip", "link", "set", veth, "up"); err != nil {
		return err
	}
	if err := run("ip", "netns", "exec", ns, "ip", "addr", "add", sub+".2/30", "dev", peer); err != nil {
		return err
	}
	if err := run("ip", "netns", "exec", ns, "ip", "link", "set", peer, "up"); err != nil {
		return err
	}
	if err := run("ip", "netns", "exec", ns, "ip", "route", "add", "default", "via", sub+".1"); err != nil {
		return err
	}

	// netns 内的 DNS，仅用于 openvpn 解析远端主机名
	nsDir := filepath.Join("/etc/netns", ns)
	if err := os.MkdirAll(nsDir, 0755); err != nil {
		return fmt.Errorf("创建 %s 失败: %w", nsDir, err)
	}
	if err := os.WriteFile(filepath.Join(nsDir, "resolv.conf"), []byte("nameserver 8.8.8.8\n"), 0644); err != nil {
		return fmt.Errorf("写 resolv.conf 失败: %w", err)
	}

	cidr := sub + ".0/30"
	ensureRule("nat", "POSTROUTING", "-s", cidr, "-j", "MASQUERADE")
	ensureRuleInsert("filter", "FORWARD", "-s", cidr, "-j", "ACCEPT")
	ensureRuleInsert("filter", "FORWARD", "-d", cidr, "-j", "ACCEPT")
	return nil
}

// ensureRule 幂等追加一条 iptables 规则。
func ensureRule(table, chain string, spec ...string) {
	check := append([]string{"-w", "5", "-t", table, "-C", chain}, spec...)
	if exec.Command("iptables", check...).Run() == nil {
		return
	}
	add := append([]string{"-w", "5", "-t", table, "-A", chain}, spec...)
	runQuiet("iptables", add...)
}

// ensureRuleInsert 幂等插入规则到链首。
// FORWARD 链末尾常有兜底 REJECT，必须插到最前面才生效。
func ensureRuleInsert(table, chain string, spec ...string) {
	check := append([]string{"-w", "5", "-t", table, "-C", chain}, spec...)
	if exec.Command("iptables", check...).Run() == nil {
		return
	}
	ins := append([]string{"-w", "5", "-t", table, "-I", chain, "1"}, spec...)
	runQuiet("iptables", ins...)
}

func (t *Tunnel) teardownNetns() {
	ns, sub := t.nsName(), t.subnet()
	cidr := sub + ".0/30"
	runQuiet("ip", "netns", "del", ns)
	runQuiet("ip", "link", "del", fmt.Sprintf("fov%d", t.Slot))
	runQuiet("iptables", "-w", "5", "-t", "nat", "-D", "POSTROUTING", "-s", cidr, "-j", "MASQUERADE")
	runQuiet("iptables", "-w", "5", "-D", "FORWARD", "-s", cidr, "-j", "ACCEPT")
	runQuiet("iptables", "-w", "5", "-D", "FORWARD", "-d", cidr, "-j", "ACCEPT")
}

// startOpenVPN 在 netns 内拉起 openvpn，并等待 tun0 拿到地址。
func (t *Tunnel) startOpenVPN(dir string) error {
	ns := t.nsName()
	cfgPath := filepath.Join(dir, ns+".ovpn")
	if err := os.WriteFile(cfgPath, []byte(t.Node.Config), 0600); err != nil {
		return fmt.Errorf("写配置失败: %w", err)
	}
	authPath := filepath.Join(dir, "auth.txt")
	if err := os.WriteFile(authPath, []byte("vpn\nvpn\n"), 0600); err != nil {
		return fmt.Errorf("写凭据失败: %w", err)
	}

	logPath := filepath.Join(dir, ns+".log")
	cmd := exec.Command("ip", "netns", "exec", ns, "openvpn",
		"--config", cfgPath,
		"--auth-user-pass", authPath,
		"--auth-nocache",
		"--dev", "tun0",
		"--connect-retry-max", "2",
		"--connect-timeout", "20",
		"--data-ciphers", "AES-128-CBC:AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305",
		"--verb", "3",
		"--log", logPath,
	)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("启动 openvpn 失败: %w", err)
	}
	t.ovpn = cmd
	go cmd.Wait() // 回收子进程，避免僵尸

	// openvpn 建好 tun0 前 SOCKS5 无法正常出网，这里等它就绪
	deadline := time.Now().Add(40 * time.Second)
	for time.Now().Before(deadline) {
		if out, err := exec.Command("ip", "netns", "exec", ns, "ip", "-4", "addr", "show", "tun0").Output(); err == nil {
			if strings.Contains(string(out), "inet ") {
				return nil
			}
		}
		if cmd.ProcessState != nil && cmd.ProcessState.Exited() {
			return fmt.Errorf("openvpn 提前退出，详见 %s", logPath)
		}
		time.Sleep(time.Second)
	}
	return fmt.Errorf("等待 tun0 就绪超时，详见 %s", logPath)
}

// serve 在母机上监听 SOCKS5 端口，出站连接则在 netns 内建立。
// 监听必须留在母机侧：netns 内的 loopback 与母机彼此独立，
// 监听在 netns 里的话外部根本连不上。
func (t *Tunnel) serve() error {
	// 端口要尽量保持不变，否则用户已经分发出去的客户端配置会失效。
	// 进程刚重启时旧监听可能还在 TIME_WAIT，这里给几秒重试窗口。
	var ln net.Listener
	var err error
	for i := 0; i < 6; i++ {
		ln, err = net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", t.Port))
		if err == nil {
			break
		}
		time.Sleep(time.Second)
	}
	if err != nil {
		// 确实被别的进程长期占用了，才换端口
		port, perr := freeRandomPort(map[int]bool{t.Port: true})
		if perr != nil {
			return fmt.Errorf("监听 %d 失败且无备用端口: %w", t.Port, err)
		}
		ln, err = net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", port))
		if err != nil {
			return fmt.Errorf("监听 %d 失败: %w", port, err)
		}
		t.Port = port
	}
	t.listener = ln
	dial := dialerInNetns(t.nsName())

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			// 每次连接现取凭据：改口令后不必重建监听，新连接立刻按新凭据校验
			cred := t.credential()
			go serveSocks(conn, &cred, dial)
		}
	}()
	return nil
}

// credential 取一份凭据副本，避免读写并发。
func (t *Tunnel) credential() SocksCred {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.Cred
}

// setCredential 换掉这条隧道的 SOCKS5 凭据。已建立的连接不受影响，
// 新连接立即按新凭据校验。
func (t *Tunnel) setCredential(c SocksCred) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.Cred = c
}

// probeExitIP 通过隧道查询出口 IP，用于确认这条隧道确实换了 IP。
// 建隧道时的首次探测：多个 HTTPS 接口互备，任一成功即返回。
func (t *Tunnel) probeExitIP() (string, error) {
	return probeExitIPVia(t.nsName(), 15*time.Second)
}

// probeExitIPVia 在指定的 netns 内查出口公网 IPv4。
//
// 只走 HTTPS + 强制 IPv4：明文 HTTP 会被部分出口侧劫持/过滤，不带 -4 时
// curl 可能优先走 IPv6，两者都会让健康检查阶段拿到的 IP 与建隧道时不一致，
// 被误判成"掉线"。多个接口并发互备，总耗时不超过 timeout，单个接口抖动不算失败。
// 全部失败时返回 *probeFailure，其 Reason() 给出一句给用户看的中文原因，
// 不再直接暴露 signal: killed 这类英文底层错误。
func probeExitIPVia(ns string, timeout time.Duration) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	type res struct {
		url string
		ip  string
		err error
	}
	ch := make(chan res, len(publicIPSources))
	var wg sync.WaitGroup
	for _, url := range publicIPSources {
		wg.Add(1)
		go func(u string) {
			defer wg.Done()
			out, err := exec.CommandContext(ctx, "ip", "netns", "exec", ns,
				"curl", "-4", "-s", "--max-time", strconv.Itoa(int(timeout.Seconds())), u).Output()
			if err != nil {
				ch <- res{url: u, err: err}
				return
			}
			ip := strings.TrimSpace(string(out))
			if parsed := net.ParseIP(ip); parsed != nil && parsed.To4() != nil {
				ch <- res{url: u, ip: ip}
				return
			}
			ch <- res{url: u, err: fmt.Errorf("返回异常 %q", ip)}
		}(url)
	}
	go func() { wg.Wait(); close(ch) }()

	var errs []sourceErr
	for r := range ch {
		if r.ip != "" {
			return r.ip, nil
		}
		errs = append(errs, sourceErr{url: r.url, err: r.err})
	}
	return "", newProbeFailure(errs, len(publicIPSources))
}

// sourceErr 记录一个探测接口的地址与其底层失败原因。
type sourceErr struct {
	url string
	err error
}

// probeFailure 记录出口探测全败的汇总。Error() 保留英文底层细节给排障，
// Reason() 汇总成一句中文原因给用户看（日志、通知都用它，不再出现英文）。
type probeFailure struct {
	errs  []sourceErr
	total int // 探测接口总数
}

func newProbeFailure(errs []sourceErr, total int) error {
	return &probeFailure{errs: errs, total: total}
}

func (p *probeFailure) Error() string {
	parts := make([]string, len(p.errs))
	for i, se := range p.errs {
		parts[i] = se.url + ": " + se.err.Error()
	}
	return fmt.Sprintf("全部失败: %s", strings.Join(parts, "; "))
}

// Reason 汇总成一句中文原因，例如
// "全部 3 个探测接口失败：探测超时无响应（8 秒内无数据返回，探测进程被强制结束）"。
func (p *probeFailure) Reason() string {
	if len(p.errs) == 0 {
		return "所有出口探测接口均失败"
	}
	cause := classifyProbeCause(p.errs)
	if cause == "" {
		cause = "探测接口无响应"
	}
	if len(p.errs) >= p.total {
		return fmt.Sprintf("全部 %d 个探测接口失败：%s", p.total, cause)
	}
	return fmt.Sprintf("%d/%d 个探测接口失败：%s", len(p.errs), p.total, cause)
}

// probeErrPatterns 把常见底层错误映射成中文原因。顺序即优先级：
// 三个接口死因通常一致，命中数量相同时排在前面的先胜出。
var probeErrPatterns = []struct{ sub, zh string }{
	{"signal: killed", "探测超时无响应（8 秒内无数据返回，探测进程被强制结束）"},
	{"context deadline exceeded", "探测超过时限，没有任何接口返回"},
	{"temporary failure in name resolution", "DNS 解析失败（无法解析探测服务器域名）"},
	{"could not resolve host", "DNS 解析失败（无法解析探测服务器域名）"},
	{"no such host", "DNS 解析失败（无法解析探测服务器域名）"},
	{"connection refused", "连接被拒绝（探测服务器端口未开放）"},
	{"connection timed out", "连接超时（无法连上探测服务器）"},
	{"timed out", "连接超时（无法连上探测服务器）"},
	{"network is unreachable", "网络不可达（隧道出口已完全没有外网）"},
	{"no route to host", "无路由到探测服务器"},
	{"exit status 28", "探测响应超时"},
	{"exit status 7", "无法连接探测服务器"},
	{"exit status 6", "无法解析探测服务器域名"},
}

// classifyProbeCause 从一堆接口错误里挑出现次数最多的一种翻译成中文。
// 三个接口通常同一种死因（比如全是被超时杀掉），重复罗列没意义，
// 挑最有代表性的说一句就够了；没有认识的错误时返回空串。
func classifyProbeCause(errs []sourceErr) string {
	best, bestCnt := "", 0
	for _, pat := range probeErrPatterns {
		cnt := 0
		for _, se := range errs {
			if strings.Contains(strings.ToLower(se.err.Error()), pat.sub) {
				cnt++
			}
		}
		if cnt > bestCnt {
			best, bestCnt = pat.zh, cnt
		}
	}
	return best
}

// stop 停止这条隧道并清理它占用的所有资源。
func (t *Tunnel) stop() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.listener != nil {
		t.listener.Close()
		t.listener = nil
	}
	if t.ovpn != nil && t.ovpn.Process != nil {
		_ = t.ovpn.Process.Kill()
		t.ovpn = nil
	}
	t.teardownNetns()
	t.Status = "stopped"
}
