import AppKit
import Combine
import PRBarCore
import SwiftUI

/// PRBar's icon in the menu bar and the panel it opens (the "popover").
///
/// It's an `NSStatusItem` and an `NSPanel` of our own instead of SwiftUI's `MenuBarExtra(.window)`, which decides the
/// panel's position, level and Spaces by itself: with the menu bar hidden (the "Automatically hide and show the menu
/// bar" setting, and every full-screen Space) its panel stayed where the menu bar had been, jumped when its content
/// changed size, and couldn't show over a full-screen app. Here the panel:
/// - shows over any Space, full-screen apps included, at the level of a menu, without activating PRBar;
/// - pins its top edge under the menu bar when it opens and keeps it on every resize, and is never taller than the
///   screen's visible area (`StatusPanelLayout`);
/// - closes on a click outside it, on Esc, when another app becomes active, on a Space or display change, and when the
///   icon moves to another screen;
/// - handles ↑/↓/Return on the PR rows (`PopoverRowSelection`).
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let panel: StatusPanel
    private let panelState = PopoverPanelState()
    private var hostingView: NSHostingView<PopoverPanelContent>?

    /// Fixed when the panel opens (see `StatusPanelLayout`).
    private var top: CGFloat = 0
    private var anchorX: CGFloat = 0
    private var buttonFrame: CGRect = .zero
    private var visibleFrame: CGRect = .zero
    private var contentSize: CGSize = .zero

    private var eventMonitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var badgeObserver: AnyCancellable?
    private var updateObserver: AnyCancellable?
    private let updateDot = UpdateDotView()

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = StatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: Theme.popoverWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true
        )
        super.init()
        configurePanel()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            updateDot.frame = button.bounds
            button.addSubview(updateDot)
        }
        updateButton(model.prStore.snapshot)
        badgeObserver = model.prStore.$snapshot.sink { [weak self] snapshot in self?.updateButton(snapshot) }
        // `objectWillChange` fires before the change: read the new state on the next turn of the run loop.
        updateObserver = model.updates.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.updateButton(self.model.prStore.snapshot)
        }
    }

    var isShown: Bool { panel.isVisible }

    /// `prbar app popover`: opens the panel (or brings it to the front if it's already open). `false` if it couldn't
    /// be shown (the icon isn't in the menu bar, e.g. hidden behind the notch).
    func show() -> Bool {
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return true
        }
        return open()
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        removeMonitors()
        model.popoverRows.reset()
        model.popoverVisibilityChanged(false)
    }

    // MARK: Icon

    private func updateButton(_ snapshot: Snapshot?) {
        guard let button = statusItem.button else { return }
        let state = Self.iconState(snapshot)
        let prompt = UpdatePrompt(availableVersion: model.updates.available?.version.description,
                                  isInstalling: model.updates.isInstalling)
        let image = BadgeIcon.image(for: state, updateDot: prompt != nil)
        button.image = image
        updateDot.dot = prompt == nil ? nil : (BadgeIcon.updateDotRect(imageSize: image.size), image.size)
        button.setAccessibilityLabel(UpdatePrompt.statusItemAccessibilityLabel(state: Self.accessibilityState(snapshot),
                                                                               prompt: prompt))
        button.toolTip = prompt?.help ?? "PRBar"
    }

    static func iconState(_ snapshot: Snapshot?) -> MenuBarIconState {
        guard let snapshot else { return .idle }
        if snapshot.failedCompletely { return .error }
        return .count(snapshot.badgeCount)
    }

    static func accessibilityState(_ snapshot: Snapshot?) -> String {
        guard let snapshot else { return "loading" }
        if snapshot.failedCompletely { return "offline" }
        return snapshot.badgeCount == 1 ? "1 PR needs your action" : "\(snapshot.badgeCount) PRs need your action"
    }

    @objc private func togglePanel(_ sender: Any?) {
        if panel.isVisible { close() } else { _ = open() }
    }

    // MARK: Panel

    private func configurePanel() {
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.title = "PRBar"
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Theme.Radius.popover)
        panel.contentView = background
    }

    /// The SwiftUI content is made the first time the panel opens (the model is ready by then).
    private func makeHostingViewIfNeeded() -> NSHostingView<PopoverPanelContent> {
        if let hostingView { return hostingView }
        let content = PopoverPanelContent(model: model, state: panelState) { [weak self] size in
            self?.contentSizeChanged(size)
        }
        let view = NSHostingView(rootView: content)
        // The controller sizes the panel (top edge pinned); the view must not resize the window on its own.
        view.sizingOptions = []
        view.autoresizingMask = [.width, .height]
        if let background = panel.contentView {
            view.frame = background.bounds
            background.addSubview(view)
        }
        hostingView = view
        return view
    }

    private func open() -> Bool {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            AppLog.write("PRBar’s menu bar icon isn’t in the menu bar; the popover can’t open.")
            return false
        }
        let frame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = Self.screen(containingX: frame.midX) ?? buttonWindow.screen ?? NSScreen.main else { return false }
        let menuBarHeight = StatusPanelLayout.menuBarHeight(
            statusBarThickness: NSStatusBar.system.thickness, safeAreaTop: screen.safeAreaInsets.top,
            screenFrame: screen.frame, visibleFrame: screen.visibleFrame
        )
        buttonFrame = frame
        anchorX = frame.midX
        visibleFrame = screen.visibleFrame
        top = StatusPanelLayout.top(buttonFrame: frame, screenFrame: screen.frame, menuBarHeight: menuBarHeight)
        panelState.availableHeight = StatusPanelLayout.maxHeight(top: top, visibleFrame: visibleFrame)

        let hosting = makeHostingViewIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        if fitting.width > 0, fitting.height > 0 { contentSize = fitting }
        if contentSize == .zero { contentSize = CGSize(width: Theme.popoverWidth, height: 200) }
        place()

        // A non-activating panel becomes key without activating PRBar: the app in front (full screen or not) stays in
        // front, and no Space changes.
        panel.makeKeyAndOrderFront(nil)
        // After the button's own mouse tracking, which would undo the highlight.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.statusItem.button?.highlight(true)
        }
        installMonitors(buttonWindow: buttonWindow)
        model.popoverVisibilityChanged(true)
        return true
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        if panel.isVisible { place() }
    }

    private func place() {
        let frame = StatusPanelLayout.frame(contentSize: contentSize, top: top, anchorX: anchorX, visibleFrame: visibleFrame)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private static func screen(containingX x: CGFloat) -> NSScreen? {
        NSScreen.screens.first { $0.frame.minX <= x && x < $0.frame.maxX }
    }

    /// A rounded-rectangle mask that stretches with the panel.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: Closing and keys

    private func installMonitors(buttonWindow: NSWindow) {
        removeMonitors()
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // A click in another app.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { eventMonitors.append(monitor) }
        // A click in another of PRBar's windows (the icon itself toggles the panel through its action).
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.belongsToPanel(event.window), event.window !== self.statusItem.button?.window else { return }
                self.close()
            }
            return event
        }) { eventMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? false } ? nil : event
        }) { eventMonitors.append(monitor) }

        observe(NotificationCenter.default, NSWindow.didMoveNotification, buttonWindow) { $0.buttonWindowMoved() }
        observe(NotificationCenter.default, NSWindow.didResizeNotification, buttonWindow) { $0.buttonWindowMoved() }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, nil) { $0.close() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification, nil) { $0.close() }
        observe(workspace, NSWorkspace.didActivateApplicationNotification, nil) { controller in
            // Another app came to the front (e.g. the browser that opened a PR).
            if NSWorkspace.shared.frontmostApplication != NSRunningApplication.current { controller.close() }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ object: AnyObject?,
                         _ action: @escaping @MainActor (StatusItemController) -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    private func removeMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors = []
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
    }

    /// The panel or a window that hangs from it (a popover inside it).
    private func belongsToPanel(_ window: NSWindow?) -> Bool {
        var current = window
        while let candidate = current {
            if candidate === panel { return true }
            current = candidate.parent
        }
        return false
    }

    private func buttonWindowMoved() {
        guard let button = statusItem.button, let window = button.window else { return close() }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        switch StatusPanelLayout.buttonMove(from: buttonFrame, to: frame, screenFrames: NSScreen.screens.map(\.frame)) {
        case .keep:
            break
        case .follow:
            anchorX = frame.midX
            place()
        case .close:
            close()
        }
        buttonFrame = frame
    }

    /// ↑/↓ select a PR row, Return opens it, Esc closes the panel. `true` = handled (the event goes no further).
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === panel, !(panel.firstResponder is NSText) else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let key = PopoverKey(keyCode: event.keyCode, hasModifiers: !modifiers.isEmpty) else { return false }
        switch key {
        case .close:
            close()
            return true
        case .up, .down:
            return model.popoverRows.move(key)
        case .open:
            guard let id = model.popoverRows.selectedID else { return false }
            model.openPRFromPopover(id)
            close()
            return true
        }
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Another of PRBar's windows became key (e.g. the Review window this panel just opened). A popover inside the
        // panel doesn't count. Checked after AppKit picks the new key window.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.belongsToPanel(NSApp.keyWindow) else { return }
            if NSApp.keyWindow != nil { self.close() }
        }
    }
}

/// The panel: it can be key (for the keyboard) without activating the app, and Esc closes it.
final class StatusPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// How tall the popover's content can be on the screen it opened on.
@MainActor
final class PopoverPanelState: ObservableObject {
    @Published var availableHeight: CGFloat = .infinity
}

/// The panel's SwiftUI content: `PopoverView` at its ideal size, which it reports so the panel can follow it.
struct PopoverPanelContent: View {
    let model: AppModel
    @ObservedObject var state: PopoverPanelState
    let sizeChanged: (CGSize) -> Void

    var body: some View {
        PopoverView(model: model, prStore: model.prStore, configStore: model.configStore, slack: model.slack,
                    tabs: model.popoverTab, rows: model.popoverRows)
            .environment(\.popoverAvailableHeight, state.availableHeight)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { sizeChanged($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The keyboard selection among the popover's PR rows (↑/↓, Return).
@MainActor
final class PopoverRowSelection: ObservableObject {
    @Published var selectedID: String?
    /// The rows on screen, top to bottom (`PopoverView` keeps it current).
    private(set) var rowIDs: [String] = []

    func setRows(_ ids: [String]) {
        rowIDs = ids
        let kept = PopoverRowNavigation.keep(selectedID, in: ids)
        if kept != selectedID { selectedID = kept }
    }

    /// `false` if there are no rows to move through.
    func move(_ key: PopoverKey) -> Bool {
        guard !rowIDs.isEmpty else { return false }
        selectedID = PopoverRowNavigation.move(from: selectedID, in: rowIDs, key: key)
        return true
    }

    func select(_ id: String) {
        if selectedID != id { selectedID = id }
    }

    func reset() {
        if selectedID != nil { selectedID = nil }
    }
}

private struct PopoverAvailableHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = .infinity
}

extension EnvironmentValues {
    /// The height the popover can use on this screen; `.infinity` outside the menu bar panel (snapshot mode).
    var popoverAvailableHeight: CGFloat {
        get { self[PopoverAvailableHeightKey.self] }
        set { self[PopoverAvailableHeightKey.self] = newValue }
    }
}
