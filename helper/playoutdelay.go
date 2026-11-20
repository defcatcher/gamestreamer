package main

// Adds the "playout-delay" RTP header extension with min = max = 0 to every
// outgoing video packet. Chrome/Edge then render each frame as soon as it is
// decoded instead of smoothing playback through the jitter buffer (the mode
// cloud-gaming services use). Saves roughly 1-2 frames of latency.

import (
	"github.com/pion/interceptor"
	"github.com/pion/rtp"
)

const playoutDelayURI = "http://www.webrtc.org/experiments/rtp-hdrext/playout-delay"

type playoutDelayFactory struct{}

func (playoutDelayFactory) NewInterceptor(string) (interceptor.Interceptor, error) {
	return &playoutDelayInterceptor{}, nil
}

type playoutDelayInterceptor struct{ interceptor.NoOp }

func (*playoutDelayInterceptor) BindLocalStream(info *interceptor.StreamInfo, w interceptor.RTPWriter) interceptor.RTPWriter {
	if info.MimeType != "video/H264" {
		return w
	}
	id := 0
	for _, e := range info.RTPHeaderExtensions {
		if e.URI == playoutDelayURI {
			id = e.ID
		}
	}
	if id == 0 {
		return w // the viewer did not negotiate it
	}
	// 12-bit min and 12-bit max delay in 10 ms units: both zero.
	payload := []byte{0, 0, 0}
	return interceptor.RTPWriterFunc(func(h *rtp.Header, p []byte, a interceptor.Attributes) (int, error) {
		if err := h.SetExtension(uint8(id), payload); err != nil {
			return 0, err
		}
		return w.Write(h, p, a)
	})
}
