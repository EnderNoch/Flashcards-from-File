import SwiftUI
import UniformTypeIdentifiers

/// The window: the decks in the sidebar, like the notes in Notes, and the open deck beside
/// them. A file dropped anywhere on the window opens.
struct ContentView: View {
    @Bindable private var m = Model.shared
    @State private var dropping = false

    var body: some View {
        let s = m.s
        NavigationSplitView {
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
            .navigationTitle(m.deck?.name ?? Model.appName)
            .navigationSubtitle(m.deck.map { $0.finished ? "" : "\($0.current + 1) / \($0.order.count)" } ?? "")
            .toolbar { if m.deck != nil { DeckTools() } }
        }
        .frame(minWidth: 760, minHeight: 540)
        // Warm the formula renderer up once the window is there (its own off-screen window
        // made any earlier keeps SwiftUI from opening this one), so the first card with math
        // doesn't wait for WebKit.
        .task { _ = MathRenderer.shared }
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
        .environment(\.locale, Locale(identifier: Strings.code))
        .environment(\.layoutDirection, Strings.rtl ? .rightToLeft : .leftToRight)
    }
}

struct Sidebar: View {
    @Bindable private var m = Model.shared

    var body: some View {
        let s = m.s
        List(selection: $m.openID) {
            Section(s.decks) {
                ForEach(m.decks) { d in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).lineLimit(1).truncationMode(.middle)
                            Text("\(d.known + d.unknown) / \(d.order.count)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: d.isFile ? "doc.text" : "doc.on.clipboard")
                    }
                    .tag(d.id)
                    .contextMenu {
                        if d.isFile {
                            Button(s.showInFinder) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: d.id)])
                            }
                            Divider()
                        }
                        Button(s.remove, role: .destructive) { m.remove(d.id) }
                    }
                }
            }
        }
        .onDeleteCommand { if let id = m.openID { m.remove(id) } }
        .toolbar {
            ToolbarItem {
                Button { AppDelegate.openPanel() } label: { Label(s.open, systemImage: "plus") }
                    .help(s.open)
            }
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

    var body: some View {
        let s = m.s
        VStack(spacing: 20) {
            ProgressStrip(deck: deck)
                .frame(maxWidth: 760)
            ZStack {
                if let card = deck.card {
                    CardView(card: card, flipped: deck.flipped, rating: deck.rating)
                        .id(deck.current)
                        .transition(.asymmetric(
                            insertion: .move(edge: m.forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: m.forward ? .leading : .trailing).combined(with: .opacity)))
                }
            }
            .frame(maxWidth: 900, maxHeight: .infinity)
            .animation(.smooth(duration: 0.35), value: deck.current)
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

/// How far into the deck: the cards passed so far, green for known, red for not, the accent
/// for skipped - the same bar as in the web version.
struct ProgressStrip: View {
    let deck: Deck

    var body: some View {
        GeometryReader { g in
            let total = max(1, deck.order.count)
            let seen = CGFloat(deck.current + 1) / CGFloat(total) * g.size.width
            let seenCount = CGFloat(deck.current + 1)
            let known = CGFloat(deck.order.prefix(deck.current + 1).count { deck.ratings[$0] == true })
            let unknown = CGFloat(deck.order.prefix(deck.current + 1).count { deck.ratings[$0] == false })
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                HStack(spacing: 0) {
                    Rectangle().fill(Color.accentColor).frame(width: seen * (seenCount - known - unknown) / seenCount)
                    Rectangle().fill(.green).frame(width: seen * known / seenCount)
                    Rectangle().fill(.red).frame(width: seen * unknown / seenCount)
                }
                .clipShape(Capsule())
            }
            .animation(.smooth, value: deck.current)
        }
        .frame(height: 6)
    }
}

/// The card: question in front, answer on the back, turned over by a click or Space.
/// Dragging it sideways goes to the next or previous card, as swiping does in the web version.
struct CardView: View {
    let card: Card
    let flipped: Bool
    let rating: Bool?
    private let m = Model.shared
    @State private var drag: CGFloat = 0

    var body: some View {
        let s = m.s
        GeometryReader { g in
            let size = min(max(min(g.size.width, g.size.height * 1.4) * 0.055, 18), 42)
            FlipCard(angle: flipped ? 180 : 0,
                     front: Face(label: s.question, text: card.front, hint: s.clickFront, size: size, rating: rating),
                     back: Face(label: s.answer, text: card.back, hint: s.clickBack, size: size, rating: rating))
                .animation(.spring(duration: 0.5, bounce: 0.15), value: flipped)
                .offset(x: drag)
                .rotationEffect(.degrees(Double(drag) / 40))
                .contentShape(.rect)
                .onTapGesture { m.flip() }
                .gesture(DragGesture(minimumDistance: 12)
                    .onChanged { drag = $0.translation.width }
                    .onEnded { v in
                        let rtl = Strings.rtl
                        if v.translation.width < -110 { rtl ? m.previous() : m.next() }
                        else if v.translation.width > 110 { rtl ? m.next() : m.previous() }
                        withAnimation(.spring) { drag = 0 }
                    })
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(flipped ? card.back : card.front)
                .accessibilityIdentifier("card")
        }
    }
}

/// Turns its content over around the vertical axis; past halfway the back shows.
struct FlipCard<Front: View, Back: View>: View, Animatable {
    var angle: Double
    let front: Front
    let back: Back

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        ZStack {
            if angle < 90 {
                front
            } else {
                back.rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
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

/// Plain text as text; with a formula, the picture KaTeX draws of the whole side.
struct CardText: View {
    let text: String
    let size: CGFloat
    let width: CGFloat
    @Environment(\.colorScheme) private var scheme
    @State private var image: NSImage?

    var body: some View {
        if MathRenderer.hasMath(text) {
            let key = MathRenderer.Key(text: text, width: Int(width), size: Int(size),
                                       color: scheme == .dark ? "rgba(255,255,255,0.88)" : "rgba(0,0,0,0.86)")
            Group {
                if let img = image ?? MathRenderer.shared.cached(key) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: img.size.width, maxHeight: img.size.height)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .task(id: key) { image = await MathRenderer.shared.image(key) }
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
