import AppKit
import Carbon
import Foundation

let home = NSHomeDirectory()
let stateDir = "\(home)/claude-awake-buddy/state"
let binDir = "\(home)/claude-awake-buddy/bin"
let assetsDir = "\(home)/claude-awake-buddy/assets"
let mascotsDir = "\(assetsDir)/mascots"
let prefsPath = "\(stateDir)/prefs.json"

struct Prefs {
    var posXFrac: CGFloat = 0.5   // free position, fraction of available screen width
    var posYFrac: CGFloat = 1.0   // 1.0 = flush to top (default, near the camera)
    var scale: CGFloat = 1.0
    var tilt: CGFloat = 0       // rotation in degrees; user-adjustable via the menu
    var keepDisplayOn = true    // false = screen may sleep while the Mac stays awake
    var maxAwakeHours: Double = 0  // sleep-safety timer; 0 = no limit
    var chirp = true            // play a soft sound when Claude needs attention
    var displayID: UInt32 = 0   // which display the bat lives on; 0 = main
    var mascotID: String = "bat"       // which character is shown
    var watchedApps: [String] = []     // bundle IDs to keep awake for while running

    static func load() -> Prefs {
        var p = Prefs()
        if let data = FileManager.default.contents(atPath: prefsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let x = json["posXFrac"] as? NSNumber { p.posXFrac = CGFloat(x.doubleValue) }
            if let y = json["posYFrac"] as? NSNumber { p.posYFrac = CGFloat(y.doubleValue) }
            if let s = json["scale"] as? NSNumber { p.scale = CGFloat(s.doubleValue) }
            if let t = json["tilt"] as? NSNumber { p.tilt = CGFloat(t.doubleValue) }
            if let k = json["keepDisplayOn"] as? Bool { p.keepDisplayOn = k }
            if let m = json["maxAwakeHours"] as? NSNumber { p.maxAwakeHours = m.doubleValue }
            if let c = json["chirp"] as? Bool { p.chirp = c }
            if let d = json["displayID"] as? NSNumber { p.displayID = d.uint32Value }
            if let id = json["mascotID"] as? String { p.mascotID = id }
            if let w = json["watchedApps"] as? [String] { p.watchedApps = w }
        }
        return p
    }

    func save() {
        let json: [String: Any] = ["posXFrac": posXFrac, "posYFrac": posYFrac, "scale": scale, "tilt": tilt,
                                   "keepDisplayOn": keepDisplayOn, "maxAwakeHours": maxAwakeHours,
                                   "chirp": chirp, "displayID": displayID,
                                   "mascotID": mascotID, "watchedApps": watchedApps]
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            try? data.write(to: URL(fileURLWithPath: prefsPath))
        }
    }
}

func runScript(_ path: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = [path]
    try? task.run()
}

func anyClaudeSessionRunning() -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-x", "claude"]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch {
        return true // if we can't check, don't force sleep on a guess
    }
}

func readState() -> (awake: Bool, message: String?, messageTime: Double, since: Double) {
    var awake = false
    var message: String? = nil
    var messageTime: Double = 0
    var since: Double = 0
    if let data = FileManager.default.contents(atPath: "\(stateDir)/state.json"),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        awake = (json["awake"] as? Bool) ?? false
        if let u = json["updated"] as? NSNumber { since = u.doubleValue }
    }
    if let data = FileManager.default.contents(atPath: "\(stateDir)/message.json"),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        message = json["message"] as? String
        if let t = json["time"] as? NSNumber { messageTime = t.doubleValue }
    }
    return (awake, message, messageTime, since)
}

// Post a message into the same pipeline the Notification hook uses, so
// app-generated notices (e.g. the sleep-safety timer) chirp and bubble too.
func postLocalMessage(_ text: String) {
    let json: [String: Any] = ["message": text, "time": Date().timeIntervalSince1970 * 1000]
    if let data = try? JSONSerialization.data(withJSONObject: json) {
        try? data.write(to: URL(fileURLWithPath: "\(stateDir)/message.json"))
    }
}

func claudeSessionCount() -> Int {
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-x", "claude"]
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return 0 }
        let out = String(data: data, encoding: .utf8) ?? ""
        return out.split(separator: "\n").count
    } catch {
        return 0
    }
}

// how many `wigbat run -- …` commands are currently holding keep-awake
func wigbatRunCount() -> Int {
    guard let s = try? String(contentsOfFile: "\(stateDir)/run-count", encoding: .utf8),
          let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
    return max(0, n)
}

// Manual keep-awake override, shared on disk so the bat, the menu, the `wigbat`
// CLI, and the wigbat:// URL scheme all speak to the same reconciler.
// "on"/"off" = user forced it; absent = follow the sources.
func readOverride() -> Bool? {
    guard let s = try? String(contentsOfFile: "\(stateDir)/override", encoding: .utf8) else { return nil }
    switch s.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "on": return true
    case "off": return false
    default: return nil
    }
}

func writeOverride(_ v: Bool?) {
    let path = "\(stateDir)/override"
    switch v {
    case .some(true):  try? "on".write(toFile: path, atomically: true, encoding: .utf8)
    case .some(false): try? "off".write(toFile: path, atomically: true, encoding: .utf8)
    case .none:        try? FileManager.default.removeItem(atPath: path)
    }
}

func loadImage(_ name: String) -> NSImage? {
    NSImage(contentsOfFile: "\(assetsDir)/\(name).png")
}

// MARK: - Mascot model

enum MascotStyle {
    case branchHung   // the bat: hangs from a branch, mirrored, blink + ear wiggle
    case sitting      // generic drop-in mascot: pose-swap driven, gentle bob/sway
}

// A character definition. The bat is a built-in with a bespoke renderer; every
// other mascot is loaded from assets/mascots/<id>/mascot.json + PNGs, so new
// characters are pure drop-in with no code changes.
final class Mascot {
    let id: String
    let displayName: String
    let style: MascotStyle
    let baseWidth: CGFloat
    let baseHeight: CGFloat
    let bobAmplitude: CGFloat
    let swayDegrees: CGFloat
    let altEverySec: Double     // 0 = never show the alt idle pose
    let altForSec: Double
    var poses: [String: NSImage] = [:]   // "asleep"/"awake"/"working"/"awakeAlt"/"leaving"
    let menuAwake: NSImage?
    let menuAsleep: NSImage?

    init(id: String, displayName: String, style: MascotStyle,
         baseWidth: CGFloat, baseHeight: CGFloat,
         bobAmplitude: CGFloat, swayDegrees: CGFloat,
         altEverySec: Double, altForSec: Double,
         poses: [String: NSImage], menuAwake: NSImage?, menuAsleep: NSImage?) {
        self.id = id; self.displayName = displayName; self.style = style
        self.baseWidth = baseWidth; self.baseHeight = baseHeight
        self.bobAmplitude = bobAmplitude; self.swayDegrees = swayDegrees
        self.altEverySec = altEverySec; self.altForSec = altForSec
        self.poses = poses; self.menuAwake = menuAwake; self.menuAsleep = menuAsleep
    }

    func pose(_ key: String) -> NSImage? { poses[key] }

    // The built-in bat: art lives directly in assets/ and the branch-hung
    // renderer draws it, so its poses dict stays empty (the view holds the
    // bat's images directly to keep it pixel-identical to before).
    static func bat() -> Mascot {
        Mascot(id: "bat", displayName: "Bat", style: .branchHung,
               baseWidth: 100, baseHeight: 100,
               bobAmplitude: 2.0, swayDegrees: 0,
               altEverySec: 0, altForSec: 0,
               poses: [:],
               menuAwake: loadImage("menu-icon-awake"),
               menuAsleep: loadImage("menu-icon-asleep"))
    }

    static func loadManifest(dir: String) -> Mascot? {
        guard let data = FileManager.default.contents(atPath: "\(dir)/mascot.json"),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = j["id"] as? String else { return nil }
        func num(_ k: String, _ d: CGFloat) -> CGFloat { (j[k] as? NSNumber).map { CGFloat($0.doubleValue) } ?? d }
        func dnum(_ k: String, _ d: Double) -> Double { (j[k] as? NSNumber)?.doubleValue ?? d }
        let style: MascotStyle = (j["style"] as? String) == "branchHung" ? .branchHung : .sitting

        var poses: [String: NSImage] = [:]
        if let map = j["poses"] as? [String: String] {
            for (key, file) in map {
                if let img = NSImage(contentsOfFile: "\(dir)/\(file)") { poses[key] = img }
            }
        }
        var menuAwake: NSImage? = nil, menuAsleep: NSImage? = nil
        if let icons = j["menuIcons"] as? [String: String] {
            if let a = icons["awake"] { menuAwake = NSImage(contentsOfFile: "\(dir)/\(a)") }
            if let s = icons["asleep"] { menuAsleep = NSImage(contentsOfFile: "\(dir)/\(s)") }
        }
        // fall back to the awake/asleep poses for the menu-bar icon if none given
        if menuAwake == nil { menuAwake = poses["awake"] ?? poses["working"] }
        if menuAsleep == nil { menuAsleep = poses["asleep"] ?? poses["awake"] }

        return Mascot(id: id, displayName: (j["displayName"] as? String) ?? id,
                      style: style,
                      baseWidth: num("baseWidth", 120), baseHeight: num("baseHeight", 120),
                      bobAmplitude: num("bobAmplitude", 2.0), swayDegrees: num("swayDegrees", 1.2),
                      altEverySec: dnum("altEverySec", 0), altForSec: dnum("altForSec", 0),
                      poses: poses, menuAwake: menuAwake, menuAsleep: menuAsleep)
    }

    // Built-in bat first, then every assets/mascots/<id>/mascot.json (deduped).
    static func buildRegistry() -> [Mascot] {
        var list = [Mascot.bat()]
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: mascotsDir) {
            for e in entries.sorted() {
                let dir = "\(mascotsDir)/\(e)"
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue
                else { continue }
                if let m = loadManifest(dir: dir), !list.contains(where: { $0.id == m.id }) {
                    list.append(m)
                }
            }
        }
        return list
    }

    static let registry: [Mascot] = buildRegistry()
    static func byID(_ id: String) -> Mascot { registry.first { $0.id == id } ?? registry[0] }
}

// MARK: - Buddy view

final class BuddyView: NSView {
    var mascot: Mascot = Mascot.byID(Prefs.load().mascotID) {
        didSet { lastAwake = awake; needsDisplay = true }
    }
    var awake = false
    var lastAwake = false
    var hovered = false
    var message: String? = nil
    var messageTime: Double = 0
    var notifyUntil: Double = 0
    var leavingUntil: Double = 0       // sitting mascots: show the "leaving" pose until this time
    let bubbleLifeMs: Double = 15000  // how long a message bubble stays up
    var dismissedMessageTime: Double = 0  // click-to-dismiss: hide bubbles up to this time
    var exciteUntil: Double = 0       // while now < this, the mascot does its excited shake
    var bubbleRect: NSRect = .zero    // where the bubble was last drawn, for hit-testing
    var phase: CGFloat = 0
    var revealProgress: CGFloat = 0
    var revealVelocity: CGFloat = 0
    var scale: CGFloat = 1.0
    var tilt: CGFloat = 0

    var dragging = false
    var dragStartMouse = NSPoint.zero
    var dragStartOrigin = NSPoint.zero

    // bat art (branch-hung renderer only)
    let branchImage = loadImage("branch")
    let awakeBody = loadImage("bat-awake")
    let asleepBody = loadImage("bat-asleep")
    let earLeftAwake = loadImage("ear-left-awake")
    let earRightAwake = loadImage("ear-right-awake")

    // measured fractions within bat-awake.png (306x229 source)
    let eyeLXFrac: CGFloat = 0.399
    let eyeRXFrac: CGFloat = 0.618
    let eyeYFracFromTop: CGFloat = 0.607

    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragging = false
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStartMouse.x
        let dy = now.y - dragStartMouse.y
        if !dragging && (abs(dx) > 4 || abs(dy) > 4) { dragging = true }
        guard dragging, let window = window else { return }
        window.setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
    }

    func bubbleShowing(_ nowMs: Double) -> Bool {
        message != nil && messageTime > dismissedMessageTime && (nowMs - messageTime) < bubbleLifeMs
    }

    // Route every awake change through here so sitting mascots can play their
    // "leaving" (get-off-work) transition when keep-awake ends.
    func setAwake(_ a: Bool) {
        if lastAwake && !a, mascot.pose("leaving") != nil {
            let now = Date().timeIntervalSince1970 * 1000
            leavingUntil = now + 2500
            notifyUntil = max(notifyUntil, now + 2500)   // pop out so the walk-off is visible
            revealVelocity = max(revealVelocity, 0.30)
        }
        lastAwake = a
        awake = a
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            (window as? BuddyPanel)?.persistCurrentPosition()
        } else {
            let p = convert(event.locationInWindow, from: nil)
            let nowMs = Date().timeIntervalSince1970 * 1000
            if bubbleShowing(nowMs), bubbleRect.insetBy(dx: -4, dy: -4).contains(p) {
                // click on the bubble dismisses it (and lets the mascot tuck away)
                dismissedMessageTime = messageTime
                notifyUntil = 0
            } else {
                // one entry point for manual toggles, so the shared override file
                // stays in sync no matter what surface was clicked
                (NSApp.delegate as? AppDelegate)?.toggleAwake()
            }
        }
        dragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = buildBuddyMenu()
        let point = convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: point, in: self)
    }

    func compositeHeight() -> CGFloat { mascot.baseHeight * scale }
    func compositeWidth() -> CGFloat { mascot.baseWidth * scale }

    func batShadow() -> NSShadow {
        let s = NSShadow()
        s.shadowBlurRadius = 6
        s.shadowOffset = NSSize(width: 0, height: -3)
        s.shadowColor = NSColor.black.withAlphaComponent(0.35)
        return s
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()
        NSGraphicsContext.current?.imageInterpolation = .high

        let nowMs = Date().timeIntervalSince1970 * 1000
        switch mascot.style {
        case .branchHung: drawBranchHung(nowMs)
        case .sitting:    drawSitting(nowMs)
        }

        if bubbleShowing(nowMs), revealProgress > 0.6, let msg = message {
            drawBubble(msg)
        } else {
            bubbleRect = .zero
        }
    }

    // MARK: bat (branch-hung) renderer — unchanged behaviour
    func drawBranchHung(_ nowMs: Double) {
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()

        // excited shake: right after a notification arrives the bat rocks on its
        // branch and bobs hard for a couple seconds so the pop actually pops
        let excited = nowMs < exciteUntil
        let exTilt: CGFloat = excited ? sin(phase * 5) * 5 : 0

        // restY: where the composite's center sits when fully revealed, comfortably
        // inside the window. collapseTravel: how far it's pushed past the window's
        // edge (off-canvas, clipped) when fully collapsed, leaving only a small peek.
        let restY = compositeHeight() / 2 + 8
        let collapseTravel = compositeHeight() * 1.3
        let localShift = collapseTravel * (1 - revealProgress)
        let pivot = NSPoint(x: bounds.width / 2, y: restY)

        ctx?.translateBy(x: pivot.x, y: pivot.y)
        ctx?.rotate(by: (tilt + exTilt) * .pi / 180)
        ctx?.scaleBy(x: -1, y: 1) // mirrored left-right
        ctx?.translateBy(x: 0, y: localShift) // push toward the edge (off-canvas) in local space

        let w = compositeWidth()
        let branchH = compositeHeight() * (70.0 / 299.0)
        let bodyH = compositeHeight() * (229.0 / 299.0)
        let bob: CGFloat = excited ? sin(phase * 3) * 3.5 : (hovered ? sin(phase) * 2.0 : 0)

        // branch: fixed, never bobs, never changes with awake/asleep
        if let branch = branchImage {
            ctx?.saveGState()
            batShadow().set()
            let r = NSRect(x: -w / 2, y: bodyH / 2, width: w, height: branchH)
            branch.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            ctx?.restoreGState()
        }

        // body: swaps art, subtle bob only (ears wiggle independently, see below)
        ctx?.saveGState()
        ctx?.translateBy(x: 0, y: bob)

        let body = awake ? awakeBody : asleepBody
        var bodyRect = NSRect.zero
        if let body = body {
            let aspect = body.size.width / body.size.height
            let bw = bodyH * aspect
            bodyRect = NSRect(x: -bw / 2, y: -bodyH / 2, width: bw, height: bodyH)
            ctx?.saveGState()
            batShadow().set()
            body.draw(in: bodyRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            ctx?.restoreGState()

            if awake {
                drawBlink(in: bodyRect)

                // little occasional ear wiggle: rotate just the cropped ear tips
                // around where they meet the head, redrawn over the static art.
                let earWiggleT = phase.truncatingRemainder(dividingBy: 6.5)
                if earWiggleT > 6.0 {
                    let p = (earWiggleT - 6.0) / 0.5
                    let wiggle = sin(p * .pi * 4) * 8 * sin(p * .pi)
                    let earW = (75.0 / 306.0) * bw
                    let earH = (72.0 / 229.0) * bodyH
                    let earY = bodyRect.maxY - earH

                    let leftX = bodyRect.minX + (50.0 / 306.0) * bw
                    ctx?.saveGState()
                    ctx?.translateBy(x: leftX + earW, y: earY)
                    ctx?.rotate(by: wiggle * .pi / 180)
                    ctx?.translateBy(x: -(leftX + earW), y: -earY)
                    earLeftAwake?.draw(in: NSRect(x: leftX, y: earY, width: earW, height: earH), from: .zero, operation: .sourceOver, fraction: 1.0)
                    ctx?.restoreGState()

                    let rightX = bodyRect.minX + (180.0 / 306.0) * bw
                    ctx?.saveGState()
                    ctx?.translateBy(x: rightX, y: earY)
                    ctx?.rotate(by: -wiggle * .pi / 180)
                    ctx?.translateBy(x: -rightX, y: -earY)
                    earRightAwake?.draw(in: NSRect(x: rightX, y: earY, width: earW, height: earH), from: .zero, operation: .sourceOver, fraction: 1.0)
                    ctx?.restoreGState()
                }
            }
        }
        ctx?.restoreGState()
        ctx?.restoreGState()

        // zzz: drawn in plain view coordinates (outside the mirrored/rotated
        // transform, so the glyphs read correctly), floating up beside the head
        if !awake && revealProgress > 0.4 {
            let zAlpha = max(0, min(1, revealProgress))
            let drift = CGFloat((sin(phase) + 1) / 2) * 10
            let centerY = restY + localShift
            let zx = bounds.width / 2 + compositeWidth() * 0.42
            let zy = centerY - compositeHeight() * 0.18 + drift
            let sizes: [CGFloat] = [11, 15, 11]
            let offsets: [(CGFloat, CGFloat)] = [(0, 0), (14, 14), (30, 26)]
            for (i, glyph) in ["z", "Z", "z"].enumerated() {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: sizes[i]),
                    .foregroundColor: NSColor(calibratedRed: 0.62, green: 0.66, blue: 0.76, alpha: zAlpha * (1 - CGFloat(i) * 0.2)),
                ]
                (glyph as NSString).draw(at: NSPoint(x: zx + offsets[i].0, y: zy + offsets[i].1), withAttributes: attrs)
            }
        }
    }

    // MARK: sitting renderer — generic pose-swap mascots (cat, future drop-ins)
    func sittingPose(_ nowMs: Double) -> NSImage? {
        if nowMs < leavingUntil, let p = mascot.pose("leaving") { return p }
        if nowMs < notifyUntil, let p = mascot.pose("working") { return p }  // engaged / just pinged
        if !awake { return mascot.pose("asleep") ?? mascot.pose("awake") }
        if mascot.altEverySec > 0, let alt = mascot.pose("awakeAlt") {
            let period = mascot.altEverySec * 1000
            if nowMs.truncatingRemainder(dividingBy: period) < mascot.altForSec * 1000 { return alt }
        }
        return mascot.pose("awake") ?? mascot.pose("asleep")
    }

    func drawSitting(_ nowMs: Double) {
        guard let img = sittingPose(nowMs) else { return }
        let ctx = NSGraphicsContext.current?.cgContext

        let excited = nowMs < exciteUntil
        let exTilt: CGFloat = excited ? sin(phase * 5) * 4 : 0
        let sway: CGFloat = revealProgress > 0.01 ? sin(phase * 0.8) * mascot.swayDegrees : 0
        let bob: CGFloat = excited ? sin(phase * 3) * mascot.bobAmplitude * 1.6
                                   : (revealProgress > 0.01 ? sin(phase) * mascot.bobAmplitude : 0)

        let w = compositeWidth()
        let h = compositeHeight()
        let restY = h / 2 + 8
        let collapseTravel = h * 1.3
        let localShift = collapseTravel * (1 - revealProgress)

        // aspect-fit the pose into the WxH box so pose swaps never blow up in size
        let aspect = img.size.width / max(1, img.size.height)
        var dw = w, dh = h
        if aspect > w / h { dw = w; dh = w / aspect } else { dh = h; dw = h * aspect }
        let rect = NSRect(x: -dw / 2, y: -dh / 2, width: dw, height: dh)

        ctx?.saveGState()
        ctx?.translateBy(x: bounds.width / 2, y: restY)
        ctx?.rotate(by: (tilt + exTilt + sway) * .pi / 180)
        ctx?.translateBy(x: 0, y: localShift + bob)
        ctx?.saveGState()
        batShadow().set()
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        ctx?.restoreGState()
        ctx?.restoreGState()
    }

    func drawBlink(in bodyRect: NSRect) {
        let t = phase.truncatingRemainder(dividingBy: 4.6)
        guard t > 4.4 else { return }
        let closeAmount = min(1, (t - 4.4) / 0.1)

        let eyeY = bodyRect.minY + (1 - eyeYFracFromTop) * bodyRect.height
        let eyeR = bodyRect.width * 0.075 * closeAmount

        NSColor(calibratedRed: 0.16, green: 0.15, blue: 0.16, alpha: 1.0).setFill()
        for xFrac in [eyeLXFrac, eyeRXFrac] {
            let ex = bodyRect.minX + xFrac * bodyRect.width
            let r = NSRect(x: ex - eyeR, y: eyeY - eyeR * 0.5, width: eyeR * 2, height: eyeR)
            NSBezierPath(ovalIn: r).fill()
        }
    }

    func drawBubble(_ msg: String) {
        // quick fade-in on arrival, fade out over the last ~0.9s, and track reveal
        let nowMs = Date().timeIntervalSince1970 * 1000
        let remaining = (messageTime + bubbleLifeMs) - nowMs
        let fadeIn = max(0, min(1, (nowMs - messageTime) / 180))
        let alpha = fadeIn * max(0, min(1, remaining / 900)) * max(0, min(1, revealProgress))
        guard alpha > 0.01 else { return }

        let bubbleW: CGFloat = bounds.width * 0.95
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .paragraphStyle: style,
        ]
        let textW = bubbleW - 20
        let bounding = (msg as NSString).boundingRect(
            with: NSSize(width: textW, height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs)
        let bubbleH = min(100, max(30, bounding.height + 16))
        let rect = NSRect(x: (bounds.width - bubbleW) / 2, y: 2, width: bubbleW, height: bubbleH)
        bubbleRect = rect  // remembered for click-to-dismiss hit-testing

        let path = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        // little tail pointing up toward the mascot
        path.move(to: NSPoint(x: rect.midX - 7, y: rect.maxY))
        path.line(to: NSPoint(x: rect.midX, y: rect.maxY + 7))
        path.line(to: NSPoint(x: rect.midX + 7, y: rect.maxY))
        path.close()
        NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.13, alpha: 0.94 * alpha).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.18 * alpha).setStroke()
        path.lineWidth = 1
        path.stroke()
        (msg as NSString).draw(in: rect.insetBy(dx: 10, dy: 8), withAttributes: attrs)
    }
}

func buildBuddyMenu() -> NSMenu {
    let menu = NSMenu()
    (NSApp.delegate as? AppDelegate)?.populate(menu, forBuddy: true)
    return menu
}

// MARK: - Panel

final class BuddyPanel: NSPanel {
    let buddyView = BuddyView()
    var prefs = Prefs.load()

    init() {
        let size = NSSize(width: 220, height: 190)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        buddyView.frame = NSRect(origin: .zero, size: size)
        buddyView.mascot = Mascot.byID(prefs.mascotID)
        buddyView.scale = prefs.scale
        buddyView.tilt = prefs.tilt
        contentView = buddyView
        layout()
        orderFrontRegardless()
    }

    static func screenID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    // the display the mascot lives on — falls back to the main screen if the
    // remembered display is unplugged
    func targetScreen() -> NSScreen? {
        NSScreen.screens.first { Self.screenID($0) == prefs.displayID } ?? NSScreen.main
    }

    func layout() {
        guard let screen = targetScreen() else { return }
        let sf = screen.frame
        let size = frame.size
        let origin = NSPoint(
            x: sf.minX + (sf.width - size.width) * prefs.posXFrac,
            y: sf.minY + (sf.height - size.height) * prefs.posYFrac
        )
        setFrameOrigin(origin)
    }

    func persistCurrentPosition() {
        // remember whichever display the mascot was dropped on, and its position
        // as fractions of that display
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
        else { return }
        let sf = screen.frame
        let size = frame.size
        let o = frame.origin
        prefs.displayID = Self.screenID(screen)
        prefs.posXFrac = max(0, min(1, (o.x - sf.minX) / max(1, sf.width - size.width)))
        prefs.posYFrac = max(0, min(1, (o.y - sf.minY) / max(1, sf.height - size.height)))
        prefs.save()
    }

    func resetPosition() {
        prefs.posXFrac = 0.5
        prefs.posYFrac = 1.0
        prefs.tilt = 0
        prefs.displayID = 0  // back to the main display
        prefs.save()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.layout()
        }
        buddyView.tilt = prefs.tilt
        buddyView.needsDisplay = true
    }

    func applyScale(_ delta: CGFloat) {
        // capped at 1.5 so the art never clips the fixed hover window
        prefs.scale = max(0.5, min(1.5, prefs.scale + delta))
        prefs.save()
        buddyView.scale = prefs.scale
        buddyView.needsDisplay = true
    }

    func applyTilt(_ delta: CGFloat) {
        prefs.tilt += delta
        prefs.save()
        buddyView.tilt = prefs.tilt
        buddyView.needsDisplay = true
    }

    func setMascot(_ id: String) {
        prefs.mascotID = id
        prefs.save()
        buddyView.mascot = Mascot.byID(id)
        buddyView.needsDisplay = true
    }
}

// MARK: - App delegate + status item

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: BuddyPanel!
    var statusItem: NSStatusItem!
    var renderTimer: Timer!
    var pollTimer: Timer!
    let statusMenu = NSMenu()
    var lastSeenMessageTime: Double = 0
    var pollTick = 0
    var sessionCount = 0
    var watchedRunning: [String] = []   // display names of watched apps currently running
    var awakeSince: Double = 0
    var history: [(time: Double, text: String)] = []  // recent messages, newest last

    func applicationWillFinishLaunching(_ notification: Notification) {
        // handle wigbat:// URLs (from Shortcuts, Automator, other GUI apps)
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let str = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let comps = URLComponents(string: str) else { return }
        switch comps.host {
        case "notify":
            if let m = comps.queryItems?.first(where: { $0.name == "message" })?.value, !m.isEmpty {
                postLocalMessage(m)
            }
        case "on":
            writeOverride(true); runScript("\(binDir)/stayawake")
        case "off":
            writeOverride(false); runScript("\(binDir)/killawake")
        case "auto":
            writeOverride(nil)
        default:
            break
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = BuddyPanel()
        setupStatusItem()

        renderTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let v = self.panel.buddyView
            let nowMs = Date().timeIntervalSince1970 * 1000
            let target: CGFloat = (v.hovered || nowMs < v.notifyUntil || nowMs < v.leavingUntil) ? 1.0 : 0.0

            // fully tucked away and idle — skip redraws entirely (zero CPU)
            if target == 0 && v.revealProgress == 0 && v.revealVelocity == 0 { return }

            v.phase += 0.03
            // slightly underdamped spring: settles fast with a small playful bounce
            v.revealVelocity = v.revealVelocity * 0.74 + (target - v.revealProgress) * 0.16
            v.revealProgress += v.revealVelocity
            v.revealProgress = min(1.12, max(-0.02, v.revealProgress))
            if abs(v.revealProgress - target) < 0.001 && abs(v.revealVelocity) < 0.001 {
                v.revealProgress = target
                v.revealVelocity = 0
            }
            v.needsDisplay = true
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        pollTimer.fire()

        // keep the mascot on its remembered display when monitors come and go
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.panel.layout()
        }
    }

    func poll() {
        pollTick += 1
        var s = readState()
        if pollTick % 3 == 1 {
            sessionCount = claudeSessionCount()
            watchedRunning = runningWatchedAppNames()
        }

        // Reconcile: keep-awake should be ON if the user forced it, or any source
        // (Claude sessions, a watched app, a `wigbat run`) wants it. This
        // generalises the old self-heal — we only force sleep when nothing wants
        // to stay awake, so a force-killed Claude session can't strand it awake.
        let sourcesWantAwake = sessionCount > 0 || !watchedRunning.isEmpty || wigbatRunCount() > 0
        let override = readOverride()
        let desiredAwake = override ?? sourcesWantAwake
        // drop a manual override once the sources agree with it again
        if let o = override, o == sourcesWantAwake { writeOverride(nil) }

        if pollTick % 3 == 0 {
            if desiredAwake && !s.awake {
                runScript("\(binDir)/stayawake"); s.awake = true
            } else if !desiredAwake && s.awake {
                runScript("\(binDir)/killawake"); s.awake = false
            }
        }

        // sleep-safety timer: never keep the Mac awake longer than the cap,
        // no matter what sources or hooks are doing
        let now = Date().timeIntervalSince1970
        let maxH = panel.prefs.maxAwakeHours
        if s.awake && maxH > 0 && s.since > 0 && now - s.since > maxH * 3600 {
            runScript("\(binDir)/killawake")
            s.awake = false
            writeOverride(false)   // don't let sources immediately re-wake it
            postLocalMessage("Sleep-safety timer: awake for \(Int(maxH))h — letting the Mac sleep now. Click me to keep it awake.")
        }
        awakeSince = s.since
        let v = panel.buddyView
        v.setAwake(s.awake)
        v.message = s.message
        v.messageTime = s.messageTime
        if s.messageTime > lastSeenMessageTime, let msg = s.message {
            lastSeenMessageTime = s.messageTime
            history.append((s.messageTime, msg))
            if history.count > 8 { history.removeFirst() }
            // only pop for fresh messages — skip stale ones found at launch
            if now * 1000 - s.messageTime < 30_000 {
                v.notifyUntil = s.messageTime + v.bubbleLifeMs + 200
                v.exciteUntil = now * 1000 + 2200
                v.revealVelocity = max(v.revealVelocity, 0.30)  // extra spring kick: pop!
                if panel.prefs.chirp { NSSound(named: "Pop")?.play() }
                if !panel.isVisible { panel.orderFrontRegardless() }
            }
        }
        updateStatusIcon()
    }

    // MARK: watched apps
    func runningRegularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    func runningWatchedAppNames() -> [String] {
        let watched = Set(panel.prefs.watchedApps)
        guard !watched.isEmpty else { return [] }
        var names: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, watched.contains(id) {
                names.append(app.localizedName ?? id)
            }
        }
        return names
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.imagePosition = .imageOnly
        updateStatusIcon()

        // rebuilt on every open (menuNeedsUpdate), so checkmarks and the
        // message history are always current — same builder as the right-click menu
        statusMenu.delegate = self
        statusItem.menu = statusMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        menu.removeAllItems()
        populate(menu, forBuddy: false)
    }

    func populate(_ menu: NSMenu, forBuddy: Bool) {
        let awake = panel.buddyView.awake

        let infoItem = NSMenuItem(title: infoLine(), action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)
        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(title: "Keep Mac Awake", action: #selector(toggleAwake), keyEquivalent: "")
        toggleItem.state = awake ? .on : .off
        menu.addItem(toggleItem)
        let displayItem = NSMenuItem(title: "Keep Display On", action: #selector(toggleKeepDisplayOn), keyEquivalent: "")
        displayItem.state = panel.prefs.keepDisplayOn ? .on : .off
        menu.addItem(displayItem)

        // keep awake while chosen apps run — the non-Claude on-ramp
        let watchItem = NSMenuItem(title: "Keep Awake While Running", action: nil, keyEquivalent: "")
        watchItem.submenu = buildWatchMenu()
        menu.addItem(watchItem)

        // sleep-safety timer: hard cap on how long keep-awake can run
        let timerItem = NSMenuItem(title: "Sleep-Safety Timer", action: nil, keyEquivalent: "")
        let timerMenu = NSMenu()
        for (label, hours) in [("Off", 0.0), ("After 2 hours", 2.0), ("After 4 hours", 4.0), ("After 8 hours", 8.0)] {
            let it = NSMenuItem(title: label, action: #selector(setSafetyTimer(_:)), keyEquivalent: "")
            it.representedObject = hours
            it.state = panel.prefs.maxAwakeHours == hours ? .on : .off
            it.target = self
            timerMenu.addItem(it)
        }
        timerItem.submenu = timerMenu
        menu.addItem(timerItem)

        let chirpItem = NSMenuItem(title: "Chirp on Notifications", action: #selector(toggleChirp), keyEquivalent: "")
        chirpItem.state = panel.prefs.chirp ? .on : .off
        menu.addItem(chirpItem)
        menu.addItem(NSMenuItem.separator())

        // mascot picker
        let mascotItem = NSMenuItem(title: "Mascot", action: nil, keyEquivalent: "")
        let mascotMenu = NSMenu()
        for m in Mascot.registry {
            let it = NSMenuItem(title: m.displayName, action: #selector(selectMascot(_:)), keyEquivalent: "")
            it.representedObject = m.id
            it.state = panel.prefs.mascotID == m.id ? .on : .off
            it.target = self
            mascotMenu.addItem(it)
        }
        mascotItem.submenu = mascotMenu
        menu.addItem(mascotItem)

        // recent messages, newest first, so a missed bubble isn't gone forever
        let histItem = NSMenuItem(title: "Recent Messages", action: nil, keyEquivalent: "")
        let histMenu = NSMenu()
        if history.isEmpty {
            let none = NSMenuItem(title: "No messages yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            histMenu.addItem(none)
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            for entry in history.reversed() {
                let when = fmt.string(from: Date(timeIntervalSince1970: entry.time / 1000))
                let text = entry.text.count > 60 ? String(entry.text.prefix(57)) + "…" : entry.text
                let it = NSMenuItem(title: "\(when)   \(text)", action: nil, keyEquivalent: "")
                it.isEnabled = false
                histMenu.addItem(it)
            }
        }
        histItem.submenu = histMenu
        menu.addItem(histItem)
        menu.addItem(NSMenuItem.separator())

        if forBuddy {
            menu.addItem(withTitle: "Hide Wigbat", action: #selector(hideBuddy), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Bigger", action: #selector(biggerBuddy), keyEquivalent: "")
            menu.addItem(withTitle: "Smaller", action: #selector(smallerBuddy), keyEquivalent: "")
            menu.addItem(withTitle: "Rotate Left", action: #selector(rotateLeft), keyEquivalent: "")
            menu.addItem(withTitle: "Rotate Right", action: #selector(rotateRight), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Reset Position", action: #selector(resetPosition), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Show/Hide Buddy", action: #selector(toggleShowHide), keyEquivalent: "")
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Help", action: #selector(showHelp), keyEquivalent: "")
        menu.addItem(withTitle: "Quit Wigbat", action: #selector(quitApp), keyEquivalent: "")
        for item in menu.items where item.target == nil && item.action != nil { item.target = self }
    }

    func buildWatchMenu() -> NSMenu {
        let m = NSMenu()
        let watched = panel.prefs.watchedApps
        let running = runningRegularApps()
        let runningIDs = Set(running.compactMap { $0.bundleIdentifier })

        let header = NSMenuItem(title: "Keep the Mac awake while these run:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)

        // watched apps that aren't currently running (so they can be unchecked)
        for id in watched where !runningIDs.contains(id) {
            let it = NSMenuItem(title: "\(shortName(id))  (not running)", action: #selector(toggleWatchedApp(_:)), keyEquivalent: "")
            it.representedObject = id
            it.state = .on
            it.target = self
            m.addItem(it)
        }
        if running.isEmpty {
            let none = NSMenuItem(title: "No other apps running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            m.addItem(none)
        }
        for app in running {
            guard let id = app.bundleIdentifier else { continue }
            let it = NSMenuItem(title: app.localizedName ?? id, action: #selector(toggleWatchedApp(_:)), keyEquivalent: "")
            it.representedObject = id
            it.state = watched.contains(id) ? .on : .off
            it.image = app.icon
            it.image?.size = NSSize(width: 16, height: 16)
            it.target = self
            m.addItem(it)
        }
        return m
    }

    func shortName(_ bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    func infoLine() -> String {
        var reasons: [String] = []
        if sessionCount == 1 { reasons.append("1 Claude session") }
        else if sessionCount > 1 { reasons.append("\(sessionCount) Claude sessions") }
        reasons.append(contentsOf: watchedRunning)
        let runN = wigbatRunCount()
        if runN > 0 { reasons.append(runN == 1 ? "a command" : "\(runN) commands") }

        var line: String
        if panel.buddyView.awake {
            line = reasons.isEmpty ? "Awake (manual)" : "Awake for " + reasons.joined(separator: ", ")
            if awakeSince > 0 {
                let mins = Int(Date().timeIntervalSince1970 - awakeSince) / 60
                let dur = mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
                line += " · \(dur)"
                let maxH = panel.prefs.maxAwakeHours
                if maxH > 0 {
                    let left = Int(maxH * 60) - mins
                    if left > 0 { line += " · auto-sleep in \(left >= 60 ? "\(left / 60)h \(left % 60)m" : "\(left)m")" }
                }
            }
        } else {
            line = "Asleep — Mac can sleep normally"
        }
        return line
    }

    func updateStatusIcon() {
        let m = panel.buddyView.mascot
        let img = panel.buddyView.awake ? m.menuAwake : m.menuAsleep
        img?.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = img
    }

    @objc func setSafetyTimer(_ sender: NSMenuItem) {
        panel.prefs.maxAwakeHours = (sender.representedObject as? Double) ?? 0
        panel.prefs.save()
    }

    @objc func toggleChirp() {
        panel.prefs.chirp.toggle()
        panel.prefs.save()
        if panel.prefs.chirp { NSSound(named: "Pop")?.play() }  // audible confirmation
    }

    @objc func toggleAwake() {
        let awake = panel.buddyView.awake
        runScript(awake ? "\(binDir)/killawake" : "\(binDir)/stayawake")
        writeOverride(!awake)
        panel.buddyView.setAwake(!awake)
        panel.buddyView.needsDisplay = true
        updateStatusIcon()
    }

    @objc func toggleKeepDisplayOn() {
        panel.prefs.keepDisplayOn.toggle()
        panel.prefs.save()
        if panel.buddyView.awake {
            // re-run stayawake so caffeinate picks up the new display flag
            runScript("\(binDir)/stayawake")
        }
        updateStatusIcon()
    }

    @objc func toggleWatchedApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if let i = panel.prefs.watchedApps.firstIndex(of: id) {
            panel.prefs.watchedApps.remove(at: i)
        } else {
            panel.prefs.watchedApps.append(id)
        }
        panel.prefs.save()
        watchedRunning = runningWatchedAppNames()
        poll()
    }

    @objc func selectMascot(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        panel.setMascot(id)
        updateStatusIcon()
    }

    @objc func toggleShowHide() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc func hideBuddy() { panel.orderOut(nil) }
    @objc func biggerBuddy() { panel.applyScale(0.1) }
    @objc func smallerBuddy() { panel.applyScale(-0.1) }
    @objc func rotateLeft() { panel.applyTilt(-10) }
    @objc func rotateRight() { panel.applyTilt(10) }
    @objc func resetPosition() { panel.resetPosition() }

    @objc func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Wigbat"
        alert.informativeText = """
        Wigbat keeps your Mac awake while things you care about are running — Claude Code sessions, apps you choose, or any command — and lets it sleep when they're done.

        • Left-click the buddy: toggle keep-awake manually
        • Drag the buddy: move it anywhere, on any display
        • Right-click the buddy: menu (mascot, timer, chirp, history, resize, rotate, quit…)
        • Hover: reveal it fully; move away: it tucks back in
        • Speech bubble: click it to dismiss
        • Mascot: pick your character (Bat, Cat, …)
        • Keep Awake While Running: choose apps that should hold the Mac awake
        • wigbat CLI: `wigbat notify "…"`, `wigbat on/off`, `wigbat run -- <cmd>`
        • Sleep-Safety Timer: auto-stop keep-awake after 2/4/8 hours
        """
        alert.runModal()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

// Single-instance guard — hold an exclusive lock so only one buddy ever runs,
// no matter how it was launched (LaunchAgent, Spotlight, Finder, or terminal).
// The FD is intentionally leaked for the process lifetime so the lock is held.
try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
let lockFD = open("\(stateDir)/buddy.lock", O_CREAT | O_RDWR, 0o644)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    FileHandle.standardError.write(Data("Wigbat is already running — not starting a second instance.\n".utf8))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
