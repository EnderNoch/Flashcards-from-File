import SwiftUI
import UniformTypeIdentifiers

/// The window: the decks in the sidebar, like the notes in Notes, and the open deck beside
/// them. A file dropped anywhere on the window opens.
struct ContentView: View {
    @Bindable private var m = Model.shared
    @State private var dropping = false
    /// The sidebar opens with the split view, whatever state the window last saved.
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        let s = m.s
        Group {
            if m.decks.isEmpty && m.folder == nil {
                // No decks yet: just the window, no sidebar and no button for one.
                EmptyState(dropping: dropping)
                    .navigationTitle(Model.appName)
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    Sidebar()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
                } detail: {
                    Group {
                        if let d = m.deck {
                            if d.finished { ResultView(deck: d) } else { StudyView(deck: d) }
                        } else {
                            EmptyState(dropping: dropping)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(m.deck.map(m.name) ?? Model.appName)
                    .navigationSubtitle(m.deck.map { $0.finished ? "" : "\($0.current + 1) / \($0.order.count)" } ?? "")
                    .toolbar { if m.deck != nil { DeckTools() } }
                }
                .onAppear { columns = .all }
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .background { MainWindowMark() }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in Model.shared.open(url) }
            }
            return true
        }
        .alert(Model.appName, isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })) {
        } message: {
            Text(m.error ?? "")
        }
        .alert(s.resetTitle, isPresented: $m.askReset) {
            Button(s.resetButton, role: .destructive) { m.reset() }
            Button(s.cancel, role: .cancel) {}
        } message: {
            Text(s.resetBody)
        }
        .alert(m.askRemove.map { s.removeTitle(m.name($0)) } ?? "",
               isPresented: Binding(get: { m.askRemove != nil }, set: { if !$0 { m.askRemove = nil } }),
               presenting: m.askRemove) { d in
            Button(s.remove, role: .destructive) { m.remove(d.id) }
            Button(s.cancel, role: .cancel) {}
        } message: { d in
            if d.isFile { Text(s.removeBody) }
        }
        .alert(s.askTitle, isPresented: $m.askFolder) {
            Button(s.chooseFolder) { m.chooseFolder() }
            Button(s.oneByOne, role: .cancel) {}
        } message: {
            Text(s.askBody)
        }
        .onAppear { m.askAtFirstLaunch() }
        .alert(s.clearTitle, isPresented: $m.askClear) {
            Button(s.remove, role: .destructive) { m.clearDecks() }
            Button(s.cancel, role: .cancel) {}
        } message: {
            Text(s.clearBody)
        }
        .environment(\.locale, Locale(identifier: Strings.code))
        .environment(\.layoutDirection, Strings.rtl ? .rightToLeft : .leftToRight)
    }
}

/// The folder's files, grouped by the subfolder they are in, then the files opened one by one.
struct Sidebar: View {
    @Bindable private var m = Model.shared

    var body: some View {
        let s = m.s
        let loose = m.decks.filter { !m.isFolderFile($0.id) }
        List(selection: Binding(get: { m.openID }, set: { m.select($0) })) {
            if let folder = m.folder {
                ForEach(groups(in: folder), id: \.title) { g in
                    Section {
                        ForEach(g.files, id: \.path) { url in
                            let d = m.decks.first { $0.id == url.path }
                            DeckRow(name: m.showExtensions ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent,
                                    progress: d.map { "\($0.known + $0.unknown) / \($0.order.count)" },
                                    icon: "doc.text")
                                .tag(url.path)
                                .contextMenu {
                                    Button(s.showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                        }
                    } header: {
                        Text(g.title)
                    }
                }
            }
            if !loose.isEmpty {
                Section(s.decks) {
                    ForEach(loose) { d in
                        DeckRow(name: m.name(d), progress: "\(d.known + d.unknown) / \(d.order.count)",
                                icon: d.isFile ? "doc.text" : "doc.on.clipboard")
                            .tag(d.id)
                            .contextMenu {
                                if d.isFile {
                                    Button(s.showInFinder) {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: d.id)])
                                    }
                                    Divider()
                                }
                                Button(s.remove, role: .destructive) { m.askRemove = d }
                            }
                    }
                }
            }
        }
        // A folder's deck goes away with its file, not from the list.
        .onDeleteCommand { if let d = m.deck, !m.isFolderFile(d.id) { m.askRemove = d } }
        .toolbar {
            ToolbarItem {
                Button { AppDelegate.openPanel() } label: { Label(s.open, systemImage: "plus") }
                    .help(s.open)
            }
        }
    }

    /// The folder's own files under its name, then one section per subfolder ("Chemia/Klasa 1").
    private func groups(in folder: URL) -> [(title: String, files: [URL])] {
        let folder = folder.resolvingSymlinksInPath()
        var out: [(title: String, files: [URL])] = []
        // The folder's own files first, then the subfolders in Finder's order.
        let top = m.folderFiles.filter { $0.deletingLastPathComponent().path == folder.path }
        for url in top + m.folderFiles.filter({ !top.contains($0) }) {
            let dir = url.deletingLastPathComponent().path
            let rel = dir == folder.path ? folder.lastPathComponent : String(dir.dropFirst(folder.path.count + 1))
            if out.last?.title == rel { out[out.count - 1].files.append(url) } else { out.append((rel, [url])) }
        }
        return out
    }
}

struct DeckRow: View {
    let name: String
    let progress: String?
    let icon: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1).truncationMode(.middle)
                if let progress {
                    Text(progress)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: icon)
        }
    }
}

/// Listen, Shuffle and Reset Progress over the open deck.
struct DeckTools: ToolbarContent {
    private let m = Model.shared

    var body: some ToolbarContent {
        let s = m.s
        let d = m.deck
        ToolbarItemGroup {
            Button { m.listen() } label: {
                Label(s.listen, systemImage: m.speech.speaking ? "speaker.wave.3.fill" : "speaker.wave.2")
            }
            .help(s.listen)
            .disabled(d?.finished ?? true)
            Toggle(isOn: Binding(get: { d?.shuffled ?? false }, set: { _ in m.toggleShuffle() })) {
                Label(s.shuffle, systemImage: "shuffle")
            }
            .help(s.shuffle)
            Button { m.askReset = true } label: { Label(s.reset, systemImage: "arrow.counterclockwise") }
                .help(s.reset)
        }
    }
}

/// Nothing open yet: what the app takes and the two ways to give it a deck.
struct EmptyState: View {
    let dropping: Bool
    private let m = Model.shared

    var body: some View {
        let s = m.s
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            Text(Model.appName).font(.largeTitle.weight(.semibold))
            Text(s.dropHint).font(.title3).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button { AppDelegate.openPanel() } label: {
                    Label(s.open, systemImage: "folder").padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("open")
                Button { m.paste() } label: {
                    Label(s.paste, systemImage: "doc.on.clipboard").padding(.horizontal, 6)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.extraLarge)
            Text(s.formatHint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 24))
                    .padding(20)
            }
        }
    }
}

// MARK: learning

struct StudyView: View {
    let deck: Deck
    private let m = Model.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let s = m.s
        VStack(spacing: 20) {
            ProgressStrip(deck: deck)
                .frame(maxWidth: 760)
            ZStack {
                if let card = deck.card {
                    CardView(card: card, flipped: deck.flipped, rating: deck.rating)
                        .id(deck.current)
                        .transition(cardTransition)
                }
            }
            .frame(maxWidth: 900, maxHeight: .infinity)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3), value: deck.current)
            HStack(spacing: 12) {
                Button { m.previous() } label: { Image(systemName: "chevron.backward").frame(height: 20) }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help(s.previous)
                    .disabled(deck.current == 0)
                RateButton(title: s.dontKnow, icon: "xmark", count: deck.unknown, color: .red) { m.rate(false) }
                    .accessibilityIdentifier("dontKnow")
                RateButton(title: s.know, icon: "checkmark", count: deck.known, color: .green) { m.rate(true) }
                    .accessibilityIdentifier("know")
                Button { m.next() } label: { Image(systemName: "chevron.forward").frame(height: 20) }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help(s.next)
                    .disabled(deck.current >= deck.order.count - 1)
                    .accessibilityIdentifier("next")
            }
            .controlSize(.extraLarge)
            .frame(maxWidth: 640)
        }
        .padding(28)
    }

    /// The next card slides in a little way and fades, like pages in Safari or Preview - not a
    /// whole card's width. With Reduce Motion it only fades.
    private var cardTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let step: CGFloat = Strings.rtl ? -60 : 60
        let ahead = m.forward ? step : -step
        return .asymmetric(insertion: .offset(x: ahead).combined(with: .opacity),
                           removal: .offset(x: -ahead).combined(with: .opacity))
    }
}

struct RateButton: View {
    let title: String
    let icon: String
    let count: Int
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon).fontWeight(.semibold)
                Spacer(minLength: 8)
                Text("\(count)").monospacedDigit().opacity(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(color)
    }
}

/// The whole deck as one bar, a slot per card in the order they come up: each card's own
/// slot is green when known, red when not - right where that card is, not gathered at the
/// start - and the cards passed without a rating so far are the accent.
struct ProgressStrip: View {
    let deck: Deck

    var body: some View {
        let order = deck.order
        let ratings = deck.ratings
        let current = deck.current
        Canvas { context, size in
            let total = max(1, order.count)
            let slot = size.width / CGFloat(total)
            context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .style(.quaternary))
            // Neighbouring cards of one colour are one rectangle, so a long deck stays a few shapes.
            var runStart = 0
            var runColor: Color?
            func close(_ end: Int) {
                guard let c = runColor else { return }
                let rect = CGRect(x: CGFloat(runStart) * slot, y: 0, width: CGFloat(end - runStart) * slot, height: size.height)
                context.fill(Path(rect), with: .color(c))
            }
            for i in 0...order.count {
                var color: Color?
                if i < order.count {
                    switch ratings[order[i]] {
                    case true?: color = .green
                    case false?: color = .red
                    case nil: color = i <= current ? .accentColor : nil
                    }
                }
                if i == order.count || color != runColor {
                    close(i)
                    runStart = i
                    runColor = color
                }
            }
        }
        .frame(height: 6)
        .animation(.smooth, value: deck.current)
    }
}

/// The card: question in front, answer on the back, turned over by a click or Space.
/// A two-finger swipe on the trackpad (AppDelegate) or a drag with the mouse goes to the next or
/// previous card; the card follows the fingers and settles back like a page in Safari.
struct CardView: View {
    let card: Card
    let flipped: Bool
    let rating: Bool?
    private let m = Model.shared
    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let s = m.s
        GeometryReader { g in
            let size = min(max(min(g.size.width, g.size.height * 1.4) * 0.055, 18), 42)
            let front = Face(label: s.question, text: card.front, hint: s.clickFront, size: size, rating: rating)
            let back = Face(label: s.answer, text: card.back, hint: s.clickBack, size: size, rating: rating)
            Group {
                if reduceMotion {
                    // Reduce Motion: the sides cross-fade instead of turning.
                    ZStack {
                        front.opacity(flipped ? 0 : 1)
                        back.opacity(flipped ? 1 : 0)
                    }
                    .animation(.easeInOut(duration: 0.2), value: flipped)
                } else {
                    ZStack {
                        front.modifier(FlipSide(angle: flipped ? 180 : 0, back: false))
                        back.modifier(FlipSide(angle: flipped ? 180 : 0, back: true))
                    }
                    .animation(.smooth(duration: 0.4), value: flipped)
                }
            }
            .offset(x: reduceMotion ? 0 : Self.rubberBand(drag + m.swipe, limit: g.size.width / 3))
            .contentShape(.rect)
            .onTapGesture { m.flip() }
            .gesture(DragGesture(minimumDistance: 12)
                .onChanged { drag = $0.translation.width }
                .onEnded { v in
                    m.finishSwipe(v.translation.width)
                    withAnimation(.smooth(duration: 0.3)) { drag = 0 }
                })
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(flipped ? card.back : card.front)
            .accessibilityIdentifier("card")
        }
    }

    /// Follows the fingers at first and resists more the farther it goes, as AppKit's
    /// elastic scrolling does.
    static func rubberBand(_ x: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0 else { return 0 }
        let a = abs(x)
        return (1 - 1 / (a * 0.55 / limit + 1)) * limit * (x < 0 ? -1 : 1)
    }
}

/// One side of a turning card. As a modifier SwiftUI redraws it on every frame of the turn,
/// so each side shows exactly while it faces the viewer - a view with its own animatable
/// angle was skipped on the first turn of a fresh card and showed the question mirrored.
struct FlipSide: ViewModifier, Animatable {
    var angle: Double
    let back: Bool

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let facing = back ? angle >= 90 : angle < 90
        content
            .opacity(facing ? 1 : 0)
            .rotation3DEffect(.degrees(back ? angle - 180 : angle), axis: (x: 0, y: 1, z: 0), perspective: 0.25)
            .allowsHitTesting(facing)
            .accessibilityHidden(!facing)
    }
}

/// One side of a card: a sheet like paper on the glass window, the side's name at the top,
/// the text in the middle, how to turn it at the bottom.
struct Face: View {
    let label: String
    let text: String
    let hint: String
    let size: CGFloat
    let rating: Bool?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                if let rating {
                    Image(systemName: rating ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(rating ? .green : .red)
                        .font(.title3)
                }
            }
            GeometryReader { g in
                CardText(text: text, size: size, width: g.size.width)
                    .frame(width: g.size.width, height: g.size.height)
            }
            .padding(.vertical, 12)
            Text(hint)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        }
    }
}

/// Plain text as text; with a formula, the side typeset by SwiftMath.
struct CardText: View {
    let text: String
    let size: CGFloat
    let width: CGFloat

    var body: some View {
        if CardMath.hasMath(text) {
            MathText(text: text, size: size)
        } else {
            Text(text)
                .font(.system(size: size, weight: .medium))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.3)
        }
    }
}

// MARK: end of the deck

struct ResultView: View {
    let deck: Deck
    private let m = Model.shared

    var body: some View {
        let s = m.s
        let unrated = deck.order.count - deck.known - deck.unknown
        let perfect = deck.unknown == 0 && unrated == 0
        VStack(spacing: 22) {
            Image(systemName: perfect ? "trophy.fill" : deck.known > deck.unknown ? "hand.thumbsup.fill" : "books.vertical.fill")
                .font(.system(size: 64))
                .foregroundStyle(perfect ? AnyShapeStyle(.yellow) : AnyShapeStyle(Color.accentColor))
                .symbolEffect(.bounce, value: deck.finished)
            Text(s.done).font(.largeTitle.weight(.semibold))
            HStack(spacing: 14) {
                Stat(value: deck.known, label: s.know, color: .green)
                Stat(value: deck.unknown, label: s.dontKnow, color: .red)
                Stat(value: deck.order.count, label: s.total, color: .primary)
            }
            Text(unrated > 0 ? s.unrated(unrated) : perfect ? s.perfect : deck.known == 0 ? s.bad : s.normal)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                if deck.unknown > 0 {
                    Button { m.retryMissed() } label: {
                        Label(s.retryMissed, systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
                Button { m.retryAll() } label: {
                    Label(s.retryAll, systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.extraLarge)
            .frame(maxWidth: 340)
        }
        .padding(40)
    }
}

struct Stat: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .frame(width: 130, height: 104)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

// MARK: settings

/// The app's settings, as in Apple's apps: a grouped form in a small window - how Listen
/// reads, and whether deck names keep their ".csv".
struct SettingsView: View {
    @Bindable private var m = Model.shared

    var body: some View {
        let s = m.s
        Form {
            Section {
                Picker(s.reading, selection: $m.reading) {
                    Text(s.readSystem).tag(Speech.Mode.system)
                    Text(s.readPolish).tag(Speech.Mode.polish)
                }
                .pickerStyle(.radioGroup)
                if m.reading == .polish {
                    LabeledContent(Speech.polishVoice?.name ?? "") {
                        Button(s.voices) { NSWorkspace.shared.open(Speech.voiceSettings) }
                    }
                }
            } footer: {
                Text(s.readPolishInfo)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent(s.folderTitle) {
                    HStack {
                        if let folder = m.folder {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(folder.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        } else {
                            Text(s.folderNone).foregroundStyle(.secondary)
                        }
                        Button(s.chooseFolder) { m.chooseFolder() }
                    }
                }
                if m.folder != nil {
                    Button(s.stopFolder) { m.folder = nil }
                }
            } footer: {
                Text(s.folderInfo)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle(s.showExtensions, isOn: $m.showExtensions)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.locale, Locale(identifier: Strings.code))
        .environment(\.layoutDirection, Strings.rtl ? .rightToLeft : .leftToRight)
    }
}

/// Tells AppDelegate which window holds the decks, so its keys and swipes stay out of Settings.
struct MainWindowMark: NSViewRepresentable {
    func makeNSView(context: Context) -> Mark { Mark() }
    func updateNSView(_ view: Mark, context: Context) {}

    final class Mark: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { AppDelegate.deckWindow = window }
        }
    }
}
