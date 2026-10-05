import SwiftUI

@main
struct FlashcardsApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private let m = Model.shared

    var body: some Scene {
        Window(Text(Model.appName), id: "main") {
            ContentView()
        }
        .defaultSize(width: 980, height: 660)
        .windowToolbarStyle(.unified)
        // Also when the app is launched by opening a file.
        .defaultLaunchBehavior(.presented)
        // Fiszki z pliku → Settings… (⌘,), named by the system in its language.
        Settings {
            SettingsView()
        }
        .commands {
            // The app menu as in Photo Booth, without Services.
            CommandGroup(replacing: .systemServices) {}
            CommandGroup(replacing: .newItem) {
                let s = m.s
                Button(s.open) { AppDelegate.openPanel() }
                    .keyboardShortcut("o")
                Menu(s.openRecent) {
                    ForEach(m.decks.prefix(10)) { d in
                        Button(m.name(d)) { m.openID = d.id }
                    }
                    Divider()
                    Button(s.clearMenu) { m.askClear = true }
                        .disabled(m.decks.isEmpty)
                }
                Button(s.paste) { m.paste() }
            }
            // Plain keys while learning, as in the web version; AppDelegate's key monitor
            // does the work, the menu shows them and works with the mouse.
            CommandMenu(m.s.deck) {
                let s = m.s
                let open = m.deck.map { !$0.finished } ?? false
                Button(s.flip) { m.flip() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!open)
                Divider()
                Button(s.previous) { m.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!open)
                Button(s.next) { m.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!open)
                Button(s.first) { m.go(to: 0) }
                    .keyboardShortcut(.home, modifiers: [])
                    .disabled(!open)
                Button(s.last) { m.go(to: .max) }
                    .keyboardShortcut(.end, modifiers: [])
                    .disabled(!open)
                Divider()
                Button(s.dontKnow) { m.rate(false) }
                    .keyboardShortcut("1", modifiers: [])
                    .disabled(!open)
                Button(s.know) { m.rate(true) }
                    .keyboardShortcut("2", modifiers: [])
                    .disabled(!open)
                Divider()
                Button(s.listen) { m.listen() }
                    .disabled(!open)
                Toggle(s.shuffle, isOn: Binding(get: { m.deck?.shuffled ?? false }, set: { _ in m.toggleShuffle() }))
                    .disabled(m.deck == nil)
                Button(s.reset + "…") { m.askReset = true }
                    .disabled(m.deck == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keys: Any?
    private var swipes: Any?
    /// The current two-finger gesture: nil until its first movement says which way it goes.
    private static var swiping: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { AppDelegate.key($0) }
        swipes = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { AppDelegate.scroll($0) }
        // Launched by opening a file, the app doesn't show its window by itself.
        DispatchQueue.main.async { AppDelegate.showWindow() }
    }

    // One window, like System Settings: closing it ends the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Files opened from Finder, dropped on the Dock icon or picked in Open With.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Model.shared.open(url) }
        AppDelegate.showWindow()
    }

    static func showWindow() {
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        // Launched by a file, SwiftUI makes the window but leaves it hidden.
        if let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        } else if let menu = NSApp.windowsMenu,
                  let i = menu.items.firstIndex(where: { $0.title == Model.appName }) {
            menu.performActionForItem(at: i)
        }
    }

    /// The Dock icon's menu lists the decks, as apps list their recent documents there.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for d in Model.shared.decks.prefix(10) {
            let item = NSMenuItem(title: Model.shared.name(d), action: #selector(openFromDock(_:)), keyEquivalent: "")
            item.representedObject = d.id
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openFromDock(_ item: NSMenuItem) {
        Model.shared.openID = item.representedObject as? String
        AppDelegate.showWindow()
        NSApp.activate()
    }

    static func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Model.fileTypes
        panel.allowsMultipleSelection = false
        let done: (NSApplication.ModalResponse) -> Void = { r in
            if r == .OK, let url = panel.url { Model.shared.open(url) }
        }
        if let w = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: w, completionHandler: done)
        } else {
            done(panel.runModal())
        }
    }

    /// The deck window - not Settings or a panel: keys and swipes there are theirs.
    private static func isMain(_ w: NSWindow?) -> Bool {
        w != nil && w === deckWindow
    }

    /// The window with the decks, as MainWindowMark finds it.
    static weak var deckWindow: NSWindow?

    /// Two fingers sideways on the trackpad turn the page, as in Safari: the card follows,
    /// and past a threshold the next or previous one comes. Vertical scrolling and the
    /// momentum after lifting the fingers pass through untouched.
    private static func scroll(_ e: NSEvent) -> NSEvent? {
        let m = Model.shared
        guard e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty, isMain(e.window),
              e.window?.attachedSheet == nil else { return e }
        // Where the fingers go, whichever way the system scrolls: with natural scrolling off
        // the deltas point the other way.
        let dx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        switch e.phase {
        case .began:
            swiping = nil
            m.swipe = 0
        case .changed:
            // The first step with any movement decides: sideways is a swipe, the rest scrolls.
            if swiping == nil, e.scrollingDeltaX != 0 || e.scrollingDeltaY != 0 {
                swiping = m.deck.map { !$0.finished } == true && abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY)
            }
            if swiping == true { m.swipe += dx }
        case .ended, .cancelled:
            defer { swiping = nil }
            guard swiping == true else { return e }
            m.finishSwipe(m.swipe)
            withAnimation(.smooth(duration: 0.3)) { m.swipe = 0 }
            return nil
        default:
            break
        }
        return swiping == true ? nil : e
    }

    /// Space flips, arrows move, 1 and 2 rate, ⌘V pastes a deck - whatever has focus, unless
    /// a sheet or a text field is in the way. Up and down stay with the list of decks.
    private static func key(_ e: NSEvent) -> NSEvent? {
        guard let w = NSApp.keyWindow, isMain(w), w.attachedSheet == nil, NSApp.modalWindow == nil,
              !(w.firstResponder is NSText) else { return e }
        let m = Model.shared
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        if mods == .command, e.charactersIgnoringModifiers == "v" {
            m.paste()
            return nil
        }
        guard mods.isEmpty, let d = m.deck, !d.finished else { return e }
        // In right-to-left languages the next card comes from the left.
        let rtl = Strings.rtl
        switch e.keyCode {
        case 49: m.flip()
        case 123: rtl ? m.next() : m.previous()
        case 124: rtl ? m.previous() : m.next()
        case 115: m.go(to: 0)
        case 119: m.go(to: .max)
        default:
            switch e.charactersIgnoringModifiers {
            case "1": m.rate(false)
            case "2": m.rate(true)
            default: return e
            }
        }
        return nil
    }
}
