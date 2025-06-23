import Cocoa
import CoreGraphics
import Carbon.HIToolbox
import ScreenCaptureKit

// MARK: – Display helper ----------------------------------------------------

enum DisplayHelper {
    /// All attached displays (main first)
    static var active: [CGDirectDisplayID] {
        var cnt: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &cnt)
        var list = [CGDirectDisplayID](repeating: 0, count: Int(cnt))
        CGGetActiveDisplayList(cnt, &list, &cnt)
        return Array(list.prefix(Int(cnt)))
    }

    /// Prefer externals; fall back to main if none
    static var selectable: [CGDirectDisplayID] {
        let main = CGMainDisplayID()
        let externals = active.filter { $0 != main }
        return externals.isEmpty ? [main] : externals
    }

    /// Human‑readable name or generic fallback
    static func name(for id: CGDirectDisplayID, idx: Int) -> String {
        if let screen = NSScreen.screens.first(where: {
            guard let num = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return num.uint32Value == id
        }) {
            return screen.localizedName
        }
        return "Monitor \(idx + 1)"
    }
}

// MARK: – AppDelegate -------------------------------------------------------

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu = NSMenu()
    private var mirror = MirrorController(displayID: DisplayHelper.selectable.first!)
    private var globalMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        
        // menu‑bar item (left‑click = toggle, right‑click = menu)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(named: "BeeTemplate")
            btn.toolTip = "Beeno — Toggle Preview (⌥B)"
            btn.target = self
            btn.action = #selector(statusItemClicked(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusMenu.delegate = self

        mirror.showWindow()
        registerHotkey()
    }

    // MARK: status‑item click handler --------------------------------------
    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            // show dropdown on right‑click
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil) // pops menu
            statusItem.menu = nil                // detach menu to keep left‑click action
        } else {
            mirror.toggleWindow()                 // left‑click toggles preview
        }
    }

    // MARK: menu
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (idx, id) in DisplayHelper.selectable.enumerated() {
            let item = NSMenuItem(title: DisplayHelper.name(for: id, idx: idx),
                                  action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.representedObject = id as NSNumber
            if id == mirror.currentDisplayID { item.state = .on }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Beeno", action: #selector(quit), keyEquivalent: "q"))
    }
    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        mirror.switchDisplay(to: CGDirectDisplayID(truncating: num))
    }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: hotkey ⌥B
    private func registerHotkey() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in _ = self?.handle(e) }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handle(e) ?? e }
    }
    private func handle(_ e: NSEvent) -> NSEvent? {
        if e.keyCode == UInt16(kVK_ANSI_B) &&
            e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option {
            mirror.toggleWindow(); return nil
        }
        return e
    }
}

// MARK: – MirrorController --------------------------------------------------

final class MirrorController: NSObject, SCStreamOutput, SCStreamDelegate, NSWindowDelegate {
    private(set) var currentDisplayID: CGDirectDisplayID

    // UI
    private let window: NSWindow
    private let imageView = NSImageView()

    // Capture
    private var stream: SCStream?
    private let ci = CIContext()

    // Remember frame in session
    private var lastFrame: NSRect?

    init(displayID: CGDirectDisplayID) {
        currentDisplayID = displayID

        // window setup
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 500),
                          styleMask: [.titled, .resizable, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Beeno — Preview"
        window.isReleasedWhenClosed = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        window.contentView = imageView
        
        // ► immer im Vordergrund + in allen Spaces
        window.level = .floating
        window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])

        super.init()
        window.delegate = self
        Task { await startStream(for: displayID) }
    }

    // MARK: stream
    private func startStream(for id: CGDirectDisplayID) async {
        stopStream()
        guard let content = try? await SCShareableContent.current,
              let disp = content.displays.first(where: { $0.displayID == id }) else { return }
        let cfg = SCStreamConfiguration()
        cfg.width = disp.width; cfg.height = disp.height
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        let filter = SCContentFilter(display: disp, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue.global(qos: .userInitiated))
            try await s.startCapture()
            stream = s
        } catch {
            NSLog("Beeno: stream error — %@", error.localizedDescription)
        }
    }
    private func stopStream() { stream?.stopCapture(); stream = nil }

    func switchDisplay(to id: CGDirectDisplayID) {
        guard id != currentDisplayID else { return }
        currentDisplayID = id
        Task { await startStream(for: id) }
    }

    // MARK: window helpers
    func showWindow() {
        if let f = lastFrame { window.setFrame(f, display: true) } else { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func toggleWindow() {
        if window.isVisible {
            lastFrame = window.frame
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }
    func windowWillClose(_ n: Notification) { lastFrame = window.frame }

    // MARK: SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let buf = sb.imageBuffer else { return }
        let ciImg = CIImage(cvImageBuffer: buf)
        let rep = NSCIImageRep(ciImage: ciImg)
        let ns = NSImage(size: rep.size); ns.addRepresentation(rep)
        DispatchQueue.main.async { self.imageView.image = ns }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Beeno: stream stopped — %@", error.localizedDescription)
    }
}
