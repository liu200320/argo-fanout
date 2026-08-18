package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// sbaFixture 造一份 sing-box-argo-lite 风格的配置：
// 一个 VLESS+WS 入站监听 127.0.0.1，出站只有 direct，没有 route。
func sbaFixture(t *testing.T) *SBA {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "sing-box.json")
	cfg := `{
	  "log": {"level": "error", "timestamp": false},
	  "inbounds": [
	    {
	      "type": "vless",
	      "tag": "vless-ws",
	      "listen": "127.0.0.1",
	      "listen_port": 40001,
	      "users": [{"uuid": "11111111-2222-4333-8444-555555555555"}],
	      "transport": {"type": "ws", "path": "/11111111-vl"}
	    }
	  ],
	  "outbounds": [
	    {"type": "direct", "tag": "direct"}
	  ]
	}`
	if err := os.WriteFile(path, []byte(cfg), 0600); err != nil {
		t.Fatal(err)
	}
	return &SBA{
		cfgPath:  path,
		stateDir: dir,
		homeDir:  dir,
		owner:    "root",
		sbMemory: "18MiB",
		restart:  func() error { return nil },
	}
}

// sbaMultiFixture 造一份带两个入站的配置，用来验证按入站分别绑出口。
func sbaMultiFixture(t *testing.T) *SBA {
	t.Helper()
	s := sbaFixture(t)
	cfg, err := s.loadCfg()
	if err != nil {
		t.Fatal(err)
	}
	ins, _ := cfg["inbounds"].([]any)
	ins = append(ins, map[string]any{
		"type":        "vless",
		"tag":         "vless-ws-2",
		"listen":      "127.0.0.1",
		"listen_port": 40002,
	})
	cfg["inbounds"] = ins
	if err := s.saveCfg(cfg); err != nil {
		t.Fatal(err)
	}
	return s
}

func sbaReadCfg(t *testing.T, s *SBA) map[string]any {
	t.Helper()
	cfg, err := s.loadCfg()
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

func TestSBAInboundsListsProxyInbound(t *testing.T) {
	s := sbaFixture(t)
	ins, err := s.Inbounds(nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(ins) != 1 {
		t.Fatalf("应列出一个入站，实际 %d", len(ins))
	}
	if ins[0].Port != 40001 || ins[0].Tag != "vless-ws" || ins[0].Protocol != "vless" {
		t.Errorf("入站信息应从 listen_port/tag/type 读出，实际 %+v", ins[0])
	}
	if ins[0].BoundTo != "" {
		t.Errorf("初始状态不该有绑定: %+v", ins[0])
	}
}

// tun/direct 这类不是节点，不该出现在界面的入站列表里
func TestSBAInboundsSkipsNonProxy(t *testing.T) {
	s := sbaFixture(t)
	cfg := sbaReadCfg(t, s)
	ins, _ := cfg["inbounds"].([]any)
	cfg["inbounds"] = append(ins, map[string]any{"type": "tun", "tag": "tun-in"})
	if err := s.saveCfg(cfg); err != nil {
		t.Fatal(err)
	}
	got, err := s.Inbounds(nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Tag != "vless-ws" {
		t.Fatalf("只该列代理入站，实际 %+v", got)
	}
}

func TestSBABindAddsSingBoxStyleRouteRule(t *testing.T) {
	s := sbaFixture(t)
	tunnels := []*Tunnel{xclTunnel("jp-01", 1, 20001)}

	if err := s.Bind("vless-ws", "jp-01", tunnels); err != nil {
		t.Fatal(err)
	}

	cfg := sbaReadCfg(t, s)
	tags := outboundTags(cfg)
	if len(tags) != 2 || tags[0] != "direct" || tags[1] != "fanout-jp-01" {
		t.Fatalf("sb-argo 自己的出站要原样保留、fanout 出站追加在后: %v", tags)
	}

	// 出站必须是 sing-box 的字段形态，不能是 Xray 的 settings.servers
	obs, _ := cfg["outbounds"].([]any)
	ob, _ := obs[1].(map[string]any)
	if ob["type"] != "socks" || ob["server"] != "127.0.0.1" {
		t.Fatalf("socks 出站字段应为 sing-box 形态: %v", ob)
	}
	if jsonInt(ob["server_port"]) != 20001 {
		t.Fatalf("server_port 应是隧道的 SOCKS5 端口: %v", ob["server_port"])
	}
	if _, bad := ob["settings"]; bad {
		t.Errorf("不该写 Xray 的 settings 字段: %v", ob)
	}

	// 路由规则同理：inbound/outbound 而不是 inboundTag/outboundTag
	route, _ := cfg["route"].(map[string]any)
	rules, _ := route["rules"].([]any)
	if len(rules) != 1 {
		t.Fatalf("应有一条路由规则，实际 %d", len(rules))
	}
	rule, _ := rules[0].(map[string]any)
	if rule["outbound"] != "fanout-jp-01" {
		t.Fatalf("规则应用 outbound 字段: %v", rule)
	}
	if _, bad := rule["outboundTag"]; bad {
		t.Errorf("不该写 Xray 的 outboundTag: %v", rule)
	}

	if bound := s.boundInbounds(cfg); bound["vless-ws"] != "jp-01" {
		t.Fatalf("绑定应能回读，实际 %v", bound)
	}
}

func TestSBABindForcesDirectIPv4Only(t *testing.T) {
	s := sbaFixture(t)
	tunnels := []*Tunnel{xclTunnel("jp-01", 1, 20001)}
	if err := s.Bind("vless-ws", "jp-01", tunnels); err != nil {
		t.Fatal(err)
	}
	obs, _ := sbaReadCfg(t, s)["outbounds"].([]any)
	direct, _ := obs[0].(map[string]any)
	if direct["domain_strategy"] != "ipv4_only" {
		t.Fatalf("direct 出站应被限制成只走 IPv4，避免 IPv6 泄露真实地址: %v", direct)
	}
}

func TestSBABindEachInboundToDifferentExit(t *testing.T) {
	s := sbaMultiFixture(t)
	tunnels := []*Tunnel{
		xclTunnel("jp-01", 1, 20001),
		xclTunnel("us-02", 2, 20002),
	}
	if err := s.Bind("vless-ws", "jp-01", tunnels); err != nil {
		t.Fatal(err)
	}
	if err := s.Bind("vless-ws-2", "us-02", tunnels); err != nil {
		t.Fatal(err)
	}
	bound := s.boundInbounds(sbaReadCfg(t, s))
	if bound["vless-ws"] != "jp-01" || bound["vless-ws-2"] != "us-02" {
		t.Fatalf("两个入站应分别绑到不同出口，实际 %v", bound)
	}
}

func TestSBABindRebindMovesInsteadOfDuplicating(t *testing.T) {
	s := sbaFixture(t)
	tunnels := []*Tunnel{
		xclTunnel("jp-01", 1, 20001),
		xclTunnel("us-02", 2, 20002),
	}
	if err := s.Bind("vless-ws", "jp-01", tunnels); err != nil {
		t.Fatal(err)
	}
	if err := s.Bind("vless-ws", "us-02", tunnels); err != nil {
		t.Fatal(err)
	}
	cfg := sbaReadCfg(t, s)
	route, _ := cfg["route"].(map[string]any)
	rules, _ := route["rules"].([]any)
	if len(rules) != 1 {
		blob, _ := json.Marshal(rules)
		t.Fatalf("换绑应改写而不是叠加规则: %s", blob)
	}
	if s.boundInbounds(cfg)["vless-ws"] != "us-02" {
		t.Errorf("换绑后应指向 us-02")
	}
}

func TestSBABindEmptyHostUnbinds(t *testing.T) {
	s := sbaFixture(t)
	tunnels := []*Tunnel{xclTunnel("jp-01", 1, 20001)}
	if err := s.Bind("vless-ws", "jp-01", tunnels); err != nil {
		t.Fatal(err)
	}
	if err := s.Bind("vless-ws", "", tunnels); err != nil {
		t.Fatal(err)
	}
	if bound := s.boundInbounds(sbaReadCfg(t, s)); len(bound) != 0 {
		t.Fatalf("解绑后不该留规则: %v", bound)
	}
}

// sb-argo 或用户自己写的 route 规则不能被 fanout 的绑定/解绑动作误伤
func TestSBAKeepsForeignRouteRules(t *testing.T) {
	s := sbaFixture(t)
	cfg := sbaReadCfg(t, s)
	cfg["route"] = map[string]any{
		"final": "direct",
		"rules": []any{
			map[string]any{"protocol": []any{"bittorrent"}, "outbound": "direct"},
		},
	}
	if err := s.saveCfg(cfg); err != nil {
		t.Fatal(err)
	}

	tunnels := []*Tunnel{xclTunnel("jp-01", 1, 20001)}
	if err := s.Bind("vless-ws", "jp-01", tunnels); err != nil {
		t.Fatal(err)
	}
	if err := s.Bind("vless-ws", "", tunnels); err != nil {
		t.Fatal(err)
	}

	cfg = sbaReadCfg(t, s)
	route, _ := cfg["route"].(map[string]any)
	if route["final"] != "direct" {
		t.Errorf("route.final 不该被动: %v", route["final"])
	}
	rules, _ := route["rules"].([]any)
	if len(rules) != 1 {
		blob, _ := json.Marshal(rules)
		t.Fatalf("应只剩用户自己的 bittorrent 规则: %s", blob)
	}
}

func TestSBABindRejectsUnknownInbound(t *testing.T) {
	s := sbaFixture(t)
	tunnels := []*Tunnel{xclTunnel("jp-01", 1, 20001)}
	if err := s.Bind("不存在的-tag", "jp-01", tunnels); err == nil {
		t.Fatal("绑不存在的入站应报错")
	}
}

func TestSBAOnTunnelsChangedDropsDeadOutbounds(t *testing.T) {
	s := sbaFixture(t)
	tunnels := []*Tunnel{xclTunnel("jp-01", 1, 20001)}
	if err := s.Bind("vless-ws", "jp-01", tunnels); err != nil {
		t.Fatal(err)
	}
	if err := s.OnTunnelsChanged(nil); err != nil {
		t.Fatal(err)
	}
	tags := outboundTags(sbaReadCfg(t, s))
	if len(tags) != 1 || tags[0] != "direct" {
		t.Fatalf("只该剩 sb-argo 自己的出站: %v", tags)
	}
}

func TestSBANodeOpsAreReadOnly(t *testing.T) {
	s := sbaFixture(t)
	if _, err := s.CreateInbound(NewInboundSpec{}, nil); err == nil {
		t.Error("新建节点应被拒绝")
	}
	if err := s.DeleteInbounds([]int{40001}, nil); err == nil {
		t.Error("删除节点应被拒绝")
	}
	if err := s.UpdateInbound(40001, InboundPatch{}, nil); err == nil {
		t.Error("改节点应被拒绝")
	}
	if err := s.ResetClient(40001, "a", nil); err == nil {
		t.Error("重置客户端应被拒绝")
	}
}

// 节点链接由 sb-argo 生成（Argo 临时域名 fanout 推不出来），只能回读它写下的那份
func TestSBAInboundDetailReadsNodeLink(t *testing.T) {
	s := sbaFixture(t)
	link := "vless://11111111-2222-4333-8444-555555555555@abc-def.trycloudflare.com:443?" +
		"encryption=none&security=tls&type=ws#NAT-Argo"
	info := "协议: VLESS\n地址: abc-def.trycloudflare.com\n\n节点链接:\n" + link + "\n"
	if err := os.WriteFile(filepath.Join(s.stateDir, "node-info.txt"), []byte(info), 0600); err != nil {
		t.Fatal(err)
	}

	detail, err := s.InboundDetail(40001, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}
	if len(detail.Links) != 1 || detail.Links[0] != link {
		t.Fatalf("应回读 sb-argo 写下的节点链接，实际 %v", detail.Links)
	}

	links, err := s.InboundLinks([]int{40001}, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}
	if len(links) != 1 || links[0] != link {
		t.Fatalf("导出链接应与 node-info.txt 一致，实际 %v", links)
	}
}

// 没有 node-info.txt 时不该报错，只是没有链接可给
func TestSBAInboundDetailWithoutNodeInfo(t *testing.T) {
	s := sbaFixture(t)
	detail, err := s.InboundDetail(40001, "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}
	if len(detail.Links) != 0 {
		t.Fatalf("没有 node-info.txt 时不该编出链接: %v", detail.Links)
	}
}

// 坏配置不能被写进去：sing-box 起不来时 Argo 隧道还在，客户端会连到空端口
func TestSBASaveCfgKeepsOwnerReadable(t *testing.T) {
	s := sbaFixture(t)
	tunnels := []*Tunnel{xclTunnel("jp-01", 1, 20001)}
	if err := s.Bind("vless-ws", "jp-01", tunnels); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(s.cfgPath + ".fanout.tmp"); err == nil {
		t.Error("临时文件应在改名后消失")
	}
	if _, err := s.loadCfg(); err != nil {
		t.Fatalf("写回后的配置应仍然可解析: %v", err)
	}
}

func TestSBASavedMemoryReadsConfig(t *testing.T) {
	dir := t.TempDir()
	saved := filepath.Join(dir, "config.conf")
	body := "LOCAL_PORT=40001\nSB_MEMORY='24MiB'\nCF_MEMORY='24MiB'\n"
	if err := os.WriteFile(saved, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	if got := sbaSavedMemory(saved); got != "24MiB" {
		t.Fatalf("应沿用 sb-argo 保存的 SB_MEMORY，实际 %q", got)
	}
	if got := sbaSavedMemory(filepath.Join(dir, "missing.conf")); got != "18MiB" {
		t.Fatalf("读不到配置时应回落默认值，实际 %q", got)
	}
}

func TestSBAShellQuoteEscapes(t *testing.T) {
	if got := shellQuote("/a b/c"); got != "'/a b/c'" {
		t.Errorf("带空格的路径应被引起来: %s", got)
	}
	if got := shellQuote("it's"); got != `'it'\''s'` {
		t.Errorf("单引号应被转义: %s", got)
	}
}

func TestSBAPanelModePersists(t *testing.T) {
	// 这个测试会动全局的 panelState，跑完恢复成自动探测，免得影响后面的用例
	t.Cleanup(func() { configurePanel("", "") })

	dir := t.TempDir()
	if err := savePanelMode(dir, "sing-box-argo-lite"); err != nil {
		t.Fatal(err)
	}
	configurePanel(dir, "")
	if got := currentPanelMode(); got != "sing-box-argo-lite" {
		t.Fatalf("重启后应恢复界面选过的模式，实际 %q", got)
	}
	if _, err := switchPanelMode("sing-box-argo-lite-typo"); err == nil {
		t.Error("未知模式应被拒绝")
	}
}
