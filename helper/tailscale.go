package main

// Which addresses to serve on: localhost (for `tailscale serve` and local
// tests) plus the addresses Tailscale itself reports. We deliberately do NOT
// guess by the 100.64.0.0/10 range: that is CGNAT space, also used by other
// VPNs and by some ISPs on the WAN interface, where the page must never be
// reachable.

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

var tailscaleCLIPaths = []string{
	"/usr/local/bin/tailscale",
	"/opt/homebrew/bin/tailscale",
	"/Applications/Tailscale.app/Contents/MacOS/Tailscale",
}

func tailscaleCLI() string {
	for _, p := range tailscaleCLIPaths {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return ""
}

// tailscaleIPv4s asks the Tailscale daemon for this machine's IPv4 addresses
// and keeps only those that are actually assigned to a local interface.
func tailscaleIPv4s() []string {
	cli := tailscaleCLI()
	if cli == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, cli, "ip", "-4").Output()
	if err != nil {
		return nil
	}
	local := map[string]bool{}
	if addrs, err := net.InterfaceAddrs(); err == nil {
		for _, a := range addrs {
			if ipn, ok := a.(*net.IPNet); ok {
				local[ipn.IP.String()] = true
			}
		}
	}
	var ips []string
	for _, line := range strings.Fields(string(out)) {
		ip := net.ParseIP(line)
		if ip == nil || ip.To4() == nil || !local[ip.String()] {
			continue
		}
		ips = append(ips, ip.String())
	}
	return ips
}

// listeners serves the page on localhost and on Tailscale addresses, picking
// up addresses that appear later (e.g. Tailscale started after the app).
type listeners struct {
	port    int
	handler http.Handler
	host    *hostIPC

	mu     sync.Mutex
	active map[string]bool
}

func (l *listeners) add(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.active[ip] {
		return false
	}
	addr := net.JoinHostPort(ip, fmt.Sprint(l.port))
	ln, err := net.Listen("tcp4", addr)
	if err != nil {
		log.Printf("listen %s: %v", addr, err)
		return false
	}
	l.active[ip] = true
	go func() {
		log.Printf("http on %s stopped: %v", addr, http.Serve(ln, l.handler))
		l.mu.Lock()
		delete(l.active, ip)
		l.mu.Unlock()
	}()
	return true
}

func (l *listeners) list() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []string
	for ip := range l.active {
		out = append(out, net.JoinHostPort(ip, fmt.Sprint(l.port)))
	}
	return out
}

func (l *listeners) run() {
	l.active = map[string]bool{}
	l.add("127.0.0.1")
	refresh := func() {
		changed := false
		for _, ip := range tailscaleIPv4s() {
			if l.add(ip) {
				changed = true
			}
		}
		if changed || len(l.list()) == 1 {
			log.Printf("listening on %v", l.list())
		}
	}
	refresh()
	if tailscaleCLI() == "" {
		log.Printf("tailscale CLI not found; serving on localhost only (tailscale serve still works)")
	}
	l.host.event(map[string]any{"t": "ready", "listen": l.list()})
	go func() {
		for range time.Tick(30 * time.Second) {
			refresh()
		}
	}()
}
