import AppKit
import CoreGraphics
import Foundation

/// Injects mouse/keyboard events received from the browser.
///
/// Wire format (first byte = type, multi-byte values little-endian):
///   1 rel move   [1][i16 dx][i16 dy]
///   2 abs move   [2][u16 x][u16 y]                 x,y: 0...65535 across the streamed display
///   3 button     [3][u8 button][u8 down][u8 hasPos][u16 x][u16 y]   button: 0 L, 1 M, 2 R, 3 back, 4 fwd
///   4 wheel      [4][i16 dx][i16 dy]               browser pixels (≈100 per notch)
///   5 key        [5][u8 down][u8 repeat][u8 len][KeyboardEvent.code utf8]
///   6 release all
///   7 mode       [7][u8 mode]                      0 absolute (menu), 1 relative (camera)
///
/// Mouse events always carry both the new cursor position and raw deltas
/// (kCGMouseEventDeltaX/Y) and are posted at the HID tap: the combination that
/// works for both the desktop and games under CrossOver.
final class InputInjector {
    var onModeChange: ((Int) -> Void)?
    /// Called on the main queue when a game grabs (true) or releases (false) the cursor.
    var onCursorCaptured: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "input", qos: .userInteractive)
    private let source: CGEventSource?
    private var pos = CGPoint.zero
    private var lastEventTime = CFAbsoluteTime(0)
    private var buttonsDown = Set<Int>()
    private var keysDown = Set<CGKeyCode>()
    private var flags: CGEventFlags = []
    private var wheelAccX = 0.0
    private var wheelAccY = 0.0
    private var lastClick: (button: Int, time: CFAbsoluteTime, pos: CGPoint, count: Int64) = (-1, 0, .zero, 0)
    private var warnedNoPermission = false

    // Cursor-capture detection. macOS doesn't tell other apps whether a game
    // hid/locked the cursor, so watch behaviour instead: after we place the
    // cursor somewhere, does it stay there? A game that captures the mouse keeps
    // it pinned (or warps it back every frame), so the real position stops
    // matching what we posted.
    private var lastPosted: CGPoint?
    private var lastPostedTime = CFAbsoluteTime(0)
    private var lastAbsTarget: CGPoint?
    private var pinnedPoint: CGPoint?
    private var pinStart = CFAbsoluteTime(0)
    private var lastPinHit = CFAbsoluteTime(0)
    private var pinHits = 0
    private var checks = 0
    private(set) var cursorCaptured = false

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        // Don't suppress the Mac's own mouse/keyboard after we post events.
        source?.localEventsSuppressionInterval = 0
    }

    static var hasPermission: Bool { CGPreflightPostEventAccess() }

    static func requestPermission() {
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
    }

    /// Called from the helper reader thread.
    func handle(_ data: Data) {
        queue.async { [weak self] in self?.process(data) }
    }

    func releaseAll() {
        queue.async { [weak self] in self?.doReleaseAll() }
    }

    // MARK: - Decoding

    private func process(_ d: Data) {
        guard let type = d.first else { return }
        if type == 7, d.count >= 2 {
            let mode = Int(d[d.startIndex + 1])
            checks = 0
            lastAbsTarget = nil
            DispatchQueue.main.async { [weak self] in self?.onModeChange?(mode) }
            return
        }
        if !Self.hasPermission {
            if !warnedNoPermission {
                warnedNoPermission = true
                Log.info("input ignored: no Device Control (Accessibility) permission")
            }
            return
        }
        warnedNoPermission = false
        let b = [UInt8](d)
        func i16(_ o: Int) -> Int { Int(Int16(bitPattern: UInt16(b[o]) | UInt16(b[o + 1]) << 8)) }
        func u16(_ o: Int) -> Int { Int(UInt16(b[o]) | UInt16(b[o + 1]) << 8) }

        syncPositionIfIdle()
        switch type {
        case 1 where b.count >= 5:
            moveRelative(dx: i16(1), dy: i16(3))
        case 2 where b.count >= 5:
            moveAbsolute(nx: u16(1), ny: u16(3))
        case 3 where b.count >= 8:
            if b[3] == 1 { moveAbsolute(nx: u16(4), ny: u16(6)) }
            button(Int(b[1]), down: b[2] == 1)
        case 4 where b.count >= 5:
            wheel(dx: i16(1), dy: i16(3))
        case 5 where b.count >= 4:
            let len = Int(b[3])
            guard b.count >= 4 + len, let code = String(bytes: b[4..<(4 + len)], encoding: .utf8) else { return }
            key(code, down: b[1] == 1, isRepeat: b[2] == 1)
        case 6:
            doReleaseAll()
        default:
            break
        }
        lastEventTime = CFAbsoluteTimeGetCurrent()
    }

    // MARK: - Mouse

    private var displayBounds: CGRect { CGDisplayBounds(CGMainDisplayID()) }

    /// Someone may have used the Mac's own mouse in between: re-read the real cursor.
    private func syncPositionIfIdle() {
        if CFAbsoluteTimeGetCurrent() - lastEventTime > 0.5, let loc = CGEvent(source: nil)?.location {
            pos = loc
            lastAbsTarget = nil
        }
    }

    private var realCursor: CGPoint { CGEvent(source: nil)?.location ?? pos }

    /// Compare where the cursor actually is with where we last put it.
    ///
    /// A capturing game keeps the cursor *pinned*: either it doesn't move at
    /// all, or the game warps it back to the same point every frame. So we look
    /// for the real position landing on the same off-target point again and
    /// again for at least a quarter of a second. Short stalls (event latency)
    /// and the cursor simply lagging a step behind don't qualify.
    private func observeCursor(_ real: CGPoint) {
        guard let posted = lastPosted, CFAbsoluteTimeGetCurrent() - lastPostedTime < 0.3 else { return }
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) <= 3 && abs(a.y - b.y) <= 3 }
        let now = CFAbsoluteTimeGetCurrent()
        checks += 1
        if !near(real, posted) {
            if let pin = pinnedPoint, near(real, pin), now - lastPinHit < 0.5 {
                pinHits += 1
            } else {
                pinnedPoint = real
                pinStart = now
                pinHits = 1
            }
            lastPinHit = now
        }

        if !cursorCaptured {
            if pinHits >= 6, now - pinStart >= 0.25, now - lastPinHit < 0.1 { setCaptured(true) }
        } else if now - lastPinHit > 1.0, checks >= 20 {
            setCaptured(false)
        }
    }

    private func setCaptured(_ on: Bool) {
        cursorCaptured = on
        pinHits = 0
        pinnedPoint = nil
        checks = 0
        Log.info(on ? "game captured the cursor -> camera mode" : "game released the cursor -> menu mode")
        DispatchQueue.main.async { [weak self] in self?.onCursorCaptured?(on) }
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        let r = displayBounds
        return CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
    }

    /// Camera mode: move from where the cursor really is. A game that keeps
    /// warping the cursor back to the centre then never hits the screen edge,
    /// and the raw deltas keep turning the camera indefinitely.
    private func moveRelative(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        let real = realCursor
        observeCursor(real)
        pos = clamp(CGPoint(x: real.x + CGFloat(dx), y: real.y + CGFloat(dy)))
        postMove(dx: dx, dy: dy)
    }

    /// Menu mode: put the cursor exactly where the viewer points.
    private func moveAbsolute(nx: Int, ny: Int) {
        let r = displayBounds
        let target = clamp(CGPoint(x: r.minX + CGFloat(nx) / 65535 * r.width,
                                   y: r.minY + CGFloat(ny) / 65535 * r.height))
        let real = realCursor
        observeCursor(real)
        // Deltas follow the viewer's own movement, not the jump from wherever a
        // game may have parked the cursor.
        let from = lastAbsTarget ?? real
        let dx = Int((target.x - from.x).rounded())
        let dy = Int((target.y - from.y).rounded())
        lastAbsTarget = target
        pos = target
        guard dx != 0 || dy != 0 || target != real else { return }
        postMove(dx: dx, dy: dy)
    }

    private func postMove(dx: Int, dy: Int) {
        let type: CGEventType
        let btn: CGMouseButton
        if buttonsDown.contains(0) { type = .leftMouseDragged; btn = .left }
        else if buttonsDown.contains(2) { type = .rightMouseDragged; btn = .right }
        else if !buttonsDown.isEmpty { type = .otherMouseDragged; btn = .center }
        else { type = .mouseMoved; btn = .left }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pos, mouseButton: btn) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        e.flags = flags
        e.post(tap: .cghidEventTap)
        lastPosted = pos
        lastPostedTime = CFAbsoluteTimeGetCurrent()
    }

    private func button(_ b: Int, down: Bool) {
        if down { buttonsDown.insert(b) } else { buttonsDown.remove(b) }
        let type: CGEventType
        let cgButton: CGMouseButton
        switch b {
        case 0: type = down ? .leftMouseDown : .leftMouseUp; cgButton = .left
        case 2: type = down ? .rightMouseDown : .rightMouseUp; cgButton = .right
        default: type = down ? .otherMouseDown : .otherMouseUp; cgButton = .center
        }
        // macOS needs an explicit click count for double/triple clicks.
        let now = CFAbsoluteTimeGetCurrent()
        if down {
            let near = abs(pos.x - lastClick.pos.x) < 5 && abs(pos.y - lastClick.pos.y) < 5
            let count: Int64 = (lastClick.button == b && now - lastClick.time < NSEvent.doubleClickInterval && near)
                ? lastClick.count + 1 : 1
            lastClick = (b, now, pos, count)
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pos, mouseButton: cgButton) else { return }
        // CGMouseButton(rawValue:) maps 0 L, 1 R, 2 M; browser uses 0 L, 1 M, 2 R, 3 back, 4 fwd.
        let number: Int64 = switch b { case 0: 0; case 1: 2; case 2: 1; default: Int64(b) }
        e.setIntegerValueField(.mouseEventButtonNumber, value: number)
        e.setIntegerValueField(.mouseEventClickState, value: lastClick.button == b ? lastClick.count : 1)
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private func wheel(dx: Int, dy: Int) {
        // Browser: +dy = scroll down. macOS line units: +1 = up.
        wheelAccY += Double(-dy) / 100
        wheelAccX += Double(-dx) / 100
        let ly = Int32(wheelAccY.rounded(.towardZero))
        let lx = Int32(wheelAccX.rounded(.towardZero))
        wheelAccY -= Double(ly)
        wheelAccX -= Double(lx)
        guard ly != 0 || lx != 0 else { return }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: ly, wheel2: lx, wheel3: 0) else { return }
        e.location = pos
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    private func key(_ code: String, down: Bool, isRepeat: Bool) {
        guard let vk = KeyMap.code[code] else { return }
        if let mod = KeyMap.modifierFlag[vk] {
            // Keep the flag while either side (left/right) is held.
            if down { keysDown.insert(vk) } else { keysDown.remove(vk) }
            let stillHeld = keysDown.contains { KeyMap.modifierFlag[$0] == mod }
            if stillHeld { flags.insert(mod) } else { flags.remove(mod) }
        } else {
            if down { keysDown.insert(vk) } else { keysDown.remove(vk) }
        }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else { return }
        e.flags = flags
        if isRepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        e.post(tap: .cghidEventTap)
    }

    private func doReleaseAll() {
        guard Self.hasPermission else { return }
        for vk in keysDown {
            flags = []
            if let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: false) {
                e.flags = []
                e.post(tap: .cghidEventTap)
            }
        }
        keysDown.removeAll()
        flags = []
        for b in buttonsDown { button(b, down: false) }
        buttonsDown.removeAll()
    }
}

/// KeyboardEvent.code -> macOS virtual keycode (physical key positions).
/// The Windows key (Meta) and CapsLock are intentionally not forwarded.
enum KeyMap {
    static let code: [String: CGKeyCode] = [
        "KeyA": 0x00, "KeyS": 0x01, "KeyD": 0x02, "KeyF": 0x03, "KeyH": 0x04, "KeyG": 0x05,
        "KeyZ": 0x06, "KeyX": 0x07, "KeyC": 0x08, "KeyV": 0x09, "IntlBackslash": 0x0A, "KeyB": 0x0B,
        "KeyQ": 0x0C, "KeyW": 0x0D, "KeyE": 0x0E, "KeyR": 0x0F, "KeyY": 0x10, "KeyT": 0x11,
        "Digit1": 0x12, "Digit2": 0x13, "Digit3": 0x14, "Digit4": 0x15, "Digit6": 0x16, "Digit5": 0x17,
        "Equal": 0x18, "Digit9": 0x19, "Digit7": 0x1A, "Minus": 0x1B, "Digit8": 0x1C, "Digit0": 0x1D,
        "BracketRight": 0x1E, "KeyO": 0x1F, "KeyU": 0x20, "BracketLeft": 0x21, "KeyI": 0x22, "KeyP": 0x23,
        "Enter": 0x24, "KeyL": 0x25, "KeyJ": 0x26, "Quote": 0x27, "KeyK": 0x28, "Semicolon": 0x29,
        "Backslash": 0x2A, "Comma": 0x2B, "Slash": 0x2C, "KeyN": 0x2D, "KeyM": 0x2E, "Period": 0x2F,
        "Tab": 0x30, "Space": 0x31, "Backquote": 0x32, "Backspace": 0x33, "Escape": 0x35,
        "ShiftLeft": 0x38, "AltLeft": 0x3A, "ControlLeft": 0x3B,
        "ShiftRight": 0x3C, "AltRight": 0x3D, "ControlRight": 0x3E,
        "NumpadDecimal": 0x41, "NumpadMultiply": 0x43, "NumpadAdd": 0x45, "NumLock": 0x47,
        "NumpadDivide": 0x4B, "NumpadEnter": 0x4C, "NumpadSubtract": 0x4E, "NumpadEqual": 0x51,
        "Numpad0": 0x52, "Numpad1": 0x53, "Numpad2": 0x54, "Numpad3": 0x55, "Numpad4": 0x56,
        "Numpad5": 0x57, "Numpad6": 0x58, "Numpad7": 0x59, "Numpad8": 0x5B, "Numpad9": 0x5C,
        "IntlYen": 0x5D, "IntlRo": 0x5E,
        "F1": 0x7A, "F2": 0x78, "F3": 0x63, "F4": 0x76, "F5": 0x60, "F6": 0x61, "F7": 0x62, "F8": 0x64,
        "F9": 0x65, "F10": 0x6D, "F11": 0x67, "F12": 0x6F,
        "Insert": 0x72, "Home": 0x73, "PageUp": 0x74, "Delete": 0x75, "End": 0x77, "PageDown": 0x79,
        "ArrowLeft": 0x7B, "ArrowRight": 0x7C, "ArrowDown": 0x7D, "ArrowUp": 0x7E,
    ]

    static let modifierFlag: [CGKeyCode: CGEventFlags] = [
        0x38: .maskShift, 0x3C: .maskShift,
        0x3B: .maskControl, 0x3E: .maskControl,
        0x3A: .maskAlternate, 0x3D: .maskAlternate,
    ]
}
