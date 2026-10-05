import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

struct Card: Codable, Hashable {
    var front: String
    var back: String
}

/// A deck from a file or the clipboard, with where the learning got to. Every deck keeps its
/// own progress, so going back to one carries on from the same card.
struct Deck: Codable, Identifiable, Hashable {
    /// The file's path, or "clip:" and a hash of the text for a pasted deck.
    var id: String
    var name: String
    var cards: [Card]
    /// Indexes into `cards` in the order they come up; after Retry Missed only those cards.
    var order: [Int]
    /// Card index → known. Only cards in `order` count.
    var ratings: [Int: Bool] = [:]
    /// Position in `order`.
    var current = 0
    var shuffled = false
    var flipped = false
    /// The end screen is showing.
    var finished = false

    init(id: String, name: String, cards: [Card]) {
        self.id = id
        self.name = name
        self.cards = cards
        order = Array(cards.indices)
    }

    var card: Card? { order.indices.contains(current) ? cards[order[current]] : nil }
    var known: Int { order.count { ratings[$0] == true } }
    var unknown: Int { order.count { ratings[$0] == false } }
    var rating: Bool? { order.indices.contains(current) ? ratings[order[current]] : nil }
    var isFile: Bool { !id.hasPrefix("clip:") }
}

/// The whole state: the decks opened so far, newest first, and which one is open. Saved in
/// UserDefaults as soon as anything changes.
@Observable
final class Model {
    static let shared = Model()

    @ObservationIgnored private let ud = UserDefaults.standard

    var decks: [Deck] { didSet { save() } }
    /// The deck in the window; nil shows the place to open one.
    var openID: String? { didSet { ud.set(openID, forKey: "open"); speech.stop() } }
    /// A problem to show over the window, already in the user's language.
    var error: String?
    var askReset = false
    /// The deck waiting for Remove from List to be confirmed.
    var askRemove: Deck?
    var askClear = false
    /// How far a two-finger swipe has moved the card, in points; 0 when not swiping.
    var swipe: CGFloat = 0
    /// The last move went to a later card; the card slides in from that side.
    var forward = true

    let speech = Speech()

    /// Deck names with ".csv" and the like, as Finder shows them with its own setting on.
    var showExtensions: Bool {
        didSet { ud.set(showExtensions, forKey: "showExtensions") }
    }

    /// How Listen reads: the system's voice as it is, or the Android app's Polish reading.
    var reading: Speech.Mode {
        didSet { ud.set(reading.rawValue, forKey: "reading") }
    }

    static let maxDecks = 20

    /// The name in the system's language, from the bundle's localized Info.plist (build.sh).
    static let appName = Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String
        ?? Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "Flashcards from File"

    static let fileTypes: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText,
                                      UTType(filenameExtension: "tsv") ?? .plainText]

    private init() {
        decks = (ud.data(forKey: "decks")).flatMap { try? JSONDecoder().decode([Deck].self, from: $0) } ?? []
        openID = ud.string(forKey: "open")
        showExtensions = ud.object(forKey: "showExtensions") as? Bool ?? true
        reading = Speech.Mode(rawValue: ud.string(forKey: "reading") ?? "") ?? .system
        if let id = openID, !decks.contains(where: { $0.id == id }) { openID = nil }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(decks) { ud.set(data, forKey: "decks") }
    }

    var s: Strings { Strings.current }

    /// A deck's name as the sidebar, title and menus show it.
    func name(_ d: Deck) -> String {
        showExtensions || !d.isFile ? d.name : (d.name as NSString).deletingPathExtension
    }

    var deck: Deck? {
        get { decks.first { $0.id == openID } }
        set {
            guard let newValue, let i = decks.firstIndex(where: { $0.id == newValue.id }) else { return }
            decks[i] = newValue
        }
    }

    /// Changes the open deck in place.
    private func change(_ f: (inout Deck) -> Void) {
        guard var d = deck else { return }
        f(&d)
        // Another card or the other side: what was being read no longer shows.
        if d.current != deck?.current || d.flipped != deck?.flipped || d.order != deck?.order { speech.stop() }
        deck = d
    }

    // MARK: opening

    func open(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            error = s.cantRead
            return
        }
        // UTF-8 first, as every export is; old Excel CSVs from Windows come in Windows-1250.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1250)
            ?? String(decoding: data, as: UTF8.self)
        add(text: text, id: url.path, name: url.lastPathComponent)
    }

    func paste() {
        let pb = NSPasteboard.general
        // A file copied in Finder pastes as the file (its text on the pasteboard is just the name).
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
            open(url)
            return
        }
        guard let text = pb.string(forType: .string), !text.isEmpty else {
            error = s.noCards
            return
        }
        // A stable id, so pasting the same text again finds its progress after a relaunch too.
        let hash = SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        add(text: text, id: "clip:" + hash, name: s.clipboard)
    }

    /// The same file opened again with the same cards carries on; changed cards start over.
    private func add(text: String, id: String, name: String) {
        let cards = Parser.parse(text)
        guard !cards.isEmpty else {
            error = s.noCards
            return
        }
        var d = decks.first { $0.id == id && $0.cards == cards } ?? Deck(id: id, name: name, cards: cards)
        d.name = name
        decks = [d] + decks.filter { $0.id != id }.prefix(Model.maxDecks - 1)
        openID = id
    }

    func remove(_ id: String) {
        if openID == id { openID = nil }
        decks.removeAll { $0.id == id }
    }

    func clearDecks() {
        openID = nil
        decks = []
    }

    // MARK: learning

    func flip() {
        guard deck?.finished == false else { return }
        change { $0.flipped.toggle() }
    }

    func rate(_ known: Bool) {
        change { d in
            guard !d.finished, d.order.indices.contains(d.current) else { return }
            d.ratings[d.order[d.current]] = known
            d.flipped = false
            forward = true
            if d.current < d.order.count - 1 { d.current += 1 } else { d.finished = true }
        }
    }

    func go(to i: Int) {
        change { d in
            guard !d.finished, !d.order.isEmpty else { return }
            let t = min(max(i, 0), d.order.count - 1)
            guard t != d.current else { return }
            forward = t > d.current
            d.current = t
            d.flipped = false
        }
    }

    /// The end of a swipe or a drag: far enough to the left is the next card, to the right
    /// the previous one (the other way round in right-to-left languages).
    func finishSwipe(_ distance: CGFloat) {
        let back = Strings.rtl ? distance < -90 : distance > 90
        let ahead = Strings.rtl ? distance > 90 : distance < -90
        if ahead { next() } else if back { previous() }
    }

    func next() { go(to: (deck?.current ?? 0) + 1) }
    func previous() { go(to: (deck?.current ?? 0) - 1) }

    /// Shuffling deals the cards again from the first one, as in the web and Android versions.
    func toggleShuffle() {
        change { d in
            d.shuffled.toggle()
            d.order = d.shuffled ? d.order.shuffled() : d.order.sorted()
            restart(&d)
        }
    }

    func reset() {
        change { d in
            if d.shuffled { d.order.shuffle() }
            restart(&d)
        }
    }

    func retryAll() {
        change { d in
            d.order = d.shuffled ? Array(d.cards.indices).shuffled() : Array(d.cards.indices)
            restart(&d)
        }
    }

    func retryMissed() {
        change { d in
            let missed = d.order.filter { d.ratings[$0] == false }
            guard !missed.isEmpty else { return }
            d.order = d.shuffled ? missed.shuffled() : missed
            restart(&d)
        }
    }

    private func restart(_ d: inout Deck) {
        for i in d.order { d.ratings[i] = nil }
        d.current = 0
        d.flipped = false
        d.finished = false
    }

    /// Reads the side of the card that is showing.
    func listen() {
        guard let d = deck, let c = d.card else { return }
        speech.toggle(d.flipped ? c.back : c.front, mode: reading)
    }
}

/// Two columns from CSV, TSV or plain text, the same rules as the web and Android versions:
/// the separator is whichever of `;` `,` or tab the first line has most of, quotes may wrap a
/// cell (with `""` for a quote inside), and a header row like "question;answer" is skipped.
enum Parser {
    static let fronts: Set = ["front", "pytanie", "question", "term"]
    static let backs: Set = ["back", "odpowiedź", "odpowiedz", "answer", "definition"]

    static func parse(_ text: String) -> [Card] {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let first = text.prefix { $0 != "\n" && $0 != "\r\n" }
        let delim: Character = [",", ";", "\t"].max { a, b in first.count { $0 == a } < first.count { $0 == b } } ?? ","
        var cards: [Card] = []
        for row in rows(text, delim) where row.count >= 2 {
            let front = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let back = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if front.isEmpty && back.isEmpty { continue }
            if cards.isEmpty, fronts.contains(front.lowercased()), backs.contains(back.lowercased()) { continue }
            cards.append(Card(front: front, back: back))
        }
        return cards
    }

    private static func rows(_ text: String, _ delim: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = ""
        var quoted = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? chars.next() {
            pending = nil
            if quoted {
                if ch == "\"" {
                    let n = chars.next()
                    if n == "\"" { cell.append("\"") } else { quoted = false; pending = n }
                } else {
                    cell.append(ch)
                }
            } else if ch == "\"" {
                quoted = true
            } else if ch == delim {
                row.append(cell); cell = ""
            } else if ch == "\n" || ch == "\r\n" {
                row.append(cell); cell = ""
                rows.append(row); row = []
            } else if ch != "\r" {
                cell.append(ch)
            }
        }
        if !cell.isEmpty || !row.isEmpty {
            row.append(cell)
            rows.append(row)
        }
        return rows
    }
}
