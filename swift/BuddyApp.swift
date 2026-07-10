import AppKit
import Foundation

let home = NSHomeDirectory()
let stateDir = "\(home)/claude-awake-buddy/state"
let binDir = "\(home)/claude-awake-buddy/bin"
let assetsDir = "\(home)/claude-awake-buddy/assets"
let prefsPath = "\(stateDir)/prefs.json"

struct Prefs {
    var posXFrac: CGFloat = 0.5   // free position, fraction of available screen width
    var posYFrac: CGFloat = 1.0   // 1.0 = flush to top (default, near the camera)
    var scale: CGFloat = 1.0
    var tilt: CGFloat = 0       // rotation in degrees; user-adjustable via the menu

    static func load() -> Prefs {
        var p = Prefs()
        if let data = FileManager.default.contents(atPath: prefsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let x = json["posXFrac"] as? NSNumber { p.posXFrac = CGFloat(x.doubleValue) }
            if let y = json["posYFrac"] as? NSNumber { p.posYFrac = CGFloat(y.doubleValue) }
            if let s = json["scale"] as? NSNumber { p.scale = CGFloat(s.doubleValue) }
            if let t = json["tilt"] as? NSNumber { p.tilt = CGFloat(t.doubleValue) }
        }
        return p
    }

    func save() {
        let json: [String: Any] = ["posXFrac": posXFrac, "posYFrac": posYFrac, "scale": scale, "tilt": tilt]
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

func readState() -> (awake: Bool, message: String?, messageTime: Double) {
    var awake = false
    var message: String? = nil
    var messageTime: Double = 0
    if let data = FileManager.default.contents(atPath: "\(stateDir)/state.json"),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        awake = (json["awake"] as? Bool) ?? false
    }
    if let data = FileManager.default.contents(atPath: "\(stateDir)/message.json"),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        message = json["message"] as? String
        if let t = json["time"] as? NSNumber { messageTime = t.doubleValue }
    }
    return (awake, message, messageTime)
}

func loadImage(_ name: String) -> NSImage? {
    NSImage(contentsOfFile: "\(assetsDir)/\(name).png")
}

// MARK: - Buddy view

final class BuddyView: NSView {
    var awake = false
    var hovered = false
    var message: String? = nil
    var messageTime: Double = 0
    var notifyUntil: Double = 0
    var phase: CGFloat = 0
    var revealProgress: CGFloat = 0
    var scale: CGFloat = 1.0
    var tilt: CGFloat = 0

    var dragging = false
    var dragStartMouse = NSPoint.zero
    var dragStartOrigin = NSPoint.zero

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

    override func mouseUp(with event: NSEvent) {
        if dragging {
            (window as? BuddyPanel)?.persistCurrentPosition()
        } else {
            runScript(awake ? "\(binDir)/killawake" : "\(binDir)/stayawake")
            awake.toggle()
            needsDisplay = true
        }
        dragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = buildBuddyMenu()
        let point = convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: point, in: self)
    }

    // total composite size at scale 1.0, before the user scale factor
    let baseWidth: CGFloat = 100
    let baseHeight: CGFloat = 100

    func compositeHeight() -> CGFloat { baseHeight * scale }
    func compositeWidth() -> CGFloat { baseWidth * scale }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()

        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()

        // restY: where the composite's center sits when fully revealed, comfortably
        // inside the window. collapseTravel: how far it's pushed past the window's
        // edge (off-canvas, clipped) when fully collapsed, leaving only a small peek.
        let restY = compositeHeight() / 2 + 8
        let collapseTravel = compositeHeight() * 1.3
        let localShift = collapseTravel * (1 - revealProgress)
        let pivot = NSPoint(x: bounds.width / 2, y: restY)

        ctx?.translateBy(x: pivot.x, y: pivot.y)
        ctx?.rotate(by: tilt * .pi / 180)
        ctx?.scaleBy(x: -1, y: 1) // mirrored left-right
        ctx?.translateBy(x: 0, y: localShift) // push toward the edge (off-canvas) in local space

        let w = compositeWidth()
        let branchH = compositeHeight() * (70.0 / 299.0)
        let bodyH = compositeHeight() * (229.0 / 299.0)
        let bob = hovered ? sin(phase) * 2.0 : 0

        // branch: fixed, never bobs, never changes with awake/asleep
        if let branch = branchImage {
            let r = NSRect(x: -w / 2, y: bodyH / 2, width: w, height: branchH)
            branch.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
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
            body.draw(in: bodyRect, from: .zero, operation: .sourceOver, fraction: 1.0)

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

        if !awake && revealProgress > 0.4 {
            let zAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: NSColor(calibratedRed: 0.6, green: 0.64, blue: 0.7, alpha: 1.0),
            ]
            let drift = CGFloat((sin(phase) + 1) / 2) * 8
            ("z Z z" as NSString).draw(at: NSPoint(x: bodyRect.maxX - 10, y: bodyRect.maxY - 10 + drift), withAttributes: zAttrs)
        }

        ctx?.restoreGState()

        let showBubble = message != nil && messageTime > 0 && (Date().timeIntervalSince1970 * 1000 - messageTime) < 8000
        if showBubble, revealProgress > 0.6, let msg = message {
            drawBubble(msg)
        }
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
        let bubbleW: CGFloat = bounds.width * 0.92
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ]
        let textW = bubbleW - 16
        let bounding = (msg as NSString).boundingRect(
            with: NSSize(width: textW, height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs)
        let bubbleH = min(90, max(28, bounding.height + 14))
        let bubbleRect = NSRect(x: (bounds.width - bubbleW) / 2, y: 2, width: bubbleW, height: bubbleH)

        let path = NSBezierPath(roundedRect: bubbleRect, xRadius: 8, yRadius: 8)
        NSColor(calibratedWhite: 0.12, alpha: 0.92).setFill()
        path.fill()
        (msg as NSString).draw(in: bubbleRect.insetBy(dx: 8, dy: 7), withAttributes: attrs)
    }
}

func buildBuddyMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(withTitle: "Hide Wigbat", action: #selector(AppDelegate.hideBuddy), keyEquivalent: "")
    menu.addItem(NSMenuItem.separator())
    menu.addItem(withTitle: "Bigger", action: #selector(AppDelegate.biggerBuddy), keyEquivalent: "")
    menu.addItem(withTitle: "Smaller", action: #selector(AppDelegate.smallerBuddy), keyEquivalent: "")
    menu.addItem(withTitle: "Rotate Left", action: #selector(AppDelegate.rotateLeft), keyEquivalent: "")
    menu.addItem(withTitle: "Rotate Right", action: #selector(AppDelegate.rotateRight), keyEquivalent: "")
    menu.addItem(NSMenuItem.separator())
    menu.addItem(withTitle: "Reset Position", action: #selector(AppDelegate.resetPosition), keyEquivalent: "")
    menu.addItem(NSMenuItem.separator())
    menu.addItem(withTitle: "Help", action: #selector(AppDelegate.showHelp), keyEquivalent: "")
    menu.addItem(withTitle: "Quit Wigbat", action: #selector(AppDelegate.quitApp), keyEquivalent: "")
    for item in menu.items { item.target = NSApp.delegate }
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
        buddyView.scale = prefs.scale
        buddyView.tilt = prefs.tilt
        contentView = buddyView
        layout()
        orderFrontRegardless()
    }

    func layout() {
        guard let screen = NSScreen.main else { return }
        let sf = screen.frame
        let size = frame.size
        let origin = NSPoint(
            x: sf.minX + (sf.width - size.width) * prefs.posXFrac,
            y: sf.minY + (sf.height - size.height) * prefs.posYFrac
        )
        setFrameOrigin(origin)
    }

    func persistCurrentPosition() {
        guard let screen = NSScreen.main else { return }
        let sf = screen.frame
        let size = frame.size
        let o = frame.origin
        prefs.posXFrac = max(0, min(1, (o.x - sf.minX) / max(1, sf.width - size.width)))
        prefs.posYFrac = max(0, min(1, (o.y - sf.minY) / max(1, sf.height - size.height)))
        prefs.save()
    }

    func resetPosition() {
        prefs.posXFrac = 0.5
        prefs.posYFrac = 1.0
        prefs.tilt = 0
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
        prefs.scale = max(0.5, min(2.0, prefs.scale + delta))
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
}

// MARK: - App delegate + status item

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: BuddyPanel!
    var statusItem: NSStatusItem!
    var renderTimer: Timer!
    var pollTimer: Timer!
    var menuIconAwake: NSImage?
    var menuIconAsleep: NSImage?
    var lastSeenMessageTime: Double = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = BuddyPanel()
        setupStatusItem()

        renderTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let v = self.panel.buddyView
            v.phase += 0.06
            let nowMs = Date().timeIntervalSince1970 * 1000
            let target: CGFloat = (v.hovered || nowMs < v.notifyUntil) ? 1.0 : 0.0
            v.revealProgress += (target - v.revealProgress) * 0.25
            if abs(v.revealProgress - target) < 0.01 { v.revealProgress = target }
            v.needsDisplay = true
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            var s = readState()
            if s.awake && !anyClaudeSessionRunning() {
                // a session was likely force-killed and SessionEnd never fired —
                // self-heal instead of staying awake forever.
                runScript("\(binDir)/killawake")
                s.awake = false
            }
            self.panel.buddyView.awake = s.awake
            self.panel.buddyView.message = s.message
            self.panel.buddyView.messageTime = s.messageTime
            if s.messageTime > self.lastSeenMessageTime, s.message != nil {
                self.lastSeenMessageTime = s.messageTime
                self.panel.buddyView.notifyUntil = s.messageTime + 6000
                if !self.panel.isVisible { self.panel.orderFrontRegardless() }
            }
            self.updateStatusIcon()
        }
        pollTimer.fire()
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menuIconAwake = loadImage("menu-icon-awake")
        menuIconAsleep = loadImage("menu-icon-asleep")
        menuIconAwake?.size = NSSize(width: 18, height: 18)
        menuIconAsleep?.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = menuIconAwake
        statusItem.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "Keep Awake (Wigbat Active)", action: #selector(toggleAwake), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem.separator())
        let showHideItem = NSMenuItem(title: "Show/Hide Buddy", action: #selector(toggleShowHide), keyEquivalent: "")
        showHideItem.target = self
        menu.addItem(showHideItem)
        menu.addItem(NSMenuItem.separator())
        let helpItem = NSMenuItem(title: "Help", action: #selector(showHelp), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)
        let quitItem = NSMenuItem(title: "Quit Wigbat", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func updateStatusIcon() {
        statusItem.button?.image = panel.buddyView.awake ? menuIconAwake : menuIconAsleep
    }

    @objc func toggleAwake() {
        let awake = panel.buddyView.awake
        runScript(awake ? "\(binDir)/killawake" : "\(binDir)/stayawake")
        panel.buddyView.awake.toggle()
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
        Wigbat keeps your Mac awake while Claude Code sessions are running, and lets it sleep normally when you're done.

        • Left-click the bat: toggle keep-awake manually
        • Drag the bat: move it anywhere on screen, free-hand
        • Right-click the bat: menu (hide, resize, rotate, reset position, help, quit)
        • Hover: reveal it fully; move away: it tucks back in
        • Menu bar icon: same controls, always available
        """
        alert.runModal()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
