package main

// Test-only: GS_TEST_DROP=<percent> randomly drops outgoing video RTP packets
// *after* the NACK responder has buffered them, imitating loss on the Internet
// path so retransmission/recovery can be reproduced locally.

import (
	"math/rand/v2"
	"os"
	"strconv"

	"github.com/pion/interceptor"
	"github.com/pion/rtp"
)

func testDropPercent() float64 {
	v, _ := strconv.ParseFloat(os.Getenv("GS_TEST_DROP"), 64)
	return v
}

type dropFactory struct{ pct float64 }

func (f dropFactory) NewInterceptor(string) (interceptor.Interceptor, error) {
	return &dropInterceptor{pct: f.pct}, nil
}

type dropInterceptor struct {
	interceptor.NoOp
	pct float64
}

func (d *dropInterceptor) BindLocalStream(info *interceptor.StreamInfo, w interceptor.RTPWriter) interceptor.RTPWriter {
	if info.MimeType != "video/H264" {
		return w
	}
	return interceptor.RTPWriterFunc(func(h *rtp.Header, payload []byte, a interceptor.Attributes) (int, error) {
		if rand.Float64()*100 < d.pct {
			return len(payload), nil
		}
		return w.Write(h, payload, a)
	})
}
