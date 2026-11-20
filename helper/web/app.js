'use strict';
// GameStreamer web client: video + stats + mouse/keyboard over DataChannels.

const $ = (id) => document.getElementById(id);

// UI language: Russian if the browser prefers it, English otherwise.
// ?lang=en / ?lang=ru overrides the browser's primary language.
const LANG = new URLSearchParams(location.search).get('lang') || navigator.language || 'en';
const RU = /^ru\b/i.test(LANG);
const T = (ru, en) => (RU ? ru : en);
const video = $('video');

let pc = null;
let ctl = null;
let mouseDc = null; // unordered, no retransmits: mouse movement
let inputDc = null; // reliable, ordered: buttons, wheel, keys, mode
let pin = localStorage.getItem('gs.pin') || '';
let wantConnected = false;
let reconnectTimer = null;
let hudMode = 1; // 0 off, 1 short, 2 detailed
let rtt = null;
let hostStats = null;
let prev = null; // previous getStats sample for deltas
let pingTimer = null;
let statsTimer = null;
let statsTick = 0;
const DIAG = new URLSearchParams(location.search).has('diag');

$('pin').value = pin;

// Static page texts.
document.documentElement.lang = RU ? 'ru' : 'en';
$('btnConnect').textContent = T('Подключиться', 'Connect');
$('unmute').textContent = T('🔇 Браузер выключил звук — кликни, чтобы включить', '🔇 The browser muted the sound — click to enable');
$('btnFull').textContent = T('Полный экран', 'Fullscreen');
$('bitrateLabel').textContent = T('Битрейт', 'Bitrate');
$('mbps').textContent = T('Мбит/с', 'Mbit/s');
$('btnHud').textContent = T('Статистика', 'Stats');
$('hint').textContent = T('Ctrl+Alt+M — мышь меню/камера · Ctrl+Alt+F — полный экран · Ctrl+Alt+S — статистика',
  'Ctrl+Alt+M — mouse menu/camera · Ctrl+Alt+F — fullscreen · Ctrl+Alt+S — stats');

// ------------------------------------------------------------------ UI helpers

function showStatus(text) {
  const el = $('status');
  if (!text) { el.classList.add('hidden'); return; }
  el.textContent = text;
  el.classList.remove('hidden');
}

function showLogin(err) {
  $('login').classList.remove('hidden');
  $('toolbar').classList.add('hidden');
  $('loginError').textContent = err || '';
  $('pin').focus();
}

function hideLogin() {
  $('login').classList.add('hidden');
  $('toolbar').classList.remove('hidden');
}

function setHudMode(m) {
  hudMode = m;
  $('hud').classList.toggle('hidden', hudMode === 0);
}

async function toggleFullscreen() {
  if (document.fullscreenElement) {
    await document.exitFullscreen();
    return;
  }
  await document.documentElement.requestFullscreen({ navigationUI: 'hide' });
  // Keyboard Lock (Esc / Alt+Tab / Win go to the game) works only over HTTPS.
  if (navigator.keyboard && navigator.keyboard.lock) {
    navigator.keyboard.lock().catch(() => {});
  }
}

document.addEventListener('fullscreenchange', () => {
  if (!document.fullscreenElement && navigator.keyboard && navigator.keyboard.unlock) {
    navigator.keyboard.unlock();
  }
});

$('btnFull').onclick = () => toggleFullscreen();
$('btnHud').onclick = () => setHudMode((hudMode + 1) % 3);
$('bitrate').onchange = (e) => sendCtl({ t: 'bitrate', kbps: Number(e.target.value) });

// Client-only hotkeys (not forwarded to the host).
const CLIENT_HOTKEYS = new Set(['KeyF', 'KeyS', 'KeyM']);
window.addEventListener('keydown', (e) => {
  if (!(e.ctrlKey && e.altKey && CLIENT_HOTKEYS.has(e.code))) return;
  e.preventDefault();
  if (e.repeat) return;
  if (e.code === 'KeyF') toggleFullscreen();
  if (e.code === 'KeyS') setHudMode((hudMode + 1) % 3);
  if (e.code === 'KeyM') setMouseMode(mouseMode === 1 ? 0 : 1);
}, true);

$('loginForm').addEventListener('submit', (e) => {
  e.preventDefault();
  pin = $('pin').value.trim();
  if (!pin) return;
  connect();
});

// ------------------------------------------------------------------ connection

function sendCtl(obj) {
  if (ctl && ctl.readyState === 'open') ctl.send(JSON.stringify(obj));
}

function teardown() {
  clearInterval(pingTimer);
  clearInterval(statsTimer);
  if (pc) { try { pc.close(); } catch (_) {} }
  pc = null; ctl = null; mouseDc = null; inputDc = null;
  audioEl.srcObject = null;
  waDetach();
  prev = null; rtt = null; hostStats = null;
  pressedKeys.clear();
  buttonsDown.clear();
}

function scheduleReconnect(why) {
  if (!wantConnected) return;
  clearTimeout(reconnectTimer);
  showStatus(`${why} — ${T('переподключение…', 'reconnecting…')}`);
  reconnectTimer = setTimeout(connect, 1500);
}

function waitIceGathering(conn, timeoutMs) {
  if (conn.iceGatheringState === 'complete') return Promise.resolve();
  return new Promise((resolve) => {
    const t = setTimeout(resolve, timeoutMs);
    conn.addEventListener('icegatheringstatechange', () => {
      if (conn.iceGatheringState === 'complete') { clearTimeout(t); resolve(); }
    });
  });
}

// ------------------------------------------------------------------ playback
// <video> is always muted (so it may autoplay without a click).
//
// Sound: by default we take the Opus packets straight from the receiver
// (encoded insertable streams), decode them with WebCodecs and play them with
// Web Audio. This bypasses WebRTC's own audio output, which on some Windows
// browsers received packets but never played them, and lets us keep the audio
// buffer small. `?webrtcaudio` switches back to the standard <audio> path.
video.muted = true;

const WEBAUDIO = !new URLSearchParams(location.search).has('webrtcaudio')
  && typeof AudioDecoder !== 'undefined'
  && typeof RTCRtpReceiver !== 'undefined' && 'createEncodedStreams' in RTCRtpReceiver.prototype;
const INSERTABLE = DIAG || WEBAUDIO;

const audioEl = document.createElement('audio');
audioEl.autoplay = true;
audioEl.style.display = 'none';
document.body.appendChild(audioEl);

const wa = {
  ctx: null, gain: null, dec: null, ts: 0, next: 0,
  packets: 0, decoded: 0, played: 0, underruns: 0, dropped: 0, errors: 0, lastError: null,
};
const WA_LEAD = 0.03;     // target audio buffer, s
const WA_MAX_LEAD = 0.07; // if the buffer grows past this, drop a packet to catch up

function waContext() {
  if (!wa.ctx) {
    wa.ctx = new AudioContext({ latencyHint: 'interactive', sampleRate: 48000 });
    wa.gain = wa.ctx.createGain();
    wa.gain.connect(wa.ctx.destination);
  }
  if (wa.ctx.state !== 'running') {
    wa.ctx.resume().then(() => setUnmuteBanner(false)).catch(() => {});
  }
  return wa.ctx;
}

function waAttach(receiver) {
  waContext();
  waDetach();
  wa.ts = 0;
  wa.next = 0;
  wa.dec = new AudioDecoder({
    output: waPlay,
    error: (e) => { wa.errors++; wa.lastError = String(e); },
  });
  wa.dec.configure({ codec: 'opus', sampleRate: 48000, numberOfChannels: 2 });
  const dec = wa.dec;
  const { readable } = receiver.createEncodedStreams();
  readable.pipeTo(new WritableStream({
    write(f) {
      wa.packets++;
      if (dec.state !== 'configured') return;
      try {
        dec.decode(new EncodedAudioChunk({ type: 'key', timestamp: wa.ts, data: f.data }));
      } catch (e) { wa.errors++; wa.lastError = String(e); }
      wa.ts += 10000;
    },
  })).catch(() => {});
  setTimeout(() => setUnmuteBanner(!wa.ctx || wa.ctx.state !== 'running'), 500);
}

function waDetach() {
  if (wa.dec) { try { wa.dec.close(); } catch (_) {} }
  wa.dec = null;
}

function waPlay(d) {
  wa.decoded++;
  const ctx = wa.ctx;
  if (!ctx || ctx.state !== 'running') { d.close(); return; }
  const buf = ctx.createBuffer(d.numberOfChannels, d.numberOfFrames, d.sampleRate);
  const tmp = new Float32Array(d.numberOfFrames);
  for (let c = 0; c < d.numberOfChannels; c++) {
    d.copyTo(tmp, { planeIndex: c, format: 'f32-planar' });
    buf.copyToChannel(tmp, c);
  }
  d.close();
  const now = ctx.currentTime;
  if (wa.next < now + 0.002) {
    if (wa.next > 0) wa.underruns++;
    wa.next = now + WA_LEAD;
  } else if (wa.next > now + WA_MAX_LEAD) {
    wa.dropped++; // we fell behind (e.g. tab was hidden): skip to catch up
    return;
  }
  const src = ctx.createBufferSource();
  src.buffer = buf;
  src.connect(wa.gain);
  src.start(wa.next);
  wa.next += buf.duration;
  wa.played++;
}

function startPlayback() {
  video.play().catch(() => {});
  if (WEBAUDIO || !audioEl.srcObject) return;
  audioEl.play().then(() => setUnmuteBanner(false)).catch(() => setUnmuteBanner(true));
}

function setUnmuteBanner(on) {
  $('unmute').classList.toggle('hidden', !on);
}

function unmute() {
  if (WEBAUDIO) {
    if (wa.ctx && wa.ctx.state !== 'running') wa.ctx.resume().then(() => setUnmuteBanner(false)).catch(() => {});
    return;
  }
  if (!audioEl.srcObject || !audioEl.paused) return;
  audioEl.play().then(() => setUnmuteBanner(false)).catch(() => {});
}
window.addEventListener('pointerdown', unmute, true);
window.addEventListener('keydown', unmute, true);

function tuneReceiver(receiver) {
  // Ask Chrome to keep the jitter buffer as small as possible.
  try { receiver.jitterBufferTarget = 0; } catch (_) {}
  try { receiver.playoutDelayHint = 0; } catch (_) {}
}

async function connect() {
  clearTimeout(reconnectTimer);
  wantConnected = true;
  teardown();
  showStatus(T('Подключение…', 'Connecting…'));

  const conn = new RTCPeerConnection(INSERTABLE
    ? { bundlePolicy: 'max-bundle', encodedInsertableStreams: true }
    : { bundlePolicy: 'max-bundle' });
  pc = conn;
  conn.addTransceiver('video', { direction: 'recvonly' });
  conn.addTransceiver('audio', { direction: 'recvonly' });

  ctl = conn.createDataChannel('ctl', { ordered: true });
  ctl.onmessage = (e) => onCtl(JSON.parse(e.data));
  mouseDc = conn.createDataChannel('mouse', { ordered: false, maxRetransmits: 0 });
  inputDc = conn.createDataChannel('input', { ordered: true });
  inputDc.onopen = () => sendMode();

  conn.ontrack = (ev) => {
    tuneReceiver(ev.receiver);
    if (ev.track.kind === 'video') {
      video.srcObject = new MediaStream([ev.track]);
      startLatencyMeter();
      if (DIAG) diagTap(ev.receiver);
      else if (INSERTABLE) {
        // With insertable streams enabled every receiver must be piped through.
        const s = ev.receiver.createEncodedStreams();
        s.readable.pipeTo(s.writable).catch(() => {});
      }
    } else if (WEBAUDIO) {
      waAttach(ev.receiver);
    } else {
      if (INSERTABLE) {
        const s = ev.receiver.createEncodedStreams();
        s.readable.pipeTo(s.writable).catch(() => {});
      }
      audioEl.srcObject = new MediaStream([ev.track]);
    }
    startPlayback();
  };

  conn.onconnectionstatechange = () => {
    if (pc !== conn) return;
    const st = conn.connectionState;
    if (st === 'connected') {
      showStatus('');
      hideLogin();
      clockOffset = null; clockRtt = Infinity;
      // Fast pings at first to lock the clock offset, then once a second.
      for (let i = 1; i <= 5; i++) setTimeout(() => sendCtl({ t: 'ping', ts: performance.now() }), i * 150);
      pingTimer = setInterval(() => sendCtl({ t: 'ping', ts: performance.now() }), 1000);
      statsTimer = setInterval(pollStats, 1000);
    } else if (st === 'failed' || st === 'disconnected') {
      scheduleReconnect(T('Связь потеряна', 'Connection lost'));
    } else if (st === 'closed') {
      scheduleReconnect(T('Соединение закрыто', 'Connection closed'));
    }
  };

  try {
    await conn.setLocalDescription(await conn.createOffer());
    await waitIceGathering(conn, 1500);
    const res = await fetch('api/offer', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pin, sdp: conn.localDescription.sdp }),
    });
    if (pc !== conn) return;
    if (res.status === 401 || res.status === 429) {
      wantConnected = false;
      teardown();
      showStatus('');
      showLogin(res.status === 401 ? T('Неверный PIN', 'Wrong PIN') : T('Слишком много попыток, подожди минуту', 'Too many attempts, wait a minute'));
      return;
    }
    if (!res.ok) throw new Error(`${T('сервер ответил', 'server replied')} ${res.status}`);
    localStorage.setItem('gs.pin', pin);
    const ans = await res.json();
    await conn.setRemoteDescription({ type: 'answer', sdp: ans.sdp });
    hideLogin();
  } catch (err) {
    console.error(err);
    if (pc === conn) scheduleReconnect(`${T('Ошибка', 'Error')}: ${err.message}`);
  }
}

// ------------------------------------------------------------------ latency meter
// The host sends capture/encode/send times for every frame (wall clock, ms),
// keyed by RTP timestamp. requestVideoFrameCallback tells us when that frame
// arrived and when it will be on screen. Clocks are aligned with the pings.

const frameInfo = new Map(); // rtp ts -> {cap, enc, snd}
let clockOffset = null;      // host wall clock minus our wall clock, ms
let clockRtt = Infinity;
const latSamples = [];       // {total, host, net, client}
let lat = null;              // averages over the last second

function wallNow() { return performance.timeOrigin + performance.now(); }

function onPong(m) {
  const t1 = performance.now();
  rtt = t1 - m.ts;
  if (m.hw === undefined) return;
  // Keep the estimate from the fastest recent ping (least queueing).
  if (rtt <= clockRtt * 1.2 || clockOffset === null) {
    clockRtt = Math.min(rtt, clockRtt);
    clockOffset = m.hw - (performance.timeOrigin + (m.ts + t1) / 2);
  }
  clockRtt *= 1.05; // slowly forget, so a better path can win later
}

function onFrameVisible(_now, md) {
  if (video.srcObject) video.requestVideoFrameCallback(onFrameVisible);
  if (clockOffset === null || md.rtpTimestamp === undefined) return;
  const info = frameInfo.get(md.rtpTimestamp);
  if (!info) return;
  frameInfo.delete(md.rtpTimestamp);
  const cap = info.cap - clockOffset;
  const snd = info.snd - clockOffset;
  const recv = performance.timeOrigin + (md.receiveTime || md.presentationTime);
  const shown = performance.timeOrigin + md.expectedDisplayTime;
  latSamples.push({ total: shown - cap, host: snd - cap, enc: info.enc, net: recv - snd, client: shown - recv });
  if (latSamples.length > 240) latSamples.shift();
}

function startLatencyMeter() {
  if ('requestVideoFrameCallback' in HTMLVideoElement.prototype) video.requestVideoFrameCallback(onFrameVisible);
}

function takeLatency() {
  if (!latSamples.length) return null;
  const avg = (k) => latSamples.reduce((a, x) => a + x[k], 0) / latSamples.length;
  const totals = latSamples.map((x) => x.total).sort((a, b) => a - b);
  const r = {
    total: Math.round(avg('total')), p95: Math.round(totals[Math.floor(totals.length * 0.95)]),
    host: +avg('host').toFixed(1), enc: +avg('enc').toFixed(1), net: +avg('net').toFixed(1), client: +avg('client').toFixed(1),
    n: latSamples.length,
  };
  latSamples.length = 0;
  return r;
}

function onCtl(m) {
  if (m.t === 'f') {
    frameInfo.set(m.ts, m);
    if (frameInfo.size > 600) frameInfo.delete(frameInfo.keys().next().value);
  } else if (m.t === 'pong') {
    onPong(m);
  } else if (m.t === 'cursor') {
    // The game on the Mac grabbed/released the mouse: follow it automatically.
    if (m.captured && mouseMode === 0) {
      autoCamera = true;
      setMouseMode(1, true);
    } else if (!m.captured && mouseMode === 1 && autoCamera) {
      autoCamera = false;
      setMouseMode(0, true);
    }
  } else if (m.t === 'hoststats') {
    hostStats = m;
    const sel = $('bitrate');
    if (m.targetKbps && document.activeElement !== sel) sel.value = String(m.targetKbps);
  }
}

// ------------------------------------------------------------------ stats

let audioOutputs = null;
if (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
  navigator.mediaDevices.enumerateDevices()
    .then((d) => { audioOutputs = d.filter((x) => x.kind === 'audiooutput').length; })
    .catch(() => {});
}

async function pollStats() {
  if (!pc) return;
  const report = await pc.getStats();
  let v = null, a = null, transport = null;
  const byId = new Map();
  report.forEach((s) => {
    byId.set(s.id, s);
    if (s.type === 'inbound-rtp' && s.kind === 'video') v = s;
    if (s.type === 'inbound-rtp' && s.kind === 'audio') a = s;
    if (s.type === 'transport') transport = s;
  });
  const pair = transport && byId.get(transport.selectedCandidatePairId);
  const now = performance.now();
  const cur = { now, v, a };

  const lines = [];
  const pingMs = rtt != null ? rtt.toFixed(0) : '—';
  let fps = '—', mbps = '—';
  if (v) {
    fps = v.framesPerSecond != null ? v.framesPerSecond.toFixed(0) : '—';
    if (prev && prev.v) {
      const dt = (now - prev.now) / 1000;
      mbps = (((v.bytesReceived - prev.v.bytesReceived) * 8) / dt / 1e6).toFixed(1);
    }
  }
  lat = takeLatency() || lat;
  const latTxt = lat ? `${T('задержка', 'latency')} ${lat.total} ms · ` : '';
  lines.push(`${latTxt}${T('пинг', 'ping')} ${pingMs} ms · ${fps} fps · ${mbps} Mbit/s · ${T('мышь', 'mouse')}: ${modeName()}`);
  if (hudMode === 2 && lat) {
    lines.push(T(`задержка: Мак ${lat.host} (кодир. ${lat.enc}) · сеть ${lat.net} · браузер ${lat.client} · p95 ${lat.p95} мс`,
      `latency: host ${lat.host} (encode ${lat.enc}) · network ${lat.net} · browser ${lat.client} · p95 ${lat.p95} ms`));
  }

  if (hudMode === 2 && v) {
    const codec = byId.get(v.codecId);
    const dFrames = prev && prev.v ? v.framesDecoded - prev.v.framesDecoded : 0;
    const decMs = prev && prev.v && dFrames > 0
      ? (((v.totalDecodeTime - prev.v.totalDecodeTime) / dFrames) * 1000).toFixed(1) : '—';
    const dEmit = prev && prev.v ? v.jitterBufferEmittedCount - prev.v.jitterBufferEmittedCount : 0;
    const jbMs = prev && prev.v && dEmit > 0
      ? (((v.jitterBufferDelay - prev.v.jitterBufferDelay) / dEmit) * 1000).toFixed(1) : '—';
    const lost = v.packetsLost != null ? v.packetsLost : 0;
    const dropped = v.framesDropped != null ? v.framesDropped : 0;
    lines.push(`${T('видео', 'video')} ${v.frameWidth || '?'}×${v.frameHeight || '?'} ${codec ? codec.mimeType.replace('video/', '') : ''}`);
    lines.push(`${T('декодер', 'decoder')} ${v.decoderImplementation || '?'}${v.powerEfficientDecoder ? T(' (аппаратный)', ' (hardware)') : ''}`);
    lines.push(`${T('декод', 'decode')} ${decMs} ms · ${T('джиттер-буфер', 'jitter buffer')} ${jbMs} ms`);
    lines.push(`${T('потери пакетов', 'packets lost')} ${lost} · ${T('пропущено кадров', 'frames dropped')} ${dropped} · NACK ${v.nackCount || 0} · PLI ${v.pliCount || 0}`);
    if (pair) {
      const local = byId.get(pair.localCandidateId);
      const remote = byId.get(pair.remoteCandidateId);
      const ice = pair.currentRoundTripTime != null ? (pair.currentRoundTripTime * 1000).toFixed(0) : '—';
      lines.push(`ICE RTT ${ice} ms · ${local ? local.candidateType : '?'} → ${remote ? `${remote.address}:${remote.port}` : '?'}`);
    }
    if (a) {
      const dA = prev && prev.a ? a.jitterBufferEmittedCount - prev.a.jitterBufferEmittedCount : 0;
      const ajb = prev && prev.a && dA > 0 ? (((a.jitterBufferDelay - prev.a.jitterBufferDelay) / dA) * 1000).toFixed(0) : '—';
      const buf = WEBAUDIO && wa.ctx ? Math.round((wa.next - wa.ctx.currentTime) * 1000) : ajb;
      lines.push(`${T('звук', 'audio')} (${WEBAUDIO ? 'webaudio' : 'webrtc'}): ${T('буфер', 'buffer')} ${buf} ms · ${T('потери', 'lost')} ${a.packetsLost || 0} · ${T('провалы', 'underruns')} ${wa.underruns} · ${T('источник', 'source')}: ${hostStats ? hostStats.audioSrc : '?'}`);
    }
    if (hostStats) {
      const h = hostStats;
      lines.push(T(`хост: захват ${h.capFps} fps · кодирование ${h.encFps} fps, ${h.encMs} мс · ${h.kbps} кбит/с (цель ${h.targetKbps})`,
        `host: capture ${h.capFps} fps · encode ${h.encFps} fps, ${h.encMs} ms · ${h.kbps} kbit/s (target ${h.targetKbps})`));
      if (h.err) lines.push(`${T('хост: ОШИБКА', 'host: ERROR')} ${h.err}`);
    }
  } else if (hostStats && hostStats.err) {
    lines.push(`${T('хост: ОШИБКА', 'host: ERROR')} ${hostStats.err}`);
  }

  $('hud').textContent = lines.join('\n');

  // Every 2 s report a summary to the host log for remote troubleshooting.
  statsTick = (statsTick + 1) % 2;
  if (statsTick === 0) {
    const local = pair && byId.get(pair.localCandidateId);
    sendCtl({
      t: 'clientstats',
      connected: pc.connectionState,
      videoPlaying: !video.paused,
      audioPath: WEBAUDIO ? 'webaudio' : 'element',
      audioCtx: wa.ctx ? wa.ctx.state : null,
      audioOutLatencyMs: wa.ctx ? Math.round(((wa.ctx.baseLatency || 0) + (wa.ctx.outputLatency || 0)) * 1000) : null,
      waPackets: wa.packets, waDecoded: wa.decoded, waPlayed: wa.played,
      waUnderruns: wa.underruns, waDropped: wa.dropped, waErrors: wa.errors, waLastError: wa.lastError,
      waLeadMs: wa.ctx ? Math.round((wa.next - wa.ctx.currentTime) * 1000) : null,
      audioPaused: audioEl.paused,
      audioPackets: a ? a.packetsReceived : 0,
      audioSamplesReceived: a ? a.totalSamplesReceived : 0,
      readyState: video.readyState,
      size: v ? `${v.frameWidth || 0}x${v.frameHeight || 0}` : null,
      packets: v ? v.packetsReceived : 0,
      bytes: v ? v.bytesReceived : 0,
      lost: v ? v.packetsLost : 0,
      framesReceived: v ? v.framesReceived : 0,
      framesDecoded: v ? v.framesDecoded : 0,
      framesDropped: v ? v.framesDropped : 0,
      keyFramesDecoded: v ? v.keyFramesDecoded : 0,
      fps: v ? v.framesPerSecond : 0,
      decoder: v ? v.decoderImplementation : null,
      hw: v ? v.powerEfficientDecoder : null,
      nack: v ? v.nackCount : 0,
      pli: v ? v.pliCount : 0,
      rttMs: rtt != null ? Math.round(rtt) : null,
      latency: lat,
      candidate: local ? local.candidateType : null,
      ua: navigator.userAgent.replace(/^.*(Chrome\/[\d.]+).*$/, '$1'),
    });
  }
  prev = cur;
}

// ------------------------------------------------------------------ input
// Binary protocol (little-endian), see host InputInjector.swift.

let mouseMode = localStorage.getItem('gs.mouseMode') === '1' ? 1 : 0; // 0 menu (absolute), 1 camera (relative)
const pressedKeys = new Set();
const buttonsDown = new Set();
const NOT_FORWARDED = new Set(['MetaLeft', 'MetaRight', 'OSLeft', 'OSRight', 'CapsLock', 'ContextMenu']);
let accX = 0, accY = 0;

function inputActive() {
  return !!pc && pc.connectionState === 'connected' && $('login').classList.contains('hidden');
}
function locked() { return document.pointerLockElement === video; }

function send(dc, buf) {
  if (dc && dc.readyState === 'open') dc.send(buf);
}
function clamp16(v) { return Math.max(-32768, Math.min(32767, v | 0)); }

// Position inside the actual picture (object-fit: contain adds black bars).
function videoNorm(clientX, clientY) {
  const r = video.getBoundingClientRect();
  const vw = video.videoWidth || 1920, vh = video.videoHeight || 1080;
  const s = Math.min(r.width / vw, r.height / vh);
  const cw = vw * s, ch = vh * s;
  const ox = r.left + (r.width - cw) / 2, oy = r.top + (r.height - ch) / 2;
  const x = Math.min(1, Math.max(0, (clientX - ox) / cw));
  const y = Math.min(1, Math.max(0, (clientY - oy) / ch));
  return [Math.round(x * 65535), Math.round(y * 65535)];
}

function sendRel(dx, dy) {
  const b = new DataView(new ArrayBuffer(5));
  b.setUint8(0, 1); b.setInt16(1, clamp16(dx), true); b.setInt16(3, clamp16(dy), true);
  send(mouseDc, b.buffer);
}
function sendAbs(x, y) {
  const b = new DataView(new ArrayBuffer(5));
  b.setUint8(0, 2); b.setUint16(1, x, true); b.setUint16(3, y, true);
  send(mouseDc, b.buffer);
}
function sendButton(button, down, e) {
  const b = new DataView(new ArrayBuffer(8));
  const withPos = mouseMode === 0 && !locked() && e;
  const [x, y] = withPos ? videoNorm(e.clientX, e.clientY) : [0, 0];
  b.setUint8(0, 3); b.setUint8(1, button); b.setUint8(2, down ? 1 : 0); b.setUint8(3, withPos ? 1 : 0);
  b.setUint16(4, x, true); b.setUint16(6, y, true);
  send(inputDc, b.buffer);
}
function sendWheel(dx, dy) {
  const b = new DataView(new ArrayBuffer(5));
  b.setUint8(0, 4); b.setInt16(1, clamp16(dx), true); b.setInt16(3, clamp16(dy), true);
  send(inputDc, b.buffer);
}
const enc = new TextEncoder();
function sendKey(code, down, repeat) {
  const name = enc.encode(code);
  const u = new Uint8Array(4 + name.length);
  u[0] = 5; u[1] = down ? 1 : 0; u[2] = repeat ? 1 : 0; u[3] = name.length; u.set(name, 4);
  send(inputDc, u.buffer);
}
function sendMode() { send(inputDc, new Uint8Array([7, mouseMode]).buffer); }

function releaseAll() {
  if (pressedKeys.size || buttonsDown.size) send(inputDc, new Uint8Array([6]).buffer);
  pressedKeys.clear();
  buttonsDown.clear();
}

function lockPointer() {
  try {
    const p = video.requestPointerLock({ unadjustedMovement: true });
    if (p && p.catch) p.catch(() => video.requestPointerLock());
  } catch (_) {
    video.requestPointerLock();
  }
}

let toastTimer = null;
function flash(text) {
  showStatus(text);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => showStatus(''), 1800);
}

// autoCamera: camera mode was switched on automatically because the game
// captured the cursor (and will be switched off when it releases it).
let autoCamera = false;

function setMouseMode(m, auto = false) {
  if (!auto) autoCamera = false;
  mouseMode = m;
  if (!auto) localStorage.setItem('gs.mouseMode', String(m));
  sendMode();
  updateModeUi();
  if (m === 1) {
    lockPointer();
    // Pointer lock needs a recent click/key; if the browser refused, the next
    // click on the video grabs the mouse.
    setTimeout(() => {
      if (mouseMode === 1 && !locked()) flash(T('Игра захватила мышь — кликни по экрану', 'The game grabbed the mouse — click the picture'));
    }, 300);
    if (!auto) flash(T('Мышь: режим камеры (Ctrl+Alt+M — вернуть меню)', 'Mouse: camera mode (Ctrl+Alt+M — back to menu)'));
  } else {
    if (locked()) document.exitPointerLock();
    flash(auto ? T('Мышь: режим меню', 'Mouse: menu mode') : T('Мышь: режим меню (Ctrl+Alt+M — камера)', 'Mouse: menu mode (Ctrl+Alt+M — camera)'));
  }
}

function modeName() { return mouseMode === 1 ? T('камера', 'camera') : T('меню', 'menu'); }

function updateModeUi() {
  $('btnMode').textContent = `${T('Мышь', 'Mouse')}: ${modeName()}`;
  video.style.cursor = mouseMode === 1 ? 'crosshair' : 'default';
}
$('btnMode').onclick = () => setMouseMode(mouseMode === 1 ? 0 : 1);
updateModeUi();

document.addEventListener('pointerlockchange', () => {
  if (!locked() && mouseMode === 1 && inputActive()) {
    releaseAll();
    flash(T('Кликни по видео, чтобы снова захватить мышь', 'Click the picture to grab the mouse again'));
  }
});

// pointerrawupdate (secure contexts only) delivers movement without waiting for a frame.
const MOVE_EVENT = 'onpointerrawupdate' in window ? 'pointerrawupdate' : 'pointermove';
document.addEventListener(MOVE_EVENT, (e) => {
  if (!inputActive()) return;
  if (locked()) {
    accX += e.movementX; accY += e.movementY;
    const dx = Math.trunc(accX), dy = Math.trunc(accY);
    accX -= dx; accY -= dy;
    if (dx || dy) sendRel(dx, dy);
  } else if (mouseMode === 0 && e.target === video) {
    const [x, y] = videoNorm(e.clientX, e.clientY);
    sendAbs(x, y);
  }
});

video.addEventListener('mousedown', (e) => {
  if (!inputActive()) return;
  e.preventDefault();
  if (mouseMode === 1 && !locked()) { lockPointer(); return; } // this click only grabs the mouse
  buttonsDown.add(e.button);
  sendButton(e.button, true, e);
});
document.addEventListener('mouseup', (e) => {
  if (e.button === 3 || e.button === 4) e.preventDefault(); // no browser back/forward
  if (!inputActive() || !buttonsDown.has(e.button)) return;
  e.preventDefault();
  buttonsDown.delete(e.button);
  sendButton(e.button, false, e);
});
video.addEventListener('contextmenu', (e) => e.preventDefault());
video.addEventListener('auxclick', (e) => e.preventDefault());

video.addEventListener('wheel', (e) => {
  if (!inputActive()) return;
  e.preventDefault();
  const k = e.deltaMode === 1 ? 33 : e.deltaMode === 2 ? 300 : 1; // lines/pages -> px
  sendWheel(e.deltaX * k, e.deltaY * k);
}, { passive: false });

window.addEventListener('keydown', (e) => {
  if (!inputActive()) return;
  if (e.ctrlKey && e.altKey && CLIENT_HOTKEYS.has(e.code)) return;
  if (!e.code || NOT_FORWARDED.has(e.code)) return;
  e.preventDefault();
  pressedKeys.add(e.code);
  sendKey(e.code, true, e.repeat);
}, true);
window.addEventListener('keyup', (e) => {
  if (!pressedKeys.has(e.code)) return;
  e.preventDefault();
  pressedKeys.delete(e.code);
  sendKey(e.code, false, false);
}, true);

// Never leave keys stuck on the Mac when focus leaves the page.
window.addEventListener('blur', releaseAll);
document.addEventListener('visibilitychange', () => { if (document.hidden) releaseAll(); });

// ------------------------------------------------------------------ diagnostics (?diag)
// Taps encoded frames as they arrive, then test-decodes them with WebCodecs
// (software and hardware) and reports everything to the host log.

function diagTap(receiver) {
  let streams;
  try { streams = receiver.createEncodedStreams(); } catch (e) {
    sendCtl({ t: 'clientdiag', error: 'createEncodedStreams: ' + e });
    return;
  }
  const frames = [];
  let done = false;
  streams.readable.pipeThrough(new TransformStream({
    transform(f, c) {
      if (!done) {
        frames.push({ type: f.type, data: new Uint8Array(f.data.slice(0)) });
        if (frames.length > 1500) frames.splice(0, 750);
        const k = frames.findIndex((x) => x.type === 'key');
        if (k >= 0 && frames.length - k >= 90) {
          done = true;
          runDiag(frames.slice(k)).catch((e) => sendCtl({ t: 'clientdiag', error: String(e) }));
        }
      }
      c.enqueue(f);
    },
  })).pipeTo(streams.writable);
}

function hex(u8, n) {
  return Array.from(u8.slice(0, n)).map((b) => b.toString(16).padStart(2, '0')).join(' ');
}

// avc1.PPCCLL from the SPS in a keyframe.
function codecFromSps(u8) {
  for (let i = 0; i + 7 < u8.length; i++) {
    if (u8[i] === 0 && u8[i + 1] === 0 && u8[i + 2] === 1 && (u8[i + 3] & 0x1f) === 7) {
      return 'avc1.' + hex(u8.slice(i + 4, i + 7), 3).replace(/ /g, '');
    }
  }
  return 'avc1.42e01f';
}

async function diagDecode(frames, codec, accel) {
  const out = { accel, decoded: 0, errors: [] };
  const cfg = { codec, hardwareAcceleration: accel, optimizeForLatency: true };
  try { out.supported = (await VideoDecoder.isConfigSupported(cfg)).supported; } catch (e) { out.errors.push('isConfigSupported ' + e); }
  if (!out.supported) return out;
  const dec = new VideoDecoder({
    output: (fr) => { if (!out.size) out.size = `${fr.codedWidth}x${fr.codedHeight}`; out.decoded++; fr.close(); },
    error: (e) => out.errors.push(String(e)),
  });
  dec.configure(cfg);
  let i = 0;
  for (const f of frames.slice(0, 60)) {
    if (dec.state !== 'configured') break;
    try { dec.decode(new EncodedVideoChunk({ type: f.type, timestamp: (i++) * 16667, data: f.data })); } catch (e) { out.errors.push('decode ' + e); break; }
  }
  try { await Promise.race([dec.flush(), new Promise((_, rej) => setTimeout(() => rej(new Error('flush timeout')), 5000))]); } catch (e) { out.errors.push('flush ' + e); }
  try { dec.close(); } catch (_) {}
  return out;
}

async function runDiag(frames) {
  const key = frames[0].data;
  const codec = codecFromSps(key);
  const report = {
    t: 'clientdiag',
    ua: navigator.userAgent,
    brands: navigator.userAgentData ? navigator.userAgentData.brands.map((b) => `${b.brand} ${b.version}`).join(', ') : null,
    platform: navigator.userAgentData ? navigator.userAgentData.platform : navigator.platform,
    codec,
    keyHead: hex(key, 40),
    keyBytes: key.length,
    frames: frames.length,
    h264Caps: (RTCRtpReceiver.getCapabilities('video') || { codecs: [] }).codecs
      .filter((c) => /h264/i.test(c.mimeType)).map((c) => c.sdpFmtpLine),
  };
  try {
    const mc = await navigator.mediaCapabilities.decodingInfo({
      type: 'webrtc',
      video: { contentType: 'video/h264;profile-level-id=42e01f;packetization-mode=1', width: 1920, height: 1080, bitrate: 10e6, framerate: 60 },
    });
    report.mediaCaps = { supported: mc.supported, smooth: mc.smooth, powerEfficient: mc.powerEfficient };
  } catch (e) { report.mediaCaps = String(e); }
  report.software = await diagDecode(frames, codec, 'prefer-software');
  report.hardware = await diagDecode(frames, codec, 'prefer-hardware');
  sendCtl(report);
  flash(T('Диагностика отправлена на Мак', 'Diagnostics sent to the Mac'));
}

// Auto-connect if we already know the PIN (e.g. after page reload).
if (pin) connect(); else showLogin();
