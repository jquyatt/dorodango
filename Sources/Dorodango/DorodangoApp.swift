import SwiftUI
import AppKit
import Combine

@main
struct DorodangoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        // No real window — the UI lives in a status-bar panel (see AppDelegate).
        Settings { EmptyView() }
    }
}

/// Shared UI state so the AppDelegate can reset the panel to the drop zone
/// each time it opens.
@MainActor
final class PanelState: ObservableObject {
    @Published var showSettings = false
}

/// A borderless panel that can still become key, so the URL text field accepts
/// typing. Crucially it does NOT auto-close on resignKey, so you can click into
/// Finder to start a drag without the panel vanishing.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Transparent overlay on the status-bar button that accepts dropped files and
/// URLs, and forwards a plain click to toggle the panel.
final class DropTargetView: NSView {
    var onClick: () -> Void = {}
    var onFiles: ([URL]) -> Void = { _ in }
    var onText: (String) -> Void = { _ in }

    override init(frame: NSRect) { super.init(frame: frame); register() }
    required init?(coder: NSCoder) { super.init(coder: coder); register() }

    private func register() {
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    override func mouseDown(with event: NSEvent) { onClick() }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        // Local files first.
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onFiles(urls)
            return true
        }
        // A web URL (e.g. dragged from a browser address bar).
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           let first = urls.first {
            if first.isFileURL { onFiles([first]) } else { onText(first.absoluteString) }
            return true
        }
        // Plain text that might be a URL.
        if let str = pb.string(forType: .string) {
            onText(str)
            return true
        }
        return false
    }
}

/// Spins the menu bar icon while work is in progress. Placeholder animation:
/// rotates a dotted-circle symbol; restores the static circle when idle.
@MainActor
final class IconAnimator {
    private weak var button: NSStatusBarButton?
    private let idle: NSImage
    private let spin: NSImage
    private var timer: Timer?
    private var angle: CGFloat = 0

    init(button: NSStatusBarButton, symbolName: String) {
        self.button = button
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        func img(_ name: String) -> NSImage {
            let i = NSImage(systemSymbolName: name, accessibilityDescription: "Dorodango")?
                .withSymbolConfiguration(cfg) ?? NSImage()
            i.isTemplate = true
            return i
        }
        self.idle = img(symbolName)
        self.spin = img("circle.dotted")
        button.image = idle
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)   // keep spinning during menu tracking
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        angle = 0
        button?.image = idle
    }

    private func tick() {
        angle -= .pi / 18                        // ~10° per frame
        if angle <= -.pi * 2 { angle += .pi * 2 }
        button?.image = rotated(spin, by: angle)
    }

    private func rotated(_ image: NSImage, by radians: CGFloat) -> NSImage {
        let size = image.size
        let out = NSImage(size: size)
        out.lockFocus()
        let t = NSAffineTransform()
        t.translateX(by: size.width / 2, yBy: size.height / 2)
        t.rotate(byRadians: radians)
        t.translateX(by: -size.width / 2, yBy: -size.height / 2)
        t.concat()
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size),
                   operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        out.isTemplate = true
        return out
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let queue = ProcessingQueue()
    let panelState = PanelState()

    private var statusItem: NSStatusItem!
    private var panel: KeyablePanel!
    private var runningObserver: AnyCancellable?
    private var resizeObserver: NSObjectProtocol?
    private var pinnedTopY: CGFloat = 0   // keep the panel's top edge fixed as it grows
    private var iconAnimator: IconAnimator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.requestAuthorization()
        setupStatusItem()
        setupPanel()

        if let button = statusItem.button {
            iconAnimator = IconAnimator(button: button, symbolName: "circle.circle")
        }

        // Spin the menu bar icon while work is happening.
        runningObserver = queue.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] running in
                if running { self?.iconAnimator?.start() } else { self?.iconAnimator?.stop() }
            }
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.circle",
                                   accessibilityDescription: "Dorodango")
            button.action = #selector(togglePanel)
            button.target = self

            // Overlay so the icon itself accepts dropped files / URLs.
            let drop = DropTargetView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onClick = { [weak self] in Task { @MainActor in self?.togglePanel() } }
            drop.onFiles = { [weak self] urls in Task { @MainActor in self?.enqueueFiles(urls) } }
            drop.onText  = { [weak self] text in Task { @MainActor in self?.handleDropped(text) } }
            button.addSubview(drop)
        }
    }

    // MARK: Drop handling (from the menu bar icon)

    private func enqueueFiles(_ urls: [URL]) {
        queue.add(urls: urls)
        showPanel()
    }

    private func handleDropped(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("http") {
            queue.add(remote: t)
            showPanel()
        } else {
            let url = URL(fileURLWithPath: t)
            if FileManager.default.fileExists(atPath: url.path) {
                queue.add(urls: [url])
                showPanel()
            }
        }
    }

    // MARK: Panel

    private func setupPanel() {
        let root = MenuContentView()
            .environmentObject(queue)
            .environmentObject(panelState)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

        let controller = NSHostingController(rootView: root)

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.contentViewController = controller   // window auto-sizes to SwiftUI content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false            // stay open when focus leaves (drag!)
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = false
        self.panel = panel

        // As the SwiftUI content changes height (queue ↔ settings), keep the top edge pinned.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            self?.repinTop()
        }
    }

    // MARK: Show / hide

    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { openPanel() }
    }

    private func openPanel() {
        panelState.showSettings = false   // always open to the drop zone
        positionPanel()
        pinnedTopY = panel.frame.maxY
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Don't let the URL field auto-grab the cursor on open. Clear first
        // responder after SwiftUI finishes its initial layout.
        DispatchQueue.main.async { [weak self] in
            self?.panel.makeFirstResponder(nil)
        }
    }

    /// Bring the panel up if it isn't already (used after a drop on the icon).
    private func showPanel() {
        if !panel.isVisible { openPanel() }
    }

    private func positionPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = NSScreen.main else { return }

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        var x = buttonRect.midX - size.width / 2
        let y = buttonRect.minY - size.height - 6

        let visible = screen.visibleFrame
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Keep the top of the panel where it was when it grows/shrinks.
    private func repinTop() {
        guard panel.isVisible, pinnedTopY > 0 else { return }
        var frame = panel.frame
        let newY = pinnedTopY - frame.height
        if abs(frame.origin.y - newY) > 0.5 {
            frame.origin.y = newY
            panel.setFrame(frame, display: true)
        }
    }
}
