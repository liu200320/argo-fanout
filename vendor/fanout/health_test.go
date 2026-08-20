package main

import (
	"errors"
	"testing"
)

// exitIPStillOnVPN 决定"探测到的出口 IP 是否还说明流量走在 VPN 上"：
// 只要不是母机公网 IP 就算健康（容忍 VPN Gate 多出口/负载均衡的 IP 漂移），
// 只有退回母机 IP 才算掉线；母机 IP 未知时不强判。
func TestExitIPStillOnVPN(t *testing.T) {
	cases := []struct {
		name string
		got  string
		host string
		want bool
	}{
		{"同母机IP=掉线", "1.2.3.4", "1.2.3.4", false},
		{"不同公网IP=健康", "9.9.9.9", "1.2.3.4", true},
		{"出口IP漂移=健康", "8.8.8.8", "1.2.3.4", true},
		{"母机IP未知不误杀", "1.2.3.4", "", true},
		{"母机IP未知且相同不误杀", "9.9.9.9", "", true},
	}
	for _, c := range cases {
		if got := exitIPStillOnVPN(c.got, c.host); got != c.want {
			t.Errorf("%s: exitIPStillOnVPN(%q, %q) = %v, want %v", c.name, c.got, c.host, got, c.want)
		}
	}
}

// probeFailure.Reason 必须输出中文原因，绝不把 signal: killed 之类的英文
// 底层错误直接堆给用户（掉线通知和日志都走这个字符串）。
func TestProbeFailureReasonChinese(t *testing.T) {
	mk := func(es ...string) *probeFailure {
		errs := make([]sourceErr, 0, len(es))
		for _, e := range es {
			errs = append(errs, sourceErr{url: "https://x.example", err: errors.New(e)})
		}
		return &probeFailure{errs: errs, total: 3}
	}

	cases := []struct {
		name string
		pf   *probeFailure
		want string
	}{
		{"三接口全超时被杀", mk("https://a: signal: killed", "signal: killed", "signal: killed"),
			"全部 3 个探测接口失败：探测超时无响应（8 秒内无数据返回，探测进程被强制结束）"},
		{"DNS解析失败", mk("could not resolve host: example.com", "Temporary failure in name resolution", "no such host"),
			"全部 3 个探测接口失败：DNS 解析失败（无法解析探测服务器域名）"},
		{"连接被拒绝", mk("dial tcp 1.2.3.4:443: connect: connection refused", "connection refused", "connection refused"),
			"全部 3 个探测接口失败：连接被拒绝（探测服务器端口未开放）"},
		{"网络不可达", mk("dial tcp: lookup: network is unreachable", "network is unreachable", "network is unreachable"),
			"全部 3 个探测接口失败：网络不可达（隧道出口已完全没有外网）"},
		{"部分接口失败只算数量", mk("signal: killed", "signal: killed"),
			"2/3 个探测接口失败：探测超时无响应（8 秒内无数据返回，探测进程被强制结束）"},
		{"未知错误兜底", mk("weird internal thing"),
			"1/3 个探测接口失败：探测接口无响应"},
	}
	for _, c := range cases {
		if got := c.pf.Reason(); got != c.want {
			t.Errorf("%s: Reason() = %q, want %q", c.name, got, c.want)
		}
	}
}

// probeFailure 必须能被 errors.As 识别为 *probeFailure，tunnelHealthy 靠它
// 拿到中文原因；Error() 仍保留英文底层细节供排障。
func TestProbeFailureTypeAssert(t *testing.T) {
	var pf *probeFailure
	err := newProbeFailure(
		[]sourceErr{{url: "https://a", err: errors.New("signal: killed")}},
		3,
	)
	if !errors.As(err, &pf) {
		t.Fatalf("probeExitIPVia 的错误应能断言为 *probeFailure, got %T", err)
	}
	if pf.Reason() == "" {
		t.Fatalf("Reason() 不应为空")
	}
	if got := pf.Error(); got == "" {
		t.Fatalf("Error() 不应为空")
	}
}