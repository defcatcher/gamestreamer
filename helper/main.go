// gs-helper: WebRTC/HTTP side of GameStreamer.
//
// It is started by the Swift host app (GameStreamer.app) and talks to it over
// stdin/stdout using simple framed messages:
//
//	[1 byte type][4 bytes big-endian length][payload]
//
// host -> helper (stdin):  1 config JSON, 2 video frame, 3 audio packet, 4 host stats JSON
// helper -> host (stdout): 1 event JSON, 2 input event (binary, stage b)
//
// Logs go to stderr; the host app writes them into its log file.
package main

import (
	"bufio"
	"crypto/subtle"
	"embed"
	"encoding/binary"
	"encoding/json"
	"flag"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"github.com/pion/rtp/codecs"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

//go:embed web
var webFS embed.FS

const (
	msgConfig = 1
	msgVideo  = 2
	msgAudio  = 3
	msgStats  = 4
	msgClient = 5 // JSON forwarded to the viewer as-is

	evtJSON  = 1
	evtInput = 2
)

// Constrained Baseline: decoded in hardware everywhere, no B-frames by definition.
const h264Fmtp = "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f"

// ---------------------------------------------------------------- IPC to host

type hostIPC struct {
	mu sync.Mutex
	w  *bufio.Writer
}

func (h *hostIPC) send(t byte, payload []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	var hdr [5]byte
	hdr[0] = t
	binary.BigEndian.PutUint32(hdr[1:], uint32(len(payload)))
	_, _ = h.w.Write(hdr[:])
	_, _ = h.w.Write(payload)
	if err := h.w.Flush(); err != nil {
		log.Printf("write to host failed: %v", err)
		os.Exit(1)
	}
}

func (h *hostIPC) event(v any) {
	b, _ := json.Marshal(v)
	h.send(evtJSON, b)
}

// ---------------------------------------------------------------- session

type session struct {
	id  int
	pc  *webrtc.PeerConnection
	mu  sync.Mutex
	ctl *webrtc.DataChannel
}

func (s *session) sendCtl(v any) {
	s.mu.Lock()
	dc := s.ctl
	s.mu.Unlock()
	if dc == nil || dc.ReadyState() != webrtc.DataChannelStateOpen {
		return
	}
	b, _ := json.Marshal(v)
	_ = dc.SendText(string(b))
}

// ---------------------------------------------------------------- server

type server struct {
	host  *hostIPC
	api   *webrtc.API
	video *webrtc.TrackLocalStaticRTP
	audio *webrtc.TrackLocalStaticSample

	// Video goes through our own packetizer + pacer instead of WriteSample so a
	// big keyframe doesn't leave as one line-rate burst that routers drop.
	packetizer rtp.Packetizer
	frames     chan videoFrame
	targetKbps atomic.Int64

	// RTCP feedback counters from the viewer (logged periodically).
	nacks, plis   atomic.Int64
	rrLost        atomic.Int64
	rrFractionMax atomic.Int64

	mu         sync.Mutex
	pin        string
	cur        *session
	nextID     int
	failed     int
	lockUntil  time.Time
	lastKeyReq time.Time

	// video timing (only touched by the stdin reader goroutine)
	lastPTS uint64
}

func newServer(host *hostIPC) (*server, error) {
	m := &webrtc.MediaEngine{}
	fb := []webrtc.RTCPFeedback{
		{Type: "ccm", Parameter: "fir"},
		{Type: "nack"},
		{Type: "nack", Parameter: "pli"},
	}
	if err := m.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType: webrtc.MimeTypeH264, ClockRate: 90000, SDPFmtpLine: h264Fmtp, RTCPFeedback: fb,
		},
		PayloadType: 102,
	}, webrtc.RTPCodecTypeVideo); err != nil {
		return nil, err
	}
	if err := m.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2,
			SDPFmtpLine: "minptime=10;useinbandfec=1;stereo=1;sprop-stereo=1",
		},
		PayloadType: 111,
	}, webrtc.RTPCodecTypeAudio); err != nil {
		return nil, err
	}

	// Zero playout delay unless GS_PLAYOUT_DELAY=0 turns it off (A/B testing).
	if os.Getenv("GS_PLAYOUT_DELAY") != "0" {
		if err := m.RegisterHeaderExtension(webrtc.RTPHeaderExtensionCapability{URI: playoutDelayURI}, webrtc.RTPCodecTypeVideo); err != nil {
			return nil, err
		}
	}

	reg := &interceptor.Registry{}
	if pct := testDropPercent(); pct > 0 {
		// Registered first = closest to the wire, so NACK can still resend.
		log.Printf("TEST MODE: dropping %.1f%% of outgoing video packets", pct)
		reg.Add(dropFactory{pct: pct})
	}
	if os.Getenv("GS_PLAYOUT_DELAY") != "0" {
		reg.Add(playoutDelayFactory{})
	}
	if err := webrtc.RegisterDefaultInterceptors(m, reg); err != nil {
		return nil, err
	}

	se := webrtc.SettingEngine{}
	se.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	// Detect a dead client quickly so the host stops capturing.
	se.SetICETimeouts(3*time.Second, 8*time.Second, 1*time.Second)

	api := webrtc.NewAPI(webrtc.WithMediaEngine(m), webrtc.WithInterceptorRegistry(reg), webrtc.WithSettingEngine(se))

	video, err := webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{
		MimeType: webrtc.MimeTypeH264, ClockRate: 90000, SDPFmtpLine: h264Fmtp,
	}, "video", "gs-video")
	if err != nil {
		return nil, err
	}
	audio, err := webrtc.NewTrackLocalStaticSample(webrtc.RTPCodecCapability{
		MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2,
	}, "audio", "gs-audio") // separate stream ID: no lip-sync, so audio never delays video
	if err != nil {
		return nil, err
	}
	srv := &server{
		host: host, api: api, video: video, audio: audio,
		// 1100-byte payloads keep SRTP+UDP+IP well under Tailscale's 1280 MTU.
		packetizer: rtp.NewPacketizer(rtpPayloadMTU, 0, 0, &codecs.H264Payloader{}, rtp.NewRandomSequencer(), 90000),
		frames:     make(chan videoFrame, 16),
	}
	srv.targetKbps.Store(25000)
	go srv.pacer()
	go srv.logFeedback()
	return srv, nil
}

const rtpPayloadMTU = 1100

type videoFrame struct {
	data      []byte
	samples   uint32
	key       bool
	capWallUs uint64 // when the frame was captured (wall clock)
	encUs     uint32 // encode time
}

// pacer sends RTP packets through a token bucket: small (delta) frames leave
// immediately, large ones (keyframes) are spread at ~3x the target bitrate.
func (s *server) pacer() {
	const burstBytes = 48 * 1024
	tokens := float64(burstBytes)
	last := time.Now()
	for f := range s.frames {
		rate := float64(s.targetKbps.Load()) * 1000 / 8 * 3 // bytes/s
		if rate < 3_000_000 {
			rate = 3_000_000
		}
		pkts := s.packetizer.Packetize(f.data, f.samples)
		start := time.Now()
		for _, p := range pkts {
			now := time.Now()
			tokens += now.Sub(last).Seconds() * rate
			last = now
			if tokens > burstBytes {
				tokens = burstBytes
			}
			size := float64(len(p.Payload) + 12)
			if tokens < size {
				wait := time.Duration((size - tokens) / rate * float64(time.Second))
				time.Sleep(wait)
				now = time.Now()
				tokens += now.Sub(last).Seconds() * rate
				last = now
			}
			tokens -= size
			if err := s.video.WriteRTP(p); err != nil {
				log.Printf("video write: %v", err)
			}
		}
		// Per-frame timing for the viewer's latency meter (matched by RTP timestamp).
		if len(pkts) > 0 {
			s.mu.Lock()
			cur := s.cur
			s.mu.Unlock()
			if cur != nil {
				cur.sendCtl(map[string]any{
					"t":   "f",
					"ts":  pkts[0].Timestamp,
					"cap": float64(f.capWallUs) / 1000,
					"enc": float64(f.encUs) / 1000,
					"snd": float64(time.Now().UnixMicro()) / 1000,
				})
			}
		}
		if f.key {
			log.Printf("keyframe %d KB in %d packets, sent in %.1f ms", len(f.data)/1024, len(pkts),
				float64(time.Since(start).Microseconds())/1000)
		}
	}
}

func (s *server) logFeedback() {
	for range time.Tick(2 * time.Second) {
		n, p, l, fr := s.nacks.Swap(0), s.plis.Swap(0), s.rrLost.Load(), s.rrFractionMax.Swap(0)
		if n > 0 || p > 0 || fr > 0 {
			log.Printf("viewer feedback (2s): NACKed packets %d, PLI %d, loss up to %.1f%%, total lost %d",
				n, p, float64(fr)*100/256, l)
		}
	}
}

func (s *server) requestKeyframe(reason string) {
	s.mu.Lock()
	if time.Since(s.lastKeyReq) < 300*time.Millisecond {
		s.mu.Unlock()
		return
	}
	s.lastKeyReq = time.Now()
	s.mu.Unlock()
	s.host.event(map[string]any{"t": "keyframe", "reason": reason})
}

// checkPIN returns an HTTP status: 200 ok, 401 wrong, 429 locked out, 503 not ready.
func (s *server) checkPIN(pin string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pin == "" {
		return http.StatusServiceUnavailable
	}
	if time.Now().Before(s.lockUntil) {
		return http.StatusTooManyRequests
	}
	if subtle.ConstantTimeCompare([]byte(pin), []byte(s.pin)) == 1 {
		s.failed = 0
		return http.StatusOK
	}
	s.failed++
	if s.failed >= 5 {
		s.failed = 0
		s.lockUntil = time.Now().Add(60 * time.Second)
		log.Printf("too many wrong PINs, locked for 60s")
	}
	return http.StatusUnauthorized
}

func (s *server) handleOffer(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		PIN string `json:"pin"`
		SDP string `json:"sdp"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if code := s.checkPIN(req.PIN); code != http.StatusOK {
		log.Printf("offer from %s rejected: %d", r.RemoteAddr, code)
		http.Error(w, http.StatusText(code), code)
		return
	}

	pc, err := s.api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	s.mu.Lock()
	s.nextID++
	sess := &session{id: s.nextID, pc: pc}
	s.mu.Unlock()

	fail := func(err error) {
		log.Printf("session %d setup failed: %v", sess.id, err)
		_ = pc.Close()
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}

	if err := pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: req.SDP}); err != nil {
		fail(err)
		return
	}
	vs, err := pc.AddTrack(s.video)
	if err != nil {
		fail(err)
		return
	}
	as, err := pc.AddTrack(s.audio)
	if err != nil {
		fail(err)
		return
	}
	go s.readRTCP(vs, true)
	go s.readRTCP(as, false)

	pc.OnDataChannel(func(dc *webrtc.DataChannel) {
		switch dc.Label() {
		case "ctl":
			sess.mu.Lock()
			sess.ctl = dc
			sess.mu.Unlock()
			dc.OnMessage(func(m webrtc.DataChannelMessage) { s.handleCtl(sess, m.Data) })
		default:
			// "mouse" / "input" channels arrive in stage (b)
			dc.OnMessage(func(m webrtc.DataChannelMessage) { s.host.send(evtInput, m.Data) })
		}
	})

	pc.OnICEConnectionStateChange(func(st webrtc.ICEConnectionState) {
		log.Printf("session %d ICE %s", sess.id, st)
	})
	pc.OnConnectionStateChange(func(st webrtc.PeerConnectionState) {
		log.Printf("session %d state %s", sess.id, st)
		switch st {
		case webrtc.PeerConnectionStateConnected:
			s.mu.Lock()
			isCur := s.cur == sess
			s.mu.Unlock()
			if isCur {
				s.host.event(map[string]any{"t": "connected", "id": sess.id, "remote": r.RemoteAddr})
				s.requestKeyframe("connected")
			}
		case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed:
			s.mu.Lock()
			isCur := s.cur == sess
			if isCur {
				s.cur = nil
			}
			s.mu.Unlock()
			if isCur {
				s.host.event(map[string]any{"t": "disconnected", "id": sess.id})
			}
			if st == webrtc.PeerConnectionStateFailed {
				_ = pc.Close()
			}
		}
	})

	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		fail(err)
		return
	}
	gather := webrtc.GatheringCompletePromise(pc)
	if err := pc.SetLocalDescription(answer); err != nil {
		fail(err)
		return
	}
	select {
	case <-gather:
	case <-time.After(3 * time.Second):
		log.Printf("session %d: ICE gathering timeout, answering with what we have", sess.id)
	}

	// Only one viewer at a time: the new one replaces the old one.
	s.mu.Lock()
	old := s.cur
	s.cur = sess
	s.mu.Unlock()
	if old != nil {
		log.Printf("session %d replaces session %d", sess.id, old.id)
		go old.pc.Close()
	}

	log.Printf("session %d answered for %s", sess.id, r.RemoteAddr)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"sdp": pc.LocalDescription().SDP})
}

func (s *server) readRTCP(sender *webrtc.RTPSender, isVideo bool) {
	for {
		pkts, _, err := sender.ReadRTCP()
		if err != nil {
			return
		}
		if !isVideo {
			continue
		}
		for _, p := range pkts {
			switch pk := p.(type) {
			case *rtcp.PictureLossIndication:
				s.plis.Add(1)
				s.requestKeyframe("pli")
			case *rtcp.FullIntraRequest:
				s.plis.Add(1)
				s.requestKeyframe("fir")
			case *rtcp.TransportLayerNack:
				for _, pair := range pk.Nacks {
					s.nacks.Add(int64(len(pair.PacketList())))
				}
			case *rtcp.ReceiverReport:
				for _, r := range pk.Reports {
					s.rrLost.Store(int64(r.TotalLost))
					if int64(r.FractionLost) > s.rrFractionMax.Load() {
						s.rrFractionMax.Store(int64(r.FractionLost))
					}
				}
			}
		}
	}
}

func (s *server) handleCtl(sess *session, data []byte) {
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		return
	}
	switch m["t"] {
	case "ping":
		m["t"] = "pong"
		m["hw"] = float64(time.Now().UnixMicro()) / 1000 // host wall clock, ms
		sess.sendCtl(m)
	case "bitrate":
		if kbps, ok := m["kbps"].(float64); ok && kbps >= 1000 && kbps <= 150000 {
			s.host.event(map[string]any{"t": "bitrate", "kbps": int(kbps)})
		}
	case "keyframe":
		s.requestKeyframe("client")
	case "clientstats":
		log.Printf("viewer stats: %s", data)
	case "clientdiag":
		log.Printf("viewer DIAG: %s", data)
	default:
		// forward anything else to the host as-is
		s.host.event(m)
	}
}

// ---------------------------------------------------------------- stdin from host

func (s *server) readHost(r io.Reader) {
	br := bufio.NewReaderSize(r, 1<<20)
	var hdr [5]byte
	buf := make([]byte, 0, 1<<20)
	for {
		if _, err := io.ReadFull(br, hdr[:]); err != nil {
			log.Printf("host closed stdin (%v), exiting", err)
			os.Exit(0)
		}
		n := int(binary.BigEndian.Uint32(hdr[1:]))
		if n > 64<<20 {
			log.Printf("bogus message length %d", n)
			os.Exit(1)
		}
		if cap(buf) < n {
			buf = make([]byte, n)
		}
		buf = buf[:n]
		if _, err := io.ReadFull(br, buf); err != nil {
			log.Printf("host stream broken: %v", err)
			os.Exit(1)
		}
		switch hdr[0] {
		case msgConfig:
			var cfg struct {
				PIN string `json:"pin"`
			}
			if err := json.Unmarshal(buf, &cfg); err == nil {
				s.mu.Lock()
				changed := s.pin != "" && s.pin != cfg.PIN
				s.pin = cfg.PIN
				cur := s.cur
				s.mu.Unlock()
				if changed && cur != nil {
					log.Printf("PIN changed, dropping current session")
					go cur.pc.Close()
				}
			}
		case msgClient:
			s.mu.Lock()
			cur := s.cur
			s.mu.Unlock()
			var m map[string]any
			if cur != nil && json.Unmarshal(buf, &m) == nil {
				cur.sendCtl(m)
			}
		case msgVideo:
			s.writeVideo(buf)
		case msgAudio:
			s.writeAudio(buf)
		case msgStats:
			s.mu.Lock()
			cur := s.cur
			s.mu.Unlock()
			var st map[string]any
			if json.Unmarshal(buf, &st) == nil {
				if t, ok := st["targetKbps"].(float64); ok && t > 0 {
					s.targetKbps.Store(int64(t))
				}
			}
			if cur != nil && st != nil {
				st["t"] = "hoststats"
				cur.sendCtl(st)
			}
		}
	}
}

// video payload: [8 pts µs][1 flags][8 capture wall-clock µs][4 encode µs][Annex-B H.264]
func (s *server) writeVideo(b []byte) {
	if len(b) < 21 {
		return
	}
	pts := binary.BigEndian.Uint64(b[:8])
	dur := 16667 * time.Microsecond
	if s.lastPTS != 0 && pts > s.lastPTS {
		d := time.Duration(pts-s.lastPTS) * time.Microsecond
		if d > time.Millisecond && d < time.Second {
			dur = d
		}
	}
	s.lastPTS = pts
	data := make([]byte, len(b)-21) // buf is reused by the reader
	copy(data, b[21:])
	f := videoFrame{
		data: data, samples: uint32(dur.Seconds() * 90000), key: b[8]&1 == 1,
		capWallUs: binary.BigEndian.Uint64(b[9:17]),
		encUs:     binary.BigEndian.Uint32(b[17:21]),
	}
	select {
	case s.frames <- f:
	default:
		log.Printf("pacer queue full, dropping frame (keyframe=%v)", f.key)
		if !f.key {
			s.requestKeyframe("drop")
		}
	}
}

// audio payload: [8 bytes pts in µs][2 bytes duration in 1/48000 s][Opus packet]
func (s *server) writeAudio(b []byte) {
	if len(b) < 10 {
		return
	}
	samples := binary.BigEndian.Uint16(b[8:10])
	dur := time.Duration(samples) * time.Second / 48000
	if err := s.audio.WriteSample(media.Sample{Data: b[10:], Duration: dur}); err != nil {
		log.Printf("audio write: %v", err)
	}
}

// ---------------------------------------------------------------- HTTP

func noCache(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		h.ServeHTTP(w, r)
	})
}

func main() {
	port := flag.Int("port", 8765, "HTTP port")
	flag.Parse()
	log.SetFlags(log.Ltime | log.Lmicroseconds)

	host := &hostIPC{w: bufio.NewWriterSize(os.Stdout, 64<<10)}
	srv, err := newServer(host)
	if err != nil {
		log.Fatalf("init: %v", err)
	}

	sub, _ := fs.Sub(webFS, "web")
	mux := http.NewServeMux()
	mux.Handle("/", noCache(http.FileServer(http.FS(sub))))
	mux.HandleFunc("/api/offer", srv.handleOffer)

	// Listen on localhost (local tests and `tailscale serve`) and on the
	// addresses Tailscale reports. Never on LAN/internet interfaces.
	(&listeners{port: *port, handler: mux, host: host}).run()

	srv.readHost(os.Stdin)
}
