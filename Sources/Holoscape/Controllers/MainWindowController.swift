import AppKit

@MainActor
class MainWindowController: NSObject, NSWindowDelegate, NSSplitViewDelegate,
    TabBarViewDelegate, SidebarViewDelegate, SessionLauncherDelegate,
    InputBoxViewDelegate, ChannelControllerDelegate, NotificationChannelSwitchDelegate,
    SplitPaneManagerDelegate, ChromeRegionManagerDelegate, SkinEngineFileWatcherDelegate {

    /// Amplify Task 5.3 makes this reassignable so shaped-window
    /// transitions can swap the underlying `NSWindow` instance without
    /// breaking every caller that reads `.window`. Outside the shape-
    /// transition path this is still effectively a let — no other
    /// code reassigns it.
    var window: NSWindow
    let channelManager: ChannelManager
    private let configService: ConfigService
    private var profileManager: SessionProfileManager?

    private let splitView = NSSplitView()
    private let sidebarContainer = NSView()
    private let sessionLauncher = SessionLauncherView(frame: .zero)
    private let sidebarView = SidebarView(frame: .zero)
    private let tabBar = TabBarView(frame: .zero)
    /// Height constraint on the title-bar tab strip. Toggled between 32pt
    /// and 0pt so that when the sidebar is expanded (which renders the
    /// tab list itself) the top tab strip collapses cleanly rather than
    /// leaving a 32pt gap above the terminal. See `tabBarVisibility(forSidebarExpanded:)`.
    private var tabBarHeightConstraint: NSLayoutConstraint?
    private let splitPaneManager = SplitPaneManager(frame: .zero)

    // MARK: - Amplify shape state (Task 5)

    /// Owns feature-flag gating, descriptor validation, mask-layer
    /// construction, and window reconstruction. Initialized once at
    /// `init()` — the flag is cached, so a runtime env flip requires
    /// relaunch.
    private let shapedWindowController = ShapedWindowController()

    /// The shape currently driving the window's style mask + content-
    /// view mask, or nil when the window is rectangular. Tracked here
    /// so `applySkin` can decide between "no-op," "install mask,"
    /// "reconstruct into borderless," and "reconstruct into titled."
    private var currentWindowShape: ResolvedWindowShape?

    /// Amplify Task 9 — active drag-region tracker for the current
    /// skin. Nil when: skin has no drag regions, OR the feature flag
    /// is off, OR the window is rectangular and no regions are
    /// declared (in which case `isMovableByWindowBackground` handles
    /// drag per Req 4.6).
    private var currentDragRegionTracker: DragRegionTracker?
    private let inputBox: InputBoxView
    private let inputContainer: NSScrollView

    // External chrome bands — decorative strips around the window content
    // area that a skin can paint graphics into (Winamp-style). Default
    // size is zero in both axes; skin engine inflates them at load time
    // in a later task. Existence here means a skin's `surfaces.top.*`
    // etc. have real NSViews + layers to paint into.
    private let topChromeBand = NSView()
    private let rightChromeBand = NSView()
    private let bottomChromeBand = NSView()
    private let leftChromeBand = NSView()
    private var topChromeBandHeight: NSLayoutConstraint?
    private var rightChromeBandWidth: NSLayoutConstraint?
    private var bottomChromeBandHeight: NSLayoutConstraint?
    private var leftChromeBandWidth: NSLayoutConstraint?

    /// Expanded size for external chrome bands (pre-skin default).
    /// Zero today because no skin paints them yet; when skins define
    /// band backgrounds, the skin engine will set the non-zero size.
    /// Keeping this as a named constant documents the extension point.
    private let externalBandDefaultExpandedSize: CGFloat = 0

    private(set) var activeChannelId: UUID?
    private var cachedShader: CompiledShader?
    /// Internal left-nav section state. Distinct from the external chrome
    /// bands managed by `regionManager` — the sidebar is a panel INSIDE
    /// the window content area, not a decorative edge band.
    private var sidebarExpanded: Bool = true
    /// Manages the four EXTERNAL chrome bands (top/right/bottom/left)
    /// that surround the window content. Collapses the band's size
    /// constraint to zero. Independent of internal panel state.
    private let regionManager: ChromeRegionManager

    /// Runtime density switch (Full / Minimal / Off). Owned here because
    /// MainWindowController already holds `configService` and needs to
    /// read / update menu-item checkmark state on `.densityModeDidChange`.
    /// Exposed `internal` so AppDelegate can pass it to AppearanceSettings.
    let densityModeManager: DensityModeManager

    /// Reactive snapshot shared across chrome views so state-variant
    /// matches (hover, agentState, etc.) stay coherent during a layout
    /// pass. Owned here so MainWindowController can update it in response
    /// to AppKit events later (hover enter/exit, channel state changes).
    let reactiveSnapshot = ReactiveUniformSnapshot()

    /// Current skin context driving the chrome. Starts as the built-in
    /// defaults (identical colors to the pre-skinning era). Task 11.3
    /// will rebuild this from `SkinEngine.apply` on `.skinDidChange`;
    /// today, swapping this property re-renders via the skinDidChange
    /// notification fired by chrome views.
    private(set) var skinContext: SkinContext

    /// Owner of the one `SkinEngine` instance the app shares. Picker,
    /// launch-time load, and (Task 11) hot-reload all go through this
    /// engine so CTFontManager registrations, image caches, and the
    /// currently-watched skin directory stay in one lifecycle.
    let skinEngine = SkinEngine()

    /// Fonts currently registered at process scope. Tracked so the next
    /// `reloadSkin(named:)` can pass the exact URL set to
    /// `unregisterFonts(_:)` before registering the new bundle — keeps
    /// font registration symmetric (Property 9 invariant).
    private var currentFontBundle: SkinFontBundle = SkinFontBundle(fonts: [:], registeredURLs: [])

    /// Debounce slot for FSEventStream-driven reloads (Task 11). The
    /// file watcher fires on every write inside the active skin's
    /// directory — editors frequently issue a cluster of syscalls
    /// (rename / write-tempfile / move-over) per user save, so we
    /// coalesce to a single `reloadSkin` call 200 ms after the last
    /// event. Cancelled whenever the user picks a different skin
    /// manually so stale disk events can't race with the selection.
    private var pendingReloadWorkItem: DispatchWorkItem?

    /// Reader Mode controller (Task 12) — floating NSPanel that shows
    /// the active channel's scrollback as plain text. Constructed eagerly
    /// at init (cheap: no panel built until first `activate`) and retained
    /// for the window-controller's lifetime so `⌘⇧R` toggling reuses the
    /// same instance.
    private let readerModeController = ReaderModeController()

    // References to Density menu items so we can flip the checkmark
    // `.state` when `.densityModeDidChange` fires. Weak because AppKit
    // retains menu items through the menu graph.
    private weak var densityFullMenuItem: NSMenuItem?
    private weak var densityMinimalMenuItem: NSMenuItem?
    private weak var densityOffMenuItem: NSMenuItem?
    nonisolated(unsafe) private var elapsedTimeTimer: Timer?
    private var notificationService: NotificationService?
    let historyBuffer = HistoryBuffer()
    weak var apiServer: HoloscapeAPIServer?
    private let bugReportService = BugReportService()
    private var bugReportDialog: BugReportDialog?
    private let launchTime = Date()
    private var inputHeightConstraint: NSLayoutConstraint?
    private let inputMinHeight: CGFloat = 40
    private let inputMaxHeight: CGFloat = 120

    /// Coalesces multiple refreshAllTabs() calls into a single
    /// layout pass at the end of the current run loop cycle.
    private var refreshScheduled: Bool = false

    /// Coalesces saveState() calls — waits 1s after last request before writing.
    private var saveStateWorkItem: DispatchWorkItem?

    private let sidebarWidth: CGFloat = 220
    private let launcherHeight: CGFloat = 36

    init(channelManager: ChannelManager, configService: ConfigService) {
        self.channelManager = channelManager
        self.configService = configService

        // Create window
        let windowRect = NSRect(x: 100, y: 100, width: 1000, height: 700)
        self.window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Swap in ShapedContentView as the content view from the start.
        // With a nil sampler, `hitTest` delegates to `super.hitTest` and
        // behaves identically to a plain NSView — no behavior change
        // for non-shaped skins. Establishing the type here means the
        // view survives reconstructWindow's content-view migration
        // (Amplify Task 7) without having to re-parent subviews
        // against a different class.
        self.window.contentView = ShapedContentView(frame: NSRect(origin: .zero, size: windowRect.size))

        // Create input box
        self.inputContainer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 40))
        self.inputBox = InputBoxView(frame: inputContainer.contentView.bounds)
        inputContainer.documentView = inputBox
        inputContainer.setAccessibilityElement(false)
        inputBox.isVerticallyResizable = true
        inputBox.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        inputBox.textContainer?.widthTracksTextView = true

        // Load config and restore the internal sidebar's expanded/collapsed
        // state. `sidebarExpanded` is an INTERNAL-section field — it controls
        // the in-panel left nav, not the external chrome band. External
        // chrome bands (top/right/bottom/left decorative strips around the
        // whole window) are managed separately via ChromeRegionManager.
        let config = configService.load()
        self.sidebarExpanded = config.sidebarExpanded ?? true

        self.regionManager = ChromeRegionManager(configService: configService)
        self.densityModeManager = DensityModeManager(configService: configService)
        // Amplify Task 11.6 — wire the density manager into the
        // ambient sprite-rendering gate so `SkinContext.applyFill`
        // honors density `.minimal` without a per-call parameter.
        SkinContext.ambientDensityManager = self.densityModeManager
        self.skinContext = SkinContext.builtInDefaults(reactive: self.reactiveSnapshot)

        super.init()

        // Hand each migrated chrome view the current skin context so
        // their colors come from `SkinContext.currentState(for:)` rather
        // than hardcoded constants. SplitPaneView instances are created
        // inside SplitPaneManager; they get wired through that bridge
        // in `setupLayout` via `splitPaneManager.skinContext = ...`.
        tabBar.skinContext = skinContext
        sidebarView.skinContext = skinContext
        inputBox.skinContext = skinContext
        sessionLauncher.skinContext = skinContext
        splitPaneManager.skinContext = skinContext

        self.regionManager.delegate = self

        // Wire the skin engine's file-watcher delegate to self. The
        // launch-time reloadSkin below will call startWatching to begin
        // the actual FSEventStream; before that call the delegate is
        // still set so a racing file-watcher event can't fire into a
        // nil delegate.
        self.skinEngine.fileWatcherDelegate = self

        // Update density menu checkmarks whenever mode changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(densityModeDidChange(_:)),
            name: .densityModeDidChange,
            object: nil
        )

        // --shader launch argument overrides config (used by UI tests)
        let shaderPath: String?
        if let idx = CommandLine.arguments.firstIndex(of: "--shader"),
           idx + 1 < CommandLine.arguments.count {
            shaderPath = CommandLine.arguments[idx + 1]
        } else {
            shaderPath = config.appearance.customShaderPath
        }
        recompileShader(path: shaderPath)

        window.delegate = self
        window.title = "Holoscape"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false

        // If the user had a non-Default skin selected at last quit, load
        // it now so the chrome reflects the persisted choice. reloadSkin
        // internally calls applySkin → applyWindowSurfaces, so the window
        // background gets painted correctly in one pass. On failure
        // (missing skin dir, malformed JSON) we log and fall through to
        // the Default branch below; reloadSkin is intentionally
        // silent-on-error so a bad skin folder never prevents launch.
        if let persistedSkin = config.appearance.skinName, persistedSkin != "Default" {
            reloadSkin(named: persistedSkin)
        } else {
            // Default path: no skin surfaces to inject, so paint the
            // window chrome from built-in defaults directly.
            applyWindowSurfaces()
        }

        tabBar.tabDelegate = self
        sidebarView.sidebarDelegate = self
        sessionLauncher.launcherDelegate = self
        inputBox.inputDelegate = self
        splitPaneManager.splitDelegate = self

        setupLayout()
        setupKeyboardShortcuts()

        window.makeFirstResponder(inputBox)

        // Defer layout-dependent state application until after setupLayout.
        // Internal sidebar state restores via applySidebarState; external
        // chrome band state restores via regionManager.restoreState (which
        // drives the delegate to set constraint constants on each band).
        DispatchQueue.main.async { [self] in
            self.applySidebarState(animated: false)
            self.regionManager.restoreState()
        }

        // Refresh elapsed time on tabs every 60 seconds
        elapsedTimeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAllTabs() }
        }
    }

    deinit {
        elapsedTimeTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Set the notification service after initialization.
    func setNotificationService(_ service: NotificationService) {
        self.notificationService = service
    }

    /// Set the profile manager after services are initialized.
    func setProfileManager(_ manager: SessionProfileManager) {
        self.profileManager = manager
        refreshLauncher()
    }

    private func setupLayout() {
        guard let contentView = window.contentView else { return }

        // External chrome bands — four edge strips that surround the main
        // content. Added first so they live behind/beside the split view.
        // Default to zero size; a skin with `surfaces.top.background` etc.
        // will inflate them via the skin engine in a later task.
        for band in [topChromeBand, rightChromeBand, bottomChromeBand, leftChromeBand] {
            band.translatesAutoresizingMaskIntoConstraints = false
            band.wantsLayer = true
            contentView.addSubview(band)
        }

        // Configure split view (holds the three internal sections)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(splitView)

        // Sidebar container: launcher at top, tab list below
        sidebarContainer.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.wantsLayer = true
        sidebarContainer.layer?.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1.0).cgColor

        sessionLauncher.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(sessionLauncher)
        sidebarContainer.addSubview(sidebarView)

        NSLayoutConstraint.activate([
            sessionLauncher.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            sessionLauncher.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            sessionLauncher.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            sessionLauncher.heightAnchor.constraint(equalToConstant: launcherHeight),

            sidebarView.topAnchor.constraint(equalTo: sessionLauncher.bottomAnchor),
            sidebarView.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            sidebarView.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
        ])

        // Right pane: tab bar (hidden when sidebar expanded) + terminal + input
        let rightPane = NSView()
        rightPane.translatesAutoresizingMaskIntoConstraints = false
        rightPane.setAccessibilityElement(false)
        rightPane.setAccessibilityRole(.group)

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        splitPaneManager.translatesAutoresizingMaskIntoConstraints = false
        inputContainer.translatesAutoresizingMaskIntoConstraints = false

        // Tab bar lives in the title-bar strip (Warp-style). It sits directly
        // on contentView, spanning from just past the traffic-light buttons
        // to the right edge. Traffic-light zone is ~78pt; leaving 80 here.
        contentView.addSubview(tabBar)
        rightPane.addSubview(splitPaneManager)
        rightPane.addSubview(inputContainer)

        let tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 32)
        self.tabBarHeightConstraint = tabBarHeight

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 80),
            tabBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBarHeight,

            splitPaneManager.topAnchor.constraint(equalTo: rightPane.topAnchor),
            splitPaneManager.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            splitPaneManager.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            splitPaneManager.bottomAnchor.constraint(equalTo: inputContainer.topAnchor),

            inputContainer.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            inputContainer.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            inputContainer.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
        ])

        // Input box auto-grow: start at min height, grow up to max
        let ihc = inputContainer.heightAnchor.constraint(equalToConstant: inputMinHeight)
        ihc.isActive = true
        inputHeightConstraint = ihc

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inputTextDidChange(_:)),
            name: NSText.didChangeNotification,
            object: inputBox
        )

        // Add panes to split view
        splitView.addArrangedSubview(sidebarContainer)
        splitView.addArrangedSubview(rightPane)

        // External band sizing. Width/height constants default to zero so
        // the bands don't affect layout until a skin inflates them.
        let topH = topChromeBand.heightAnchor.constraint(equalToConstant: 0)
        let rightW = rightChromeBand.widthAnchor.constraint(equalToConstant: 0)
        let bottomH = bottomChromeBand.heightAnchor.constraint(equalToConstant: 0)
        let leftW = leftChromeBand.widthAnchor.constraint(equalToConstant: 0)
        topChromeBandHeight = topH
        rightChromeBandWidth = rightW
        bottomChromeBandHeight = bottomH
        leftChromeBandWidth = leftW

        NSLayoutConstraint.activate([
            // Top band pinned just below the tab bar
            topChromeBand.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            topChromeBand.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            topChromeBand.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            topH,

            // Bottom band pinned across the window bottom
            bottomChromeBand.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bottomChromeBand.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomChromeBand.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottomH,

            // Left band between the top and bottom bands, on the leading edge
            leftChromeBand.topAnchor.constraint(equalTo: topChromeBand.bottomAnchor),
            leftChromeBand.bottomAnchor.constraint(equalTo: bottomChromeBand.topAnchor),
            leftChromeBand.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            leftW,

            // Right band between the top and bottom bands, on the trailing edge
            rightChromeBand.topAnchor.constraint(equalTo: topChromeBand.bottomAnchor),
            rightChromeBand.bottomAnchor.constraint(equalTo: bottomChromeBand.topAnchor),
            rightChromeBand.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rightW,

            // Split view fills the interior between all four bands
            splitView.topAnchor.constraint(equalTo: topChromeBand.bottomAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomChromeBand.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: leftChromeBand.trailingAnchor),
            splitView.trailingAnchor.constraint(equalTo: rightChromeBand.leadingAnchor),
        ])

        // Set holding priorities
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)      // sidebar can shrink
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)     // terminal keeps space
    }

    private func setupKeyboardShortcuts() {
        let newItem = NSMenuItem(title: "New Session", action: #selector(handleNewSession), keyEquivalent: "n")
        newItem.target = self

        let newChannelItem = NSMenuItem(title: "New Channel", action: #selector(showChannelPicker), keyEquivalent: "")
        newChannelItem.target = self

        let closeItem = NSMenuItem(title: "Close Channel", action: #selector(closeActiveChannel), keyEquivalent: "w")
        closeItem.target = self

        let toggleSidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "s")
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .shift]
        toggleSidebarItem.target = self

        if let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu {
            fileMenu.addItem(newItem)
            fileMenu.addItem(newChannelItem)
            fileMenu.addItem(closeItem)
            fileMenu.addItem(NSMenuItem.separator())
            fileMenu.addItem(toggleSidebarItem)
        }

        // View menu: timestamp toggle + four chrome region toggles.
        // Building these here (not in AppDelegate) lets us set
        // `target = self` explicitly, which is consistent with every other
        // MainWindowController-owned menu item. Responder-chain dispatch
        // would otherwise silently fail to fire under certain focused-view
        // conditions (sheets, popovers, text field focus).
        if let viewMenu = NSApp.mainMenu?.item(withTitle: "View")?.submenu {
            let timestampItem = NSMenuItem(title: "Show Timestamps", action: #selector(toggleTimestamps), keyEquivalent: "t")
            timestampItem.target = self
            viewMenu.addItem(timestampItem)

            // Reader Mode — floating NSPanel with the active channel's
            // scrollback as plain text (ANSI stripped). ⌘⇧R rather than
            // ⌘R because ⌘R is too commonly "reload" in dev tools; the
            // shift modifier keeps the shortcut specific to Holoscape.
            let readerModeItem = NSMenuItem(
                title: "Reader Mode",
                action: #selector(toggleReaderMode),
                keyEquivalent: "r"
            )
            readerModeItem.keyEquivalentModifierMask = [.command, .shift]
            readerModeItem.target = self
            viewMenu.addItem(readerModeItem)

            viewMenu.addItem(NSMenuItem.separator())

            // External chrome region toggles. All four bands exist as
            // dedicated NSViews; their expanded size is zero until a skin
            // paints them. The toggle is a real state change — the user's
            // preference is persisted so when a skin loads, the skin engine
            // honors it (inflate if expanded, keep 0 if collapsed).
            let toggleTopItem = NSMenuItem(title: "Toggle Top Chrome", action: #selector(toggleTopChrome), keyEquivalent: "")
            toggleTopItem.target = self
            viewMenu.addItem(toggleTopItem)

            let toggleRightItem = NSMenuItem(title: "Toggle Right Chrome", action: #selector(toggleRightChrome), keyEquivalent: "")
            toggleRightItem.target = self
            viewMenu.addItem(toggleRightItem)

            let toggleBottomItem = NSMenuItem(title: "Toggle Bottom Chrome", action: #selector(toggleBottomChrome), keyEquivalent: "")
            toggleBottomItem.target = self
            viewMenu.addItem(toggleBottomItem)

            let toggleLeftItem = NSMenuItem(title: "Toggle Left Chrome", action: #selector(toggleLeftChrome), keyEquivalent: "")
            toggleLeftItem.target = self
            viewMenu.addItem(toggleLeftItem)

            viewMenu.addItem(NSMenuItem.separator())

            // Density mode picker — a submenu with three mutually-exclusive
            // items that show a checkmark on the active mode. Living in the
            // menu bar (not a settings window) so it's one click away, the
            // same way Settings itself is reachable.
            let densityMenuItem = NSMenuItem(title: "Density", action: nil, keyEquivalent: "")
            let densityMenu = NSMenu(title: "Density")

            let fullItem = NSMenuItem(title: "Full", action: #selector(setDensityFull), keyEquivalent: "")
            fullItem.target = self
            densityMenu.addItem(fullItem)
            densityFullMenuItem = fullItem

            let minimalItem = NSMenuItem(title: "Minimal", action: #selector(setDensityMinimal), keyEquivalent: "")
            minimalItem.target = self
            densityMenu.addItem(minimalItem)
            densityMinimalMenuItem = minimalItem

            let offItem = NSMenuItem(title: "Off", action: #selector(setDensityOff), keyEquivalent: "")
            offItem.target = self
            densityMenu.addItem(offItem)
            densityOffMenuItem = offItem

            densityMenuItem.submenu = densityMenu
            viewMenu.addItem(densityMenuItem)

            updateDensityMenuChecks(for: densityModeManager.mode)
        }

        // Cmd+1-9 channel switching via local event monitor
        setupChannelSwitchShortcuts()
    }

    nonisolated(unsafe) private var keyMonitor: Any?

    private func setupChannelSwitchShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command) else { return event }

            let hasShift = event.modifierFlags.contains(.shift)

            // Cmd+D → split horizontal, Cmd+Shift+D → split vertical
            if event.keyCode == 2 {  // 'd'
                if hasShift {
                    self.splitPaneManager.splitVertical()
                } else {
                    self.splitPaneManager.splitHorizontal()
                }
                return nil
            }

            // Cmd+Shift+W → close split pane (only when multiple panes)
            if event.keyCode == 13 && hasShift {
                if self.splitPaneManager.paneCount > 1 {
                    self.splitPaneManager.closeActivePane()
                }
                return nil  // consume even with 1 pane to prevent system handling
            }

            // Key codes 18-26 map to digits 1-9
            let digitKeyCodes: [UInt16: Int] = [
                18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
            ]
            guard let position = digitKeyCodes[event.keyCode] else { return event }
            let channels = self.channelManager.allChannels()
            if position <= channels.count {
                self.switchToChannel(channels[position - 1].channelId)
                return nil
            }
            return event
        }
    }

    @objc func toggleTimestamps() {
        var config = configService.load()
        let current = config.showTimestamps ?? false
        config.showTimestamps = !current
        configService.save(config)
    }

    /// View menu "Reader Mode" action (⌘⇧R). Toggles the floating
    /// reader panel for the active channel. Silently no-ops when no
    /// channel is active — the menu item stays available but a toggle
    /// with no channel just logs and returns.
    ///
    /// `animationEngine: nil` is intentional: the app's object graph
    /// does not currently own a shared AnimationEngine (backlog card to
    /// wire one alongside DensityModeManager). When nil, Reader Mode
    /// skips its chrome-animation suppression step; the dim already
    /// conveys "not in interactive mode."
    @objc func toggleReaderMode() {
        if readerModeController.isActive {
            readerModeController.dismiss()
            return
        }
        guard let id = activeChannelId,
              let channel = channelManager.channel(for: id) else {
            NSLog("MainWindowController: Reader Mode invoked with no active channel — ignoring")
            return
        }
        // Amplify Task 17.1 — inject the current skin context so
        // Reader Mode can theme its panel surfaces. Reassigned each
        // activation so skin switches mid-session pick up the change
        // on the next Reader Mode open (no need to toggle twice).
        readerModeController.skinContext = skinContext
        readerModeController.activate(
            for: channel,
            parentWindow: window,
            animationEngine: nil
        )
    }

    // MARK: - Internal sidebar (left nav)

    // MARK: - Skin injection and window surfaces (Task 9.7, 9.8)

    /// Resolve `window.background` + `window.titleBar` from the current
    /// skin context and apply them to the NSWindow. Called once at init
    /// and again whenever the skin context swaps. Fallback stays on the
    /// pre-skinning dark-purple background when the skin doesn't ship
    /// a `.color` fill for the `window.background` surface.
    ///
    /// `window.titleBar` is reserved for future styling (the title bar
    /// hosts the tab bar today — see Task 9.1 migration). A dedicated
    /// title-bar accessory view would honor this surface's fill; for
    /// now the tab bar's own `tabBar.container` surface covers the
    /// visible titlebar band, so this method only wires the window bg.
    private func applyWindowSurfaces() {
        window.backgroundColor = Self.resolveWindowBackground(from: skinContext)
    }

    /// Pure helper: map a `SkinContext` to the NSColor that should land
    /// on `NSWindow.backgroundColor`. Extracted as a static seam so a
    /// unit test can exercise the mapping without constructing a real
    /// `MainWindowController` (which needs a ChannelManager, a window,
    /// a config service).
    ///
    /// `NSWindow.backgroundColor` is a single NSColor slot — it can't
    /// natively carry a gradient or image. The main visible impact of
    /// this color is the 80pt traffic-lights gap at the top-left of the
    /// titlebar band (the rest of the window is covered by chrome views
    /// that paint their own fills). For gradient window skins we pick
    /// the FIRST gradient stop as the NSWindow color — that's what
    /// shows behind the traffic lights, which visually ties the
    /// titlebar gap to the adjacent tab bar's gradient. Image fills
    /// fall back to the built-in default (no good way to sample an
    /// image in NSWindow.backgroundColor).
    static func resolveWindowBackground(from context: SkinContext) -> NSColor {
        let defaultBg = NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0)
        let fill = context.currentState(for: .windowBackground).fill
        switch fill {
        case .color(let ns):
            return ns
        case .gradient(_, let stops):
            // Lowest-offset stop is the color visible in the traffic-lights
            // gap (top-of-gradient for a vertical direction). Sort by
            // offset rather than array order so a skin that lists stops
            // out of order still picks the correct end of the gradient.
            // CAGradientLayer itself uses the `locations` array to
            // position stops, so the gradient renders correctly in any
            // order; only this derived-single-color mapping needs the sort.
            if let topStop = stops.min(by: { $0.offset < $1.offset }),
               let color = NSColor(hex: topStop.color) {
                return color
            }
            return defaultBg
        case .image:
            NSLog("MainWindowController: image fill for 'window.background' not supported — NSWindow can't sample an image. Falling back.")
            return defaultBg
        }
    }

    /// Swap the active skin. Rebuilds the `SkinContext`, re-injects into
    /// every chrome view, and re-applies window surfaces.
    ///
    /// Passing `nil` resets to the built-in defaults (the "unload skin"
    /// path). Called by the skin loader in Task 11 hot reload; safe to
    /// invoke at any time after init.
    ///
    /// Why no `.skinDidChange` post here: the direct property
    /// assignments below already trigger each view's `didSet` →
    /// `refreshFromSkin()`. Posting the notification on top of that
    /// would fire the same repaint a second time on every subscriber.
    /// Callers that need to wake up observers outside this controller
    /// (future views added after this PR, or tests) can post
    /// `.skinDidChange` themselves after `applySkin` returns.
    func applySkin(_ surfaces: [SurfaceKey: SkinContext.ResolvedSurface]?) {
        applySkin(surfaces: surfaces, windowShape: nil, dragRegions: [])
    }

    /// Amplify Task 5.3 + 9.3 — extended entry point for skins that
    /// may carry `windowShape` and/or `dragRegions`. Existing callers
    /// that don't know about either keep using `applySkin(_:)`.
    /// `reloadSkin` calls this directly, passing `LoadedSkin.windowShape`
    /// + `.dragRegions`.
    ///
    /// Both shape and drag-region application is gated on the shaped-
    /// windows feature flag. When off, `windowShape` is ignored and
    /// `dragRegions` is ignored (moving a titled window uses the
    /// system title bar — no custom drag handles needed).
    func applySkin(
        surfaces: [SurfaceKey: SkinContext.ResolvedSurface]?,
        windowShape: ResolvedWindowShape?,
        dragRegions: [ResolvedDragRegion]
    ) {
        skinContext = Self.buildSkinContext(overriding: surfaces, reactive: reactiveSnapshot)
        tabBar.skinContext = skinContext
        sidebarView.skinContext = skinContext
        inputBox.skinContext = skinContext
        sessionLauncher.skinContext = skinContext
        splitPaneManager.skinContext = skinContext
        applyWindowSurfaces()
        applyWindowShape(windowShape)
        applyDragRegions(dragRegions, shapeActive: windowShape != nil)
    }

    /// Amplify Task 9.3 — install / replace the drag region tracker.
    /// Always tears down the previous tracker first so skin switches
    /// leave no stale tracking areas on the content view.
    ///
    /// Fallback per Requirement 4.6: when the window is borderless
    /// (shape active) AND no drag regions are declared, enable
    /// `isMovableByWindowBackground` so the whole content view acts
    /// as a drag handle. For titled windows we keep the default
    /// false — AppKit's title bar handles drag.
    private func applyDragRegions(
        _ regions: [ResolvedDragRegion],
        shapeActive: Bool
    ) {
        // Always drain the previous tracker. The guard below either
        // installs a new one or leaves the view tracker-less.
        currentDragRegionTracker?.teardown()
        currentDragRegionTracker = nil
        (window.contentView as? ShapedContentView)?.dragRegionTracker = nil

        guard shapedWindowController.featureFlagEnabled else {
            // Flag off — ignore drag regions entirely, rely on the
            // default titled window's title bar for dragging.
            window.isMovableByWindowBackground = false
            return
        }

        if regions.isEmpty {
            // Borderless + no regions → whole-window drag fallback
            // per Req 4.6. Rectangular windows default to false so
            // the titled window's system drag zone (title bar) is
            // the only drag target.
            window.isMovableByWindowBackground = shapeActive
            return
        }

        // Install a fresh tracker.
        window.isMovableByWindowBackground = false
        guard let shapedView = window.contentView as? ShapedContentView else {
            NSLog("MainWindowController: drag regions declared but content view is not ShapedContentView — dropping")
            return
        }
        let tracker = DragRegionTracker(contentView: shapedView, regions: regions)
        tracker.install()
        shapedView.dragRegionTracker = tracker
        currentDragRegionTracker = tracker
    }

    /// Transition the window to / from the requested shape. No-op when
    /// the feature flag is off (Req 2.8) or when the shape state is
    /// unchanged. On a changed shape:
    ///
    /// - nil → non-nil: reconstruct borderless, install mask
    /// - non-nil → non-nil: keep window, swap mask layer
    /// - non-nil → nil: reconstruct titled, remove mask
    ///
    /// Reduce Motion (Req 2.7) skips the fade-in on mask install;
    /// Reduce Transparency (Req 2.6) renders the mask complement as
    /// opaque system-gray rather than transparent — preserves the
    /// shape outline without the visual transparency effect.
    private func applyWindowShape(_ targetShape: ResolvedWindowShape?) {
        guard shapedWindowController.featureFlagEnabled else {
            // Flag off: zero shape work. If a shape somehow survived in
            // `currentWindowShape` (shouldn't happen — init reads the
            // flag once), clearing it here is the belt-and-suspenders.
            currentWindowShape = nil
            return
        }
        // No transition needed.
        if targetShape == currentWindowShape { return }

        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Reconstruction is needed when crossing the rectangular ↔
        // shaped boundary. Same-state shape changes (non-nil → non-nil
        // with different polygons) just swap the mask on the existing
        // window — no style-mask flip, no focus churn.
        let isRectangularNow = currentWindowShape == nil
        let shouldReconstruct = isRectangularNow != (targetShape == nil)
        if shouldReconstruct {
            guard let contentView = window.contentView else {
                // A window without a content view is only reachable in
                // teardown or future test harnesses. Bail before
                // force-unwrapping would crash; leave currentWindowShape
                // as-is so the next `applySkin` can retry.
                NSLog("MainWindowController: applyWindowShape skipped — window has no contentView")
                return
            }
            let oldWindow = window
            let result = shapedWindowController.reconstructWindow(
                currentWindow: oldWindow,
                contentView: contentView,
                targetShape: targetShape
            )
            window = result.newWindow
            window.delegate = self

            // Reduce-Transparency override: when RT is on, force the
            // shaped window opaque with a systemGray fill so the mask
            // complement renders gray instead of transparent. Outline
            // stays visible; visual transparency does not (Req 2.6).
            if targetShape != nil && reduceTransparency {
                window.isOpaque = true
                window.backgroundColor = .systemGray
            }

            // Close the old window AFTER the new one exists so AppKit
            // never has a window-less moment that would send the app
            // to background. Order the new window front to mirror the
            // old one's key state.
            oldWindow.close()
            if result.wasKey {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFront(nil)
            }
        }

        // Install (or clear) the mask layer AND the hit-region sampler.
        // Both are required for shaped windows to feel right — mask
        // makes the non-polygon regions visually invisible; sampler
        // makes clicks pass through those regions to windows behind.
        // Without the sampler, an invisible rectangle still eats clicks.
        if let shape = targetShape {
            guard let contentView = window.contentView else {
                NSLog("MainWindowController: cannot install shape mask — window has no contentView")
                currentWindowShape = targetShape
                return
            }
            contentView.wantsLayer = true
            let maskLayer = shapedWindowController.buildMaskLayer(
                for: shape,
                in: contentView.bounds
            )
            // Inject the sampler. Only ShapedContentView carries the
            // property; a plain NSView will silently drop through without
            // click-through — that's a graceful degradation, not a bug
            // (init always uses ShapedContentView, but tests may swap).
            if case .polygons(let polygons) = shape.kind,
               let shapedView = contentView as? ShapedContentView {
                shapedView.sampler = HitRegionSampler(polygons: polygons)
            }
            if reduceMotion {
                contentView.layer?.mask = maskLayer
            } else {
                // Mild fade-in on the mask's opacity. The mask itself is
                // a clip, so "opacity" here means the layer's alpha in
                // the compositor — visually a fade between "rectangle"
                // and "shape."
                maskLayer?.opacity = 0
                contentView.layer?.mask = maskLayer
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.2)
                maskLayer?.opacity = 1
                CATransaction.commit()
            }
        } else {
            window.contentView?.layer?.mask = nil
            // Clear sampler so any future skin cycle starts clean and
            // hitTest returns to pure super.hitTest behavior. Matches
            // the mask-clear invariant above.
            (window.contentView as? ShapedContentView)?.sampler = nil
        }

        currentWindowShape = targetShape
    }

    /// Atomic "load-and-apply a skin by name" path shared by the Appearance
    /// Settings picker, the launch-time persisted-skin load, and (Task 11)
    /// the FSEventStream hot-reload callback.
    ///
    /// On success: unregisters the previous font bundle, stores the new
    /// one, and calls `applySkin` with the v2 surfaces from the manifest
    /// (or nil for `"Default"`, which resets to built-in defaults).
    ///
    /// On failure: logs via NSLog and keeps the previous `SkinContext` and
    /// `SkinFontBundle` untouched — the UI stays on last-known-good state.
    /// This matches Task 11.2's "keep previous SkinContext active" rule
    /// and is the reason fonts are unregistered AFTER the new load
    /// succeeds rather than before.
    func reloadSkin(named name: String) {
        // Cancel any pending file-watcher debounce — user-driven skin
        // switches must win over a stale disk-change event from a
        // different skin directory.
        pendingReloadWorkItem?.cancel()
        pendingReloadWorkItem = nil

        do {
            let loaded = try skinEngine.loadComposite(named: name)
            // Drain previous fonts only after the new load committed —
            // preserves symmetric register/unregister pairing on the
            // happy path and leaves the old fonts alive on failure.
            skinEngine.unregisterFonts(currentFontBundle)
            currentFontBundle = loaded.fonts
            applySkin(
                surfaces: loaded.surfaces,
                windowShape: loaded.windowShape,
                dragRegions: loaded.dragRegions
            )
            if let reason = loaded.validationBannerReason {
                // Req 13.2 — surface the malformed-shape banner. For
                // now this is just logged; a visible banner view is
                // a later task.
                NSLog("MainWindowController: \(reason)")
            }
        } catch {
            NSLog("MainWindowController: reloadSkin('\(name)') failed: \(error) — keeping previous SkinContext")
        }

        // Re-point the file watcher at the new skin's directory. Runs
        // regardless of load success so even a failed-to-parse skin
        // gets watched — the author edits the broken file, the
        // debouncer fires, and reloadSkin runs again (hopefully with
        // a valid file this time). For Default, startWatching is a
        // no-op (nothing to watch).
        skinEngine.startWatching(skinName: name)
    }

    // MARK: - SkinEngineFileWatcherDelegate (Task 11)

    /// FSEventStream fired inside the active skin's directory. Schedule
    /// a debounced reload — coalesce the event cluster from a single
    /// save (editors commonly fire 3–5 events per write) into one
    /// `reloadSkin` call 200ms after the last event.
    ///
    /// Cancels any already-pending work item so the timer always
    /// restarts from the most recent event — standard debounce.
    /// Matches the `scheduleSaveState()` pattern elsewhere in this file.
    func skinEngineDidDetectChange(in directory: URL) {
        pendingReloadWorkItem?.cancel()
        let skinName = directory.lastPathComponent
        let item = DispatchWorkItem { [weak self] in
            self?.reloadSkin(named: skinName)
        }
        pendingReloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    /// Pure helper: build the SkinContext the controller should hold
    /// given an optional surfaces map. Extracted as a static seam so
    /// unit tests can verify the build-and-reset semantics without
    /// constructing a real controller.
    static func buildSkinContext(overriding surfaces: [SurfaceKey: SkinContext.ResolvedSurface]?,
                                 reactive: ReactiveUniformSnapshot) -> SkinContext {
        if let surfaces {
            return SkinContext(surfaces: surfaces, reactive: reactive)
        }
        return SkinContext.builtInDefaults(reactive: reactive)
    }

    /// Top tab bar visibility follows the inverse of the sidebar.
    ///
    /// The expanded sidebar already renders the channel/tab list, so a
    /// second tab strip across the titlebar would duplicate the same UI.
    /// When the sidebar is collapsed, the top strip becomes the only
    /// surface showing the tab list, so it appears.
    ///
    /// Pure mapping, extracted so `TopTabBarSidebarMutualExclusionTests`
    /// can pin this invariant without spinning up a real NSWindow.
    /// Card #6021.
    static func tabBarVisibility(forSidebarExpanded sidebarExpanded: Bool)
        -> (isHidden: Bool, height: CGFloat)
    {
        if sidebarExpanded {
            return (isHidden: true, height: 0)
        } else {
            return (isHidden: false, height: 32)
        }
    }

    /// Apply the internal sidebar's expanded/collapsed state. This is the
    /// in-panel left nav — NOT an external chrome band. The top tab strip
    /// (Warp-style) is mutually exclusive with the sidebar's own tab
    /// list: expanded sidebar → hide top strip; collapsed sidebar →
    /// show top strip. See `tabBarVisibility(forSidebarExpanded:)` for
    /// the pinned invariant.
    private func applySidebarState(animated: Bool) {
        let tabBarState = Self.tabBarVisibility(forSidebarExpanded: sidebarExpanded)
        let work = { [self] in
            if sidebarExpanded {
                splitView.setPosition(sidebarWidth, ofDividerAt: 0)
                sidebarContainer.isHidden = false
            } else {
                splitView.setPosition(0, ofDividerAt: 0)
                sidebarContainer.isHidden = true
            }
            tabBar.isHidden = tabBarState.isHidden
            tabBarHeightConstraint?.constant = tabBarState.height
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                work()
            }
        } else {
            work()
        }
        refreshAllTabsNow()
    }

    @objc func toggleSidebar() {
        sidebarExpanded.toggle()
        applySidebarState(animated: true)

        var config = configService.load()
        config.sidebarExpanded = sidebarExpanded
        configService.save(config)
    }

    // MARK: - External chrome bands (ChromeRegionManagerDelegate)

    /// Toggles one of the four external decorative chrome bands by
    /// modulating its size constraint. When expanded, the band shows at
    /// `externalBandDefaultExpandedSize` (zero today — the skin engine
    /// will inflate bands at skin-apply time in a later task). When
    /// collapsed, the size goes to zero unconditionally.
    func regionManager(
        _ manager: ChromeRegionManager,
        setRegion region: ChromeRegionManager.Region,
        collapsed: Bool,
        animated: Bool
    ) {
        let target: CGFloat = collapsed ? 0 : externalBandDefaultExpandedSize
        // setupLayout assigns all four constraints unconditionally; a nil
        // here means the delegate fired before layout ran, which is a
        // programming error we want to surface, not swallow.
        let constraint: NSLayoutConstraint
        switch region {
        case .top:
            guard let c = topChromeBandHeight else { preconditionFailure("topChromeBandHeight not set — delegate fired before setupLayout") }
            constraint = c
        case .right:
            guard let c = rightChromeBandWidth else { preconditionFailure("rightChromeBandWidth not set — delegate fired before setupLayout") }
            constraint = c
        case .bottom:
            guard let c = bottomChromeBandHeight else { preconditionFailure("bottomChromeBandHeight not set — delegate fired before setupLayout") }
            constraint = c
        case .left:
            guard let c = leftChromeBandWidth else { preconditionFailure("leftChromeBandWidth not set — delegate fired before setupLayout") }
            constraint = c
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                constraint.animator().constant = target
            }
        } else {
            constraint.constant = target
        }
    }

    @objc func toggleTopChrome() {
        regionManager.toggleRegion(.top)
    }

    @objc func toggleRightChrome() {
        regionManager.toggleRegion(.right)
    }

    @objc func toggleBottomChrome() {
        regionManager.toggleRegion(.bottom)
    }

    @objc func toggleLeftChrome() {
        regionManager.toggleRegion(.left)
    }

    // MARK: - Density mode menu

    @objc func setDensityFull() {
        densityModeManager.setMode(.full)
    }

    @objc func setDensityMinimal() {
        densityModeManager.setMode(.minimal)
    }

    @objc func setDensityOff() {
        densityModeManager.setMode(.off)
    }

    @objc private func densityModeDidChange(_ notification: Notification) {
        guard
            let rawValue = notification.userInfo?["current"] as? String,
            let mode = DensityModeManager.Mode(rawValue: rawValue)
        else {
            // Malformed notification — log so the desync between menu
            // checkmarks and actual mode is visible rather than silent.
            NSLog("MainWindowController: .densityModeDidChange received with malformed userInfo: \(String(describing: notification.userInfo))")
            return
        }
        updateDensityMenuChecks(for: mode)
    }

    private func updateDensityMenuChecks(for mode: DensityModeManager.Mode) {
        densityFullMenuItem?.state = (mode == .full) ? .on : .off
        densityMinimalMenuItem?.state = (mode == .minimal) ? .on : .off
        densityOffMenuItem?.state = (mode == .off) ? .on : .off
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        if let id = activeChannelId,
           let channel = channelManager.channel(for: id),
           ptyChannelTypes.contains(channel.channelType) {
            window.makeFirstResponder(channel.contentView)
        } else {
            window.makeFirstResponder(inputBox)
        }
    }

    // MARK: - NSSplitViewDelegate

    nonisolated func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        // Allow the sidebar (first subview at index 0) to collapse
        return splitView.subviews.first === subview
    }

    nonisolated func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 0  // allow full collapse; canCollapseSubview handles the rest
    }

    nonisolated func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 350  // maximum sidebar width
    }

    nonisolated func splitView(_ splitView: NSSplitView, shouldCollapseSubview subview: NSView, forDoubleClickOnDividerAt dividerIndex: Int) -> Bool {
        return splitView.subviews.first === subview
    }

    // MARK: - URL Scheme

    func openChannel(type: String, directory: String?, label: String?, command: String? = nil) {
        let dir = directory.map { URL(fileURLWithPath: $0) }

        switch type {
        case "shell":
            let dirName = dir?.lastPathComponent
            let effectiveLabel = label ?? dirName
            let channel = channelManager.createChannel(
                type: .shell,
                role: effectiveLabel ?? "Shell",
                workingDirectory: dir
            ) { id, _, _, instanceNum, workDir in
                ShellChannelController(id: id, instanceNumber: instanceNum, label: effectiveLabel, workingDirectory: workDir?.path)
            }
            channel.delegate = self
            channel.activate()
            if let cmd = command {
                // Small delay to let shell initialize before sending command
                let channelRef = channel
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    // Append a newline if missing so the command actually executes
                    // rather than being typed-but-not-submitted (affects URL scheme
                    // cmd= parameter and any other caller passing a raw command).
                    channelRef.sendInput(cmd.hasSuffix("\n") ? cmd : cmd + "\n")
                }
            }
            switchToChannel(channel.channelId)

        case "agent":
            let channel = channelManager.createChannel(
                type: .agentDirect,
                role: label,
                workingDirectory: dir ?? URL(fileURLWithPath: NSHomeDirectory())
            ) { id, _, _, instanceNum, workDir in
                AgentChannelController(
                    id: id,
                    authType: .oauth,
                    workingDirectory: workDir,
                    userLabel: label,
                    instanceNumber: instanceNum
                )
            }
            channel.delegate = self
            channel.activate()
            switchToChannel(channel.channelId)

        default:
            NSLog("Holoscape openChannel: unknown type '\(type)'")
        }
    }

    // MARK: - Channel Operations

    private let ptyChannelTypes: Set<ChannelType> = [.shell, .agentDirect, .agentAPI, .ssh]

    func switchToChannel(_ id: UUID) {
        guard let channel = channelManager.channel(for: id) else { return }
        let previousLabel = activeChannelId.flatMap { channelManager.channel(for: $0)?.displayLabel }
        activeChannelId = id
        channel.hasUnread = false
        apiServer?.clearNotification(for: id)
        splitPaneManager.showContent(channel.contentView, channelId: id, compiledShader: cachedShader)
        refreshAllTabs()
        historyBuffer.recordChannelSwitch(from: previousLabel, to: channel.displayLabel)

        // PTY channels handle their own input — hide InputBox and focus the terminal
        if ptyChannelTypes.contains(channel.channelType) {
            inputContainer.isHidden = true
            inputHeightConstraint?.constant = 0
            window.makeFirstResponder(channel.contentView)
        } else {
            inputContainer.isHidden = false
            inputHeightConstraint?.constant = inputMinHeight
            window.makeFirstResponder(inputBox)
        }
    }

    /// Schedule a tab refresh for the end of the current run loop cycle.
    /// Multiple calls within the same cycle are coalesced into one.
    func scheduleRefreshAllTabs() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshAllTabsNow()
        }
    }

    /// Debounce saveState() — waits 1s after the last call before writing to disk.
    private func scheduleSaveState() {
        // Skip state persistence during UI testing to prevent cross-test pollution
        if CommandLine.arguments.contains("--ui-testing") &&
           !CommandLine.arguments.contains("--restore-channels") {
            return
        }
        saveStateWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.channelManager.saveState()
        }
        saveStateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    /// Immediately refresh all tabs (use sparingly — prefer scheduleRefreshAllTabs).
    func refreshAllTabs() {
        refreshAllTabsNow()
    }

    private func refreshAllTabsNow() {
        let channels = channelManager.allChannels()
        // Sort: pinned first (by pinnedAt), then unpinned
        let pinned = channels.filter { channelManager.pinnedChannelIds.contains($0.channelId) }
            .sorted { (channelManager.pinnedTimestamps[$0.channelId] ?? .distantPast) < (channelManager.pinnedTimestamps[$1.channelId] ?? .distantPast) }
        let unpinned = channels.filter { !channelManager.pinnedChannelIds.contains($0.channelId) }
        let sorted = pinned + unpinned

        let notifications = apiServer?.channelNotifications ?? [:]
        tabBar.updateTabs(channels: sorted, activeId: activeChannelId, pinnedIds: channelManager.pinnedChannelIds, notifications: notifications)
        sidebarView.updateTabs(channels: sorted, activeId: activeChannelId, pinnedIds: channelManager.pinnedChannelIds, notifications: notifications)
    }

    func refreshLauncher() {
        guard let profileManager else { return }
        let (preconfigured, discovered, recent) = profileManager.allSessions()
        sessionLauncher.updateItems(preconfigured: preconfigured, discovered: discovered, recent: recent)
    }

    @objc func handleNewSession() {
        if sidebarExpanded {
            sessionLauncher.focus()
        } else {
            showChannelPicker()
        }
    }

    @objc func showChannelPicker() {
        let alert = NSAlert()
        alert.messageText = "New Channel"
        alert.informativeText = "Select channel type:"
        alert.addButton(withTitle: "Shell")
        alert.addButton(withTitle: "Agent (OAuth)")
        alert.addButton(withTitle: "Agent (API Key)")
        alert.addButton(withTitle: "Group Chat")
        alert.addButton(withTitle: "Bridge")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:                      // 1000 — Shell
            createShellChannel()
        case .alertSecondButtonReturn:                     // 1001 — Agent (OAuth)
            createAgentChannel(authType: .oauth)
        case .alertThirdButtonReturn:                      // 1002 — Agent (API Key)
            createAgentChannel(authType: .apiKey(""))
        case NSApplication.ModalResponse(rawValue: 1003):  // Group Chat
            createGroupChatChannel()
        case NSApplication.ModalResponse(rawValue: 1004):  // Bridge
            createBridgeChannel()
        default:
            break
        }
    }

    private func createShellChannel() {
        let channel = channelManager.createChannel(
            type: .shell,
            role: "Shell",
            workingDirectory: nil
        ) { id, _, _, instanceNum, _ in
            return ShellChannelController(id: id, instanceNumber: instanceNum)
        }
        channel.delegate = self
        channel.activate()
        switchToChannel(channel.channelId)
    }

    private func createAgentChannel(authType: AgentAuthType) {
        let projectsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("projects")
        let defaultDir = FileManager.default.fileExists(atPath: projectsDir.path)
            ? projectsDir
            : URL(fileURLWithPath: NSHomeDirectory())
        let channel = channelManager.createChannel(
            type: { switch authType { case .oauth: return ChannelType.agentDirect; case .apiKey: return ChannelType.agentAPI } }(),
            role: nil,
            workingDirectory: defaultDir
        ) { id, type, _, instanceNum, workDir in
            AgentChannelController(
                id: id,
                authType: authType,
                workingDirectory: workDir,
                userLabel: nil,
                instanceNumber: instanceNum
            )
        }
        channel.delegate = self
        channel.activate()
        switchToChannel(channel.channelId)
    }

    private func createGroupChatChannel() {
        let envPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/agent-chat.env")
        var apiURL = ""
        var apiKey = ""
        if let content = try? String(contentsOf: envPath, encoding: .utf8) {
            for line in content.components(separatedBy: "\n") {
                if line.hasPrefix("AGENT_CHAT_URL=") {
                    apiURL = String(line.dropFirst("AGENT_CHAT_URL=".count))
                } else if line.hasPrefix("AGENT_CHAT_API_KEY=") {
                    apiKey = String(line.dropFirst("AGENT_CHAT_API_KEY=".count))
                }
            }
        }

        guard !apiURL.isEmpty, !apiKey.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Chat Not Configured"
            alert.informativeText = "~/.claude/agent-chat.env not found or missing AGENT_CHAT_URL/AGENT_CHAT_API_KEY"
            alert.runModal()
            return
        }

        let channel = channelManager.createChannel(
            type: .groupChat,
            role: "Chat",
            workingDirectory: nil
        ) { id, _, _, _, _ in
            GroupChatChannelController(id: id, apiURL: apiURL, apiKey: apiKey)
        }
        channel.delegate = self
        channel.activate()
        switchToChannel(channel.channelId)
    }

    private func createBridgeChannel() {
        let cm = channelManager
        let channel = channelManager.createChannel(
            type: .bridge,
            role: "Bridge",
            workingDirectory: nil
        ) { id, _, _, instanceNum, _ in
            BridgeChannelController(id: id, channelManager: cm, instanceNumber: instanceNum)
        }
        channel.delegate = self
        channel.activate()
        switchToChannel(channel.channelId)
    }

    private func launchSession(from profile: SessionProfile) {
        let resolved = profile.resolved(with: configService.load().sshDefaults)
        let channel = channelManager.createChannel(from: resolved)
        channel.delegate = self
        channel.activate()
        profileManager?.recordRecentSession(label: profile.label)
        refreshLauncher()
        switchToChannel(channel.channelId)
    }

    @objc func closeActiveChannel() {
        guard let id = activeChannelId,
              let channel = channelManager.channel(for: id) else { return }

        // Show confirmation for active channels
        if channel.state == .active {
            let alert = NSAlert()
            alert.messageText = "Close Channel"
            alert.informativeText = "The channel \"\(channel.displayLabel)\" is still active. Are you sure you want to close it?"
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
        }

        closeChannel(id: id)
    }

    func closeChannel(id: UUID) {
        channelManager.closeChannel(id: id)

        splitPaneManager.removeChannel(channelId: id)
        if activeChannelId == id {
            activeChannelId = nil
            if let first = channelManager.allChannels().first {
                switchToChannel(first.channelId)
                // switchToChannel already called refreshAllTabs + scheduleSaveState
                return
            }
            // Last channel was closed — create a fresh shell so the window isn't empty
            let channel = channelManager.createChannel(
                type: .shell,
                role: "Shell",
                workingDirectory: nil
            ) { id, _, _, instanceNum, _ in
                ShellChannelController(id: id, instanceNumber: instanceNum, workingDirectory: nil)
            }
            channel.delegate = self
            channel.activate()
            switchToChannel(channel.channelId)
            return
        }
        refreshAllTabs()
        scheduleSaveState()
    }

    // MARK: - Context Menu

    func buildContextMenu(for channelId: UUID) -> NSMenu? {
        guard let channel = channelManager.channel(for: channelId) else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let closeItem = NSMenuItem(title: "Close", action: #selector(contextMenuClose(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.representedObject = channelId
        menu.addItem(closeItem)

        let renameItem = NSMenuItem(title: "Rename", action: #selector(contextMenuRename(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = channelId
        menu.addItem(renameItem)

        let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(contextMenuDuplicate(_:)), keyEquivalent: "")
        duplicateItem.target = self
        duplicateItem.representedObject = channelId
        menu.addItem(duplicateItem)

        menu.addItem(NSMenuItem.separator())

        let reconnectItem = NSMenuItem(title: "Reconnect", action: #selector(contextMenuReconnect(_:)), keyEquivalent: "")
        reconnectItem.target = self
        reconnectItem.representedObject = channelId
        reconnectItem.isEnabled = channel.state == .disconnected
        menu.addItem(reconnectItem)

        menu.addItem(NSMenuItem.separator())

        // Pin/Unpin
        let isPinned = channelManager.pinnedChannelIds.contains(channelId)
        let pinTitle = isPinned ? "Unpin" : "Pin"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(contextMenuTogglePin(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.representedObject = channelId
        menu.addItem(pinItem)

        menu.addItem(NSMenuItem.separator())

        let copyInfoItem = NSMenuItem(title: "Copy Session Info", action: #selector(contextMenuCopyInfo(_:)), keyEquivalent: "")
        copyInfoItem.target = self
        copyInfoItem.representedObject = channelId
        menu.addItem(copyInfoItem)

        return menu
    }

    @objc private func contextMenuClose(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let channel = channelManager.channel(for: id) else { return }

        if channel.state == .active {
            let alert = NSAlert()
            alert.messageText = "Close Channel"
            alert.informativeText = "The channel \"\(channel.displayLabel)\" is still active. Are you sure you want to close it?"
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
        }

        closeChannel(id: id)
    }

    @objc private func contextMenuRename(_ sender: NSMenuItem) {
        // TODO: Implement inline rename
    }

    @objc private func contextMenuDuplicate(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let channel = channelManager.channel(for: id) else { return }

        if let profileManager, let label = channelManager.labelForChannel(id: id) {
            let profile = profileManager.resolve(label: label)
            launchSession(from: profile)
        } else {
            // Fallback: duplicate by channel type without a profile
            switch channel.channelType {
            case .shell:
                createShellChannel()
            case .agentDirect:
                createAgentChannel(authType: .oauth)
            case .agentAPI:
                createAgentChannel(authType: .apiKey(""))
            case .bridge:
                createBridgeChannel()
            case .groupChat:
                createGroupChatChannel()
            default:
                createShellChannel()
            }
        }
    }

    @objc private func contextMenuReconnect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let channel = channelManager.channel(for: id) else { return }
        channel.retry()
    }

    @objc private func contextMenuTogglePin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        channelManager.togglePin(id: id)
        refreshAllTabs()
        scheduleSaveState()
    }

    @objc private func contextMenuCopyInfo(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let channel = channelManager.channel(for: id) else { return }

        var info = "Label: \(channel.displayLabel)\nType: \(channel.channelType.rawValue)"
        if let sshChannel = channel as? SSHChannelController {
            info += "\nHost: \(sshChannel.profile.host ?? "N/A")"
            info += "\nUser: \(sshChannel.profile.user ?? "N/A")"
            info += "\nDirectory: \(sshChannel.profile.directory)"
            info += "\nCommand: \(sshChannel.profile.command)"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
    }

    // MARK: - TabBarViewDelegate

    func tabBarView(_ tabBar: TabBarView, didSelectChannelWithId id: UUID) {
        switchToChannel(id)
    }

    // MARK: - SidebarViewDelegate

    func sidebarView(_ sidebar: SidebarView, didSelectChannelWithId id: UUID) {
        switchToChannel(id)
    }

    func sidebarView(_ sidebar: SidebarView, contextMenuForChannelWithId id: UUID) -> NSMenu? {
        return buildContextMenu(for: id)
    }

    // MARK: - SessionLauncherDelegate

    func sessionLauncher(_ launcher: SessionLauncherView, didSelectProfile label: String) {
        guard let profileManager else { return }
        let profile = profileManager.resolve(label: label)
        launchSession(from: profile)
        window.makeFirstResponder(inputBox)
    }

    func sessionLauncher(_ launcher: SessionLauncherView, didTypeNewName name: String) {
        guard let profileManager else { return }
        let profile = profileManager.resolve(label: name)
        launchSession(from: profile)
        window.makeFirstResponder(inputBox)
    }

    func sessionLauncherDidRequestRefresh(_ launcher: SessionLauncherView) {
        Task {
            if let profileManager {
                let discoveryService = ProjectDiscoveryService(configService: configService)
                _ = await discoveryService.refresh()
                refreshLauncher()
            }
        }
    }

    // MARK: - InputBoxViewDelegate

    func inputBoxView(_ inputBox: InputBoxView, didSubmitText text: String) {
        guard let id = activeChannelId,
              let channel = channelManager.channel(for: id) else { return }
        channel.sendInput(text)
        historyBuffer.recordCommand(text, channelName: channel.displayLabel)
        resizeInputBox()
        window.makeFirstResponder(inputBox)
    }

    @objc private func inputTextDidChange(_ notification: Notification) {
        resizeInputBox()
    }

    private func resizeInputBox() {
        guard let layoutManager = inputBox.layoutManager,
              let textContainer = inputBox.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let padding: CGFloat = 12  // top + bottom inset
        let newHeight = min(max(usedHeight + padding, inputMinHeight), inputMaxHeight)
        inputHeightConstraint?.constant = newHeight
    }

    func inputBoxViewDidRequestPreviousHistory(_ inputBox: InputBoxView) {
        guard let id = activeChannelId,
              let channel = channelManager.channel(for: id),
              let prev = channel.commandHistory.previous() else { return }
        inputBox.setHistoryText(prev)
    }

    func inputBoxViewDidRequestNextHistory(_ inputBox: InputBoxView) {
        guard let id = activeChannelId,
              let channel = channelManager.channel(for: id) else { return }
        if let next = channel.commandHistory.next() {
            inputBox.setHistoryText(next)
        } else {
            inputBox.string = ""
        }
    }

    // MARK: - ChannelControllerDelegate

    func channelDidReceiveOutput(_ channel: any ChannelController) {
        if channel.channelId != self.activeChannelId {
            channel.hasUnread = true
            // Tabs stay in place — no reordering on output
            scheduleRefreshAllTabs()

            // Send desktop notification (use displayLabel instead of extracting full buffer)
            notificationService?.notifyIfNeeded(channel: channel, firstLine: channel.displayLabel)
        }
    }

    func channelStateDidChange(_ channel: any ChannelController, to state: ChannelState) {
        scheduleRefreshAllTabs()
        scheduleSaveState()
    }

    // MARK: - SplitPaneManagerDelegate

    func splitPaneManager(_ manager: SplitPaneManager, activePaneDidChange channelId: UUID?) {
        if let channelId {
            activeChannelId = channelId
            scheduleRefreshAllTabs()
        }
    }

    func recordAppearanceChange(_ settings: AppearanceConfig) {
        let config = configService.load()
        let old = config.appearance
        if old.themeName != settings.themeName {
            historyBuffer.recordSettingsChange(setting: "theme", oldValue: old.themeName ?? "Dark", newValue: settings.themeName ?? "Dark")
        }
        if old.fontFamily != settings.fontFamily {
            historyBuffer.recordSettingsChange(setting: "fontFamily", oldValue: old.fontFamily, newValue: settings.fontFamily)
        }
        if old.fontSize != settings.fontSize {
            historyBuffer.recordSettingsChange(setting: "fontSize", oldValue: "\(old.fontSize)", newValue: "\(settings.fontSize)")
        }
        if old.transparency != settings.transparency {
            historyBuffer.recordSettingsChange(setting: "transparency", oldValue: "\(old.transparency)", newValue: "\(settings.transparency)")
        }
        if old.skinName != settings.skinName {
            historyBuffer.recordSettingsChange(setting: "skin", oldValue: old.skinName ?? "Default", newValue: settings.skinName ?? "Default")
        }
        if old.customShaderPath != settings.customShaderPath {
            historyBuffer.recordSettingsChange(setting: "shader", oldValue: old.customShaderPath ?? "None", newValue: settings.customShaderPath ?? "None")
            recompileShader(path: settings.customShaderPath)
        }
    }

    private func shaderLog(_ msg: String) {
        let line = "\(Date()): \(msg)\n"
        let logPath = "/tmp/holoscape-shader.log"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
        }
    }

    private func recompileShader(path: String?) {
        shaderLog("recompileShader called with path: \(path ?? "nil")")
        guard let shaderPath = path else {
            shaderLog(" path is nil, clearing cachedShader")
            cachedShader = nil
            if let id = activeChannelId { switchToChannel(id) }
            return
        }
        let url: URL
        if shaderPath.hasPrefix("/") || shaderPath.hasPrefix("~") {
            url = URL(fileURLWithPath: (shaderPath as NSString).expandingTildeInPath)
            shaderLog(" resolved as absolute path: \(url.path)")
        } else if let bundled = Bundle.module.url(
            forResource: (shaderPath as NSString).lastPathComponent.replacingOccurrences(of: ".glsl", with: ""),
            withExtension: "glsl"
        ) {
            url = bundled
            shaderLog(" resolved from bundle: \(url.path)")
        } else {
            url = URL(fileURLWithPath: shaderPath)
            shaderLog(" WARNING: fallback to relative path: \(url.path)")
        }
        do {
            cachedShader = try ShaderCompiler().compile(glslPath: url)
            shaderLog(" compilation SUCCESS, MSL length: \(cachedShader!.mslSource.count) chars")
        } catch {
            shaderLog(" compilation FAILED: \(error)")
            cachedShader = nil
        }
        // Re-show current channel with new (or no) compositor
        if let id = activeChannelId { switchToChannel(id) }
    }

    // MARK: - Bug Report

    func showBugReportDialog() {
        guard let activeId = activeChannelId,
              let activeChannel = channelManager.channel(for: activeId) else { return }

        let allChannels = channelManager.allChannels()
        let channelStates = allChannels.map {
            ChannelStateInfo(
                channelName: $0.displayLabel,
                channelType: $0.channelType,
                state: "\($0.state)"
            )
        }

        let config = configService.load()
        let appearanceSummary = "Theme: \(config.appearance.themeName ?? "Dark"), Font: \(config.appearance.fontFamily) \(config.appearance.fontSize)pt, Transparency: \(config.appearance.transparency)"

        let context = BugReportDialog.Context(
            activeChannelName: activeChannel.displayLabel,
            activeChannelType: activeChannel.channelType.rawValue,
            allChannelStates: channelStates,
            lastOutputLines: activeChannel.lastLines(50),
            appearanceConfig: appearanceSummary,
            splitLayout: config.splitLayout.map { "\($0)" },
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: Self.hardwareModel(),
            uptime: Date().timeIntervalSince(launchTime)
        )

        let dialog = BugReportDialog()
        dialog.delegate = self
        dialog.show(in: window, context: context)
        bugReportDialog = dialog
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: - BugReportDialogDelegate

extension MainWindowController: BugReportDialogDelegate {
    func bugReportDialog(_ dialog: BugReportDialog, didSubmitDescription description: String, screenshot: Data?) {
        guard let activeId = activeChannelId,
              let activeChannel = channelManager.channel(for: activeId) else { return }

        let allChannels = channelManager.allChannels()
        let channelStates = allChannels.map {
            ChannelStateInfo(
                channelName: $0.displayLabel,
                channelType: $0.channelType,
                state: "\($0.state)"
            )
        }

        let config = configService.load()
        let appearanceSummary = "Theme: \(config.appearance.themeName ?? "Dark"), Font: \(config.appearance.fontFamily) \(config.appearance.fontSize)pt"

        let report = BugReport(
            channelName: activeChannel.displayLabel,
            channelType: activeChannel.channelType,
            lastOutputLines: activeChannel.lastLines(100),
            timestamp: Date(),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            description: description,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            hardwareModel: Self.hardwareModel(),
            allChannelStates: channelStates,
            appearanceConfig: appearanceSummary,
            splitLayout: config.splitLayout.map { "\($0)" },
            uptime: Date().timeIntervalSince(launchTime),
            historyBuffer: historyBuffer.snapshot(),
            screenshotData: screenshot
        )

        let service = bugReportService
        Task {
            do {
                let response = try await service.submitBugReport(report)
                await MainActor.run {
                    if response.success {
                        self.showSubmitConfirmation(success: true, message: response.message)
                    } else {
                        service.savePendingBugReport(report)
                        self.showSubmitConfirmation(success: false, message: response.message)
                    }
                }
            } catch {
                service.savePendingBugReport(report)
                await MainActor.run {
                    self.showSubmitConfirmation(success: false, message: "Network error — report saved locally for retry.")
                }
            }
        }

        bugReportDialog = nil
    }

    private func showSubmitConfirmation(success: Bool, message: String?) {
        let alert = NSAlert()
        if success {
            alert.messageText = "Report Submitted"
            alert.informativeText = message ?? "Thank you! Your bug report has been submitted."
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Submission Issue"
            alert.informativeText = message ?? "Report saved locally and will be retried on next launch."
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
    }
}
