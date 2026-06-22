import AppKit
import GhosttyKit
import QuartzCore

final class GhosttyTerminalNSView: NSView {
    /// Weak registry of every live instance so global operations (e.g. config
    /// reload) can iterate without a central cache.
    @MainActor private static let liveViews = NSHashTable<GhosttyTerminalNSView>.weakObjects()
    @MainActor
    static func allLiveViews() -> [GhosttyTerminalNSView] {
        liveViews.allObjects
    }

    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    private let workingDirectory: String
    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onProcessExit: (() -> Void)?
    var onSplitRequest: ((SplitDirection, SplitPosition) -> Void)?
    var onZoomRequest: (() -> Void)?
    var isZoomed: Bool = false
    var onSearchStart: ((String?) -> Void)?
    var onSearchEnd: (() -> Void)?
    var onSearchTotal: ((Int?) -> Void)?
    var onSearchSelected: ((Int?) -> Void)?
    var onCommandSubmitted: ((String) -> Void)?
    var onCommandFinished: (() -> Void)?
    var onProgressActivityChange: ((Bool) -> Void)?
    var onAssistantOutputActivity: ((String) -> Void)?
    var isFocused: Bool = false
    var currentPwd: String?

    var _markedRange: NSRange = .init(location: NSNotFound, length: 0)
    var _selectedRange: NSRange = .init(location: NSNotFound, length: 0)
    var keyTextAccumulator: [String] = []
    var currentKeyEvent: NSEvent?
    var commandLineBuffer = ""
    private var assistantOutputMonitorTask: Task<Void, Never>?
    private var assistantOutputDigest: UInt64?

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        setupTrackingArea()
        Self.liveViews.add(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.framebufferOnly = false
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.needsDisplayOnBoundsChange = true
        layer.presentsWithTransaction = false
        return layer
    }

    override var wantsUpdateLayer: Bool { true }

    // MARK: - Surface lifecycle

    private var pendingSurfaceCreation = false

    /// Once destroySurface() has been called this view is "retired": it should
    /// never spontaneously recreate a surface (e.g. from viewDidMoveToWindow or
    /// from a stray updateNSView during SwiftUI teardown).
    private var isDestroyed = false

    func createSurface() {
        guard !isDestroyed else { return }
        guard surface == nil, let app = GhosttyApp.shared.app else { return }
        let backingSize = convertToBacking(bounds).size
        guard backingSize.width > 0, backingSize.height > 0 else {
            pendingSurfaceCreation = true
            return
        }
        pendingSurfaceCreation = false

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
        config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        workingDirectory.withCString { cwd in
            config.working_directory = cwd
            surface = ghostty_surface_new(app, &config)
        }
        guard let surface else { return }

        let scale = Double(window?.backingScaleFactor ?? 2.0)
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(backingSize.width), UInt32(backingSize.height))

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_surface_set_color_scheme(surface, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)

        if let screen = window?.screen ?? NSScreen.main,
           let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        {
            ghostty_surface_set_display_id(surface, displayID)
        }
        ghostty_surface_set_focus(surface, isFocused)
    }

    func destroySurface() {
        stopAssistantOutputMonitor()
        isDestroyed = true
        if let surface { ghostty_surface_free(surface) }
        surface = nil
    }

    deinit {
        if let surface { ghostty_surface_free(surface) }
        for token in windowObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Tear down previous window's observers.
        for token in windowObservers {
            NotificationCenter.default.removeObserver(token)
        }
        windowObservers.removeAll()

        guard let window else { return }
        if surface == nil {
            createSurface()
        } else {
            // Reconnect existing surface to the new window
            let scale = Double(window.backingScaleFactor)
            ghostty_surface_set_content_scale(surface, scale, scale)
            let size = convertToBacking(bounds).size
            if size.width > 0, size.height > 0 {
                ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
            }
            ghostty_surface_set_focus(surface, isFocused)
        }
        updateMetalLayerSize()

        // The per-view `viewDidChangeBackingProperties` override doesn't reliably
        // fire when the window moves between displays of different DPI. Listen
        // on the window directly so the surface picks up the new scale even
        // when AppKit doesn't propagate the call to every layer-backed subview.
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMetalLayerSize() }
        }
        let backing = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeBackingPropertiesNotification,
            object: window,
            queue: .main,
            using: handler
        )
        let screen = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main,
            using: handler
        )
        windowObservers = [backing, screen]
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if pendingSurfaceCreation { createSurface() }
        updateMetalLayerSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMetalLayerSize()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let surface else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_surface_set_color_scheme(surface, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    private func updateMetalLayerSize() {
        guard let surface, window != nil else { return }
        let scaledSize = convertToBacking(bounds).size
        guard scaledSize.width > 0, scaledSize.height > 0 else { return }
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        if let metalLayer = layer as? CAMetalLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.contentsScale = CGFloat(scale)
            CATransaction.commit()
        }
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
    }

    func needsConfirmQuit() -> Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    func notifySurfaceFocused() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, true)
    }

    func notifySurfaceUnfocused() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, false)
    }

    func startAssistantOutputMonitor(assistant: String) {
        assistantOutputMonitorTask?.cancel()
        assistantOutputDigest = visibleTextDigest()
        assistantOutputMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard let self else { return }
                guard let digest = self.visibleTextDigest() else { continue }
                if let previous = self.assistantOutputDigest, previous != digest {
                    self.assistantOutputDigest = digest
                    self.onAssistantOutputActivity?(assistant)
                } else if self.assistantOutputDigest == nil {
                    self.assistantOutputDigest = digest
                }
            }
        }
    }

    func stopAssistantOutputMonitor() {
        assistantOutputMonitorTask?.cancel()
        assistantOutputMonitorTask = nil
        assistantOutputDigest = nil
    }

    private func visibleTextDigest() -> UInt64? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.width_px > 0, size.height_px > 0 else { return nil }

        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SURFACE,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SURFACE,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: size.width_px,
                y: size.height_px
            ),
            rectangle: true
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return 0 }

        var hash: UInt64 = 14_695_981_039_346_656_037
        let bytes = UnsafeBufferPointer(start: ptr, count: Int(text.text_len))
        for byte in bytes {
            hash ^= UInt64(UInt8(bitPattern: byte))
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    // MARK: - First responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, true)
            onFocus?()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface { ghostty_surface_set_focus(surface, false) }
        return result
    }

    // MARK: - Tracking area

    private var currentTrackingArea: NSTrackingArea?

    private func setupTrackingArea() {
        if let existing = currentTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        currentTrackingArea = area
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        setupTrackingArea()
    }
}
