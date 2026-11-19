import AppKit
import EventKit
import SwiftUI

@main
@MainActor
enum MarginApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = MarginDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class MarginDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let workspace = Workspace(preview: CommandLine.arguments.contains("--preview"))
    private let tabWidth: CGFloat = 22
    private let tabHeight: CGFloat = 38
    private let tabGap: CGFloat = 5
    private let menuHeight: CGFloat = 28
    private var rail: NSPanel?
    private var settingsWindow: NSWindow?
    private var captureReturnApp: NSRunningApplication?
    private lazy var globalShortcuts = GlobalShortcuts(defaults: workspace.preview
        ? UserDefaults(suiteName: "margin.preview.shortcuts")! : .standard)
    private var dueTasks: [TaskItem] = []
    private var editorWindow: NSWindow?
    private var activeNoteID: String?
    private var buttons: [EdgeButton] = []
    private var onLeft = UserDefaults.standard.bool(forKey: "margin.edge.left")
    private var presentationObserver: NSKeyValueObservation?
    private var fullscreenSuppressed = false
    private var restoreEditorAfterFullscreen = false
    private lazy var taskAlert = TaskEdgeAlert { [weak self] tasks, newlyDue in
        self?.dueTasks = tasks
        self?.layOutTabs(pulsing: newlyDue)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !workspace.preview {
            globalShortcuts.invoke = { [weak self] action in
                guard let self, !self.workspace.busy else { return }
                let previous = NSWorkspace.shared.frontmostApplication
                if action == 0 { self.createNote() } else { self.createTask() }
                if previous?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    self.captureReturnApp = previous
                }
            }
        }
        let rail = NSPanel(contentRect: NSRect(x: 0, y: 0, width: tabWidth, height: tabHeight),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureFloating(rail)
        rail.hasShadow = false
        rail.contentView = NSView(frame: NSRect(x: 0, y: 0, width: tabWidth, height: tabHeight))
        self.rail = rail
        workspace.edgeTabsChanged = { [weak self] in self?.layOutTabs() }
        workspace.timedTasksChanged = { [weak self] tasks in self?.taskAlert.replaceTasks(tasks) }
        workspace.tasksViewed = { [weak self] in self?.taskAlert.acknowledge() }
        presentationObserver = NSApp.observe(\.currentSystemPresentationOptions, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateFullscreenVisibility() }
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(systemTimeChanged(_:)),
                                    name: NSWorkspace.didWakeNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(activeSpaceChanged(_:)),
                                    name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(systemTimeChanged(_:)),
                                               name: .NSSystemClockDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(systemTimeChanged(_:)),
                                               name: .NSSystemTimeZoneDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(remindersChanged(_:)),
                                               name: .EKEventStoreChanged, object: nil)
        updateFullscreenVisibility()
        layOutTabs()

        let args = CommandLine.arguments
        if args.contains("--show") || (!args.contains("--idle") && !workspace.preview) {
            openWorkspace()
        }
        taskAlert.replaceTasks(workspace.tasks)
        workspace.refreshRemindersForEdge()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        updateFullscreenVisibility()
        layOutTabs()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWorkspace()
        return false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === settingsWindow {
            globalShortcuts.stopRecording()
            sender.orderOut(nil)
            return false
        }
        closeEditor()
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === editorWindow, workspace.draft != nil else { return }
        // SwiftUI must finish mounting its native input before assigning first responder.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window.isKeyWindow,
                  window === self.editorWindow, self.workspace.draft != nil else { return }
            func input(in view: NSView) -> NSView? {
                guard !view.isHidden else { return nil }
                if let text = view as? NSTextView, text.isEditable { return text }
                if let field = view as? NSTextField, field.isEditable { return field }
                for child in view.subviews {
                    if let found = input(in: child) { return found }
                }
                return nil
            }
            if let content = window.contentView, let input = input(in: content) {
                window.makeFirstResponder(input)
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let sender = notification.object as? NSWindow, sender === editorWindow,
              !fullscreenSuppressed, activeNoteID != nil, editorWindow?.attachedSheet == nil,
              !workspace.busy, !workspace.pinned else { return }
        closeEditor()
    }

    @objc private func openWorkspace() {
        presentWorkspace { workspace.showLibrary(.notes) }
    }

    @objc private func openSettings() {
        if let settingsWindow {
            NSApp.activate()
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 488, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Margin Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ShortcutSettingsView(shortcuts: globalShortcuts))
        settingsWindow = window
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func createNote() {
        presentWorkspace { workspace.newItem(.notes) }
    }

    @objc private func createTask() {
        presentWorkspace { workspace.newItem(.tasks) }
    }

    @objc private func openTasks() {
        presentWorkspace { workspace.showLibrary(.tasks) }
    }

    @objc private func openDueTask(_ sender: DueTaskButton) {
        presentWorkspace {
            workspace.editTask(sender.task)
            taskAlert.acknowledge(taskID: sender.task.id)
        }
    }

    @objc private func remindersChanged(_ notification: Notification) {
        workspace.refreshRemindersForEdge()
    }

    @objc private func systemTimeChanged(_ notification: Notification) {
        taskAlert.resetClock()
        workspace.refreshRemindersForEdge()
    }

    @objc private func activeSpaceChanged(_ notification: Notification) {
        updateFullscreenVisibility()
    }

    private func updateFullscreenVisibility() {
        let options = NSApp.currentSystemPresentationOptions
        let hide = options.contains(.fullScreen) || options.contains([.hideDock, .hideMenuBar])
        guard fullscreenSuppressed != hide else { return }
        fullscreenSuppressed = hide
        if hide {
            restoreEditorAfterFullscreen = editorWindow?.isVisible == true
            editorWindow?.orderOut(nil)
            rail?.orderOut(nil)
        } else {
            if restoreEditorAfterFullscreen { editorWindow?.orderFrontRegardless() }
            restoreEditorAfterFullscreen = false
            rail?.orderFrontRegardless()
        }
    }

    private func presentWorkspace(_ configure: () -> Void) {
        guard !workspace.busy else { return }
        if let editorWindow, activeNoteID == nil {
            configure()
            NSApp.activate()
            editorWindow.makeKeyAndOrderFront(nil)
            return
        }

        // Keep the outgoing host alive until the replacement is on screen.
        let outgoingWindow = editorWindow
        closeEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 540),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Margin"
        window.contentMinSize = NSSize(width: 390, height: 420)
        window.isReleasedWhenClosed = false
        installContent(in: window, quickSticky: false)
        window.center()
        configure()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        withExtendedLifetime(outgoingWindow) {}
    }

    @objc private func clickedNote(_ sender: EdgeButton) {
        let id = sender.note.id
        if activeNoteID == id, editorWindow?.isVisible == true {
            closeEditor()
            return
        }
        guard !workspace.busy else { return }

        if activeNoteID == nil {
            closeEditor()
            let panel = StickyPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 390),
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
            configureFloating(panel)
            panel.dismiss = { [weak self] in self?.closeEditor() }
            installContent(in: panel, quickSticky: true)
        }
        activeNoteID = id
        workspace.openNote(id: id)
        updateHighlight()
        positionSticky()
        editorWindow?.makeKeyAndOrderFront(nil)
        watchOutsideClicks()
    }

    @objc private func changeEdge() {
        onLeft.toggle()
        if !workspace.preview { UserDefaults.standard.set(onLeft, forKey: "margin.edge.left") }
        layOutTabs()
    }

    private func installContent(in window: NSWindow, quickSticky: Bool) {
        window.delegate = self
        let hosting = NSHostingView(rootView: PanelView(
            workspace: workspace,
            quickSticky: quickSticky,
            close: { [weak self] in self?.closeEditor() },
            openWorkspace: { [weak self] in
                // Finish the button event before replacing its hosting window.
                DispatchQueue.main.async { self?.openWorkspace() }
            }
        ))
        hosting.sizingOptions = []
        hosting.frame = window.contentView?.bounds ?? NSRect(origin: .zero, size: window.contentLayoutRect.size)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        editorWindow = window
        workspace.opened()
    }

    private var outsideClickMonitor: Any?

    private func watchOutsideClicks() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.activeNoteID != nil, !self.workspace.pinned,
                  self.editorWindow?.attachedSheet == nil else { return }
            self.closeEditor()
        }
    }

    private func closeEditor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        guard let window = editorWindow else { return }
        editorWindow = nil
        activeNoteID = nil
        window.delegate = nil
        workspace.closed()
        window.orderOut(nil)
        updateHighlight()
        if let previous = captureReturnApp {
            captureReturnApp = nil
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previous.activate(options: [])
            }
        }
    }

    private func configureFloating(_ window: NSPanel) {
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenNone, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.animationBehavior = .none
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspace.flushAutosave()
    }

    private func layOutTabs(pulsing newlyDue: Set<String> = []) {
        guard let rail, let content = rail.contentView, let screen = NSScreen.screens.first else { return }
        let available = screen.visibleFrame
        let capacity = max(0, Int((available.height - 24 - menuHeight) / (tabHeight + tabGap)))
        let taskTabs = dueTasks.suffix(capacity)
        let notes = workspace.edgeStickies.prefix(capacity - taskTabs.count)
        let canPulse = !fullscreenSuppressed && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        content.subviews = []
        let height = menuHeight + CGFloat(notes.count + taskTabs.count) * (tabHeight + tabGap)
        let menuButton = NSButton(frame: NSRect(x: 0, y: height - menuHeight, width: tabWidth, height: menuHeight))
        menuButton.title = ""
        menuButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        menuButton.imagePosition = .imageOnly
        menuButton.contentTintColor = .white
        menuButton.isBordered = false
        menuButton.wantsLayer = true
        menuButton.layer?.cornerRadius = 6
        menuButton.target = self
        menuButton.action = #selector(showEdgeMenu(_:))
        menuButton.layer?.backgroundColor = NSColor(srgbRed: 0.25, green: 0.19, blue: 0.37, alpha: 1).cgColor
        menuButton.setAccessibilityLabel("Margin menu")
        content.addSubview(menuButton)
        for (index, task) in taskTabs.enumerated() {
            let y = height - menuHeight - CGFloat(index + 1) * (tabHeight + tabGap)
            let button = DueTaskButton(task: task, frame: NSRect(x: 0, y: y, width: tabWidth, height: tabHeight))
            button.target = self
            button.action = #selector(openDueTask(_:))
            content.addSubview(button)
            if canPulse && newlyDue.contains(task.id) { button.pulse() }
        }
        buttons = notes.enumerated().map { index, note in
            let y = height - menuHeight - CGFloat(taskTabs.count + index + 1) * (tabHeight + tabGap)
            let button = EdgeButton(note: note, onLeft: onLeft,
                                    frame: NSRect(x: 0, y: y, width: tabWidth, height: tabHeight))
            button.target = self
            button.action = #selector(clickedNote(_:))
            content.addSubview(button)
            return button
        }

        let x = onLeft ? available.minX : available.maxX - tabWidth
        rail.setFrame(NSRect(x: x, y: available.midY - height / 2, width: tabWidth, height: height), display: false)
        content.setFrameSize(NSSize(width: tabWidth, height: height))
        updateHighlight()
        content.needsDisplay = true
        rail.displayIfNeeded()
        if !fullscreenSuppressed && !rail.isVisible { rail.orderFrontRegardless() }
        positionSticky()
    }

    @objc private func showEdgeMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "All Notes", action: #selector(openWorkspace), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Note", action: #selector(createNote), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Task", action: #selector(createTask), keyEquivalent: "").target = self
        menu.addItem(withTitle: dueTasks.isEmpty ? "Tasks" : "Due Tasks", action: #selector(openTasks), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: onLeft ? "Move to Right Edge" : "Move to Left Edge",
                     action: #selector(changeEdge), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Margin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "").target = NSApp
        let x = onLeft ? sender.bounds.maxX : sender.bounds.minX
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: sender.bounds.midY), in: sender)
    }

    private func updateHighlight() {
        for button in buttons {
            button.selected = button.note.id == activeNoteID
        }
    }

    private func positionSticky() {
        guard let noteID = activeNoteID, let rail, let editorWindow,
              let screen = NSScreen.screens.first else { return }
        let usable = screen.visibleFrame
        let width = min(350, max(1, usable.width - tabWidth - 24))
        let height = min(390, max(1, usable.height - 24))
        let tabY = buttons.first { $0.note.id == noteID }.map { rail.frame.minY + $0.frame.midY }
            ?? rail.frame.midY
        let y = min(max(tabY - height / 2, usable.minY + 12), usable.maxY - height - 12)
        let x = onLeft ? rail.frame.maxX + 8 : rail.frame.minX - width - 8
        editorWindow.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

private final class StickyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var dismiss: () -> Void = {}

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }
}

private final class HoverTabView: NSView {
    var onExit: () -> Void = {}
    var onClick: () -> Void = {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseExited(with event: NSEvent) { onExit() }
    override func mouseDown(with event: NSEvent) { onClick() }
}

private final class EdgeButton: NSButton {
    let note: EdgeSticky
    let onLeft: Bool
    private static weak var activeHover: EdgeButton?
    private var hoverPreview: NSPanel?
    private var retractingPreview: NSPanel?
    private var hoverWork: DispatchWorkItem?
    private var hovered = false
    var selected = false {
        didSet {
            if selected != oldValue { needsDisplay = true }
        }
    }

    init(note: EdgeSticky, onLeft: Bool, frame: NSRect) {
        self.note = note
        self.onLeft = onLeft
        super.init(frame: frame)
        title = ""
        isBordered = false
        setAccessibilityLabel("Open \(note.title)")
        setAccessibilityHelp(note.excerpt)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hoverWork?.cancel()
        if hoverPreview != nil { return }
        hovered = true
        needsDisplay = true
        let work = DispatchWorkItem { [weak self] in self?.showPreview() }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        if let preview = hoverPreview, preview.frame.contains(NSEvent.mouseLocation) { return }
        dismissPreview()
    }

    override func mouseDown(with event: NSEvent) {
        dismissPreview()
        super.mouseDown(with: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { dismissPreview() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func dismissPreview() {
        hoverWork?.cancel()
        hoverWork = nil
        hovered = false
        if let preview = hoverPreview {
            retractingPreview = preview
            preview.ignoresMouseEvents = true
            let source = window.map { $0.convertToScreen(convert(bounds, to: nil)) }
            if let source, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.24
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    preview.animator().setFrame(source, display: true)
                }, completionHandler: {
                    preview.parent?.removeChildWindow(preview)
                    preview.close()
                })
            } else {
                preview.parent?.removeChildWindow(preview)
                preview.close()
            }
        }
        hoverPreview = nil
        needsDisplay = true
    }

    private func showPreview() {
        guard hovered, hoverPreview == nil, window?.isVisible == true, !selected else { return }
        if let previous = Self.activeHover, previous !== self {
            previous.dismissPreview()
            previous.finishRetraction()
        }
        finishRetraction()
        Self.activeHover = self
        guard let window else { return }
        let source = window.convertToScreen(convert(bounds, to: nil))
        let allWords = (note.title.isEmpty ? note.excerpt : note.title)
            .split(whereSeparator: { $0.isWhitespace })
        let words = allWords.prefix(3).joined(separator: " ")
        let hasMore = allWords.count > 3 || !note.excerpt.isEmpty
        let label = words.isEmpty ? "Untitled" : words + (hasMore ? "...." : "")
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let width = min(170, max(85, (label as NSString).size(withAttributes: [.font: font]).width + 32))
        let finalFrame = NSRect(x: onLeft ? source.minX : source.maxX - width,
                                y: source.minY, width: width, height: source.height)
        let preview = NSPanel(contentRect: source, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        preview.isReleasedWhenClosed = false
        preview.backgroundColor = .clear
        preview.isOpaque = false
        preview.hasShadow = false
        preview.ignoresMouseEvents = false
        preview.level = window.level
        preview.collectionBehavior = [.canJoinAllSpaces, .fullScreenNone, .ignoresCycle]
        let content = HoverTabView(frame: NSRect(origin: .zero, size: finalFrame.size))
        content.onExit = { [weak self] in
            guard let self else { return }
            if let window = self.window,
               window.convertToScreen(self.convert(self.bounds, to: nil)).contains(NSEvent.mouseLocation) { return }
            self.dismissPreview()
        }
        content.onClick = { [weak self] in
            guard let self else { return }
            self.dismissPreview()
            self.performClick(nil)
        }
        content.wantsLayer = true
        content.layer?.backgroundColor = note.tint.tabColor.cgColor
        content.layer?.cornerRadius = 7
        content.layer?.borderWidth = 0.75
        content.layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
        content.layer?.masksToBounds = true
        let text = NSTextField(labelWithString: label)
        text.font = font
        text.textColor = NSColor(srgbRed: 0.16, green: 0.14, blue: 0.24, alpha: 1)
        text.lineBreakMode = .byTruncatingTail
        text.frame = NSRect(x: 14, y: (source.height - 17) / 2, width: width - 28, height: 17)
        content.addSubview(text)
        preview.contentView = content
        hoverPreview = preview
        window.addChildWindow(preview, ordered: .above)
        preview.orderFrontRegardless()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            preview.setFrame(finalFrame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                preview.animator().setFrame(finalFrame, display: true)
            }
        }
    }

    private func finishRetraction() {
        guard let preview = retractingPreview else { return }
        preview.contentView?.layer?.removeAllAnimations()
        preview.parent?.removeChildWindow(preview)
        preview.orderOut(nil)
        preview.close()
        retractingPreview = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: onLeft ? -6 : 1, y: 0.8,
                          width: bounds.width + 5, height: bounds.height - 1.6)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        note.tint.tabColor.setFill()
        shape.fill()
        NSColor.black.withAlphaComponent(selected ? 0.65 : (hovered ? 0.4 : 0.18)).setStroke()
        shape.lineWidth = selected ? 1.7 : 0.75
        shape.stroke()
    }
}

private final class DueTaskButton: NSButton {
    let task: TaskItem
    private let glow = CAGradientLayer()

    init(task: TaskItem, frame: NSRect) {
        self.task = task
        super.init(frame: frame)
        title = ""
        image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        imagePosition = .imageOnly
        contentTintColor = NSColor(srgbRed: 0.83, green: 0.95, blue: 0.93, alpha: 1)
        isBordered = false
        toolTip = task.title
        setAccessibilityLabel("Due task: \(task.title)")

        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.24, blue: 0.24, alpha: 1).cgColor
        layer?.borderColor = NSColor(srgbRed: 0.43, green: 0.68, blue: 0.64, alpha: 0.58).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        let accent = NSColor(srgbRed: 0.41, green: 0.74, blue: 0.67, alpha: 1)
        glow.type = .radial
        glow.frame = bounds
        glow.startPoint = CGPoint(x: 0.5, y: 0.54)
        glow.endPoint = CGPoint(x: 1.0, y: 0.95)
        glow.colors = [accent.cgColor, accent.withAlphaComponent(0.4).cgColor,
                       accent.withAlphaComponent(0).cgColor]
        glow.locations = [0, 0.45, 1]
        glow.opacity = 0.25
        layer?.insertSublayer(glow, at: 0)
    }

    required init?(coder: NSCoder) { nil }

    func pulse() {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = glow.opacity
        animation.toValue = 0.85
        animation.duration = 0.70
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.autoreverses = true
        animation.repeatCount = 2
        glow.add(animation, forKey: "dueGlow")
    }
}
