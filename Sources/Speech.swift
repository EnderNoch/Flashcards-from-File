import AVFoundation
import NaturalLanguage

/// Reading a card aloud. Two ways, picked in Settings: the system's voice for the card's
/// language, or the Polish reading - always Polish, formulas said in words.
@Observable
final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    enum Mode: String { case system, polish }

    private(set) var speaking = false
    @ObservationIgnored private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func toggle(_ text: String, mode: Mode) {
        if speaking { stop(); return }
        let u: AVSpeechUtterance
        switch mode {
        case .system:
            u = AVSpeechUtterance(string: Speech.readable(text))
            let rec = NLLanguageRecognizer()
            rec.processString(u.speechString)
            if let lang = rec.dominantLanguage {
                u.voice = AVSpeechSynthesisVoice(language: lang.rawValue)
            }
        case .polish:
            u = AVSpeechUtterance(string: PolishReading.speech(text))
            u.voice = Speech.polishVoice
        }
        guard !u.speechString.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        speaking = true
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        speaking = false
    }

    /// The best Polish voice installed: premium, then enhanced, then the built-in Zosia.
    static var polishVoice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "pl-PL" }
            .max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "pl-PL")
    }

    /// The Spoken Content settings, where better voices are downloaded.
    static let voiceSettings = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!

    /// LaTeX read out as written would be noise; keep the words and numbers.
    static func readable(_ text: String) -> String {
        text.replacingOccurrences(of: #"\\[a-zA-Z]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[$\\{}^_]"#, with: " ", options: .regularExpression)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
}

/// The Polish reading: plain text read
/// as it is, formulas turned into Polish words, symbols with a capital letter spelled out
/// (Na → "N A"), long pauses at colons, arrows and blanks, short ones around operators.
enum PolishReading {
    struct Segment {
        let text: String
        let math: Bool
        /// `$$…$$` or `\[…\]`: a formula on a line of its own.
        var display = false
    }

    /// Plain text and formulas, found the way the cards find them (autoWrapMath).
    static func segments(_ raw: String) -> [Segment] {
        let wrapped = autoWrap(raw)
        let re = try! NSRegularExpression(pattern: #"\$\$(.+?)\$\$|\\\[(.+?)\\\]|\$(.+?)\$|\\\((.+?)\\\)"#,
                                          options: .dotMatchesLineSeparators)
        let ns = wrapped as NSString
        var out: [Segment] = []
        var last = 0
        for m in re.matches(in: wrapped, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                out.append(Segment(text: ns.substring(with: NSRange(location: last, length: m.range.location - last)), math: false))
            }
            let latex = (1...4).compactMap { i -> String? in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }.first ?? ""
            let display = m.range(at: 1).location != NSNotFound || m.range(at: 2).location != NSNotFound
            out.append(Segment(text: latex, math: true, display: display))
            last = m.range.location + m.range.length
        }
        if last < ns.length { out.append(Segment(text: ns.substring(from: last), math: false)) }
        return out
    }

    static func speech(_ raw: String) -> String {
        var s = ""
        for seg in segments(raw) {
            s += seg.math ? " " + speakMath(seg.text) + " " : seg.text
        }
        // blanks in plain text too (§ marks a LONG pause)
        s = sub(s, #"_{2,}"#, " § miejsce na odpowiedź ")
        // a colon is a long pause
        s = s.replacingOccurrences(of: ":", with: " § ")
        // § → two full stops (two sentence pauses are clearly longer than one)
        s = s.replacingOccurrences(of: "§", with: " . . ")
        // neighbouring marks merge into a double one, not a triple
        s = sub(s, #"(?:\s*\.\s*){3,}"#, " . . ")
        // a digit right before a full stop would be read as an ordinal ("drugie")
        s = sub(s, #"(\d)\s*\."#, "$1 .")
        s = sub(s, #"\s+"#, " ").trimmingCharacters(in: .whitespaces)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    /// A LaTeX formula as words a Polish voice can say, symbols with a capital letter spelled out.
    static func speakMath(_ formula: String) -> String {
        var s = formula.replacingOccurrences(of: "~", with: " ")
        // "fill in the blank" gaps - the § before them is a long pause
        s = sub(s, #"\\text\s*\{_+\}"#, " § miejsce na odpowiedź ")
        s = sub(s, #"_{2,}"#, " § miejsce na odpowiedź ")
        // fractions, square roots
        s = sub(s, #"\\[dt]?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}"#) { " , \($0[1]) przez \($0[2]) , " }
        s = sub(s, #"\\sqrt\s*\{([^{}]*)\}"#) { " , pierwiastek z \($0[1]) , " }
        // known commands → words. Arrows are a long pause (full stops), operators a medium one (commas).
        let words: [(String, String)] = [
            ("\\longrightarrow", " § daje §"), ("\\rightarrow", " § daje §"),
            ("\\Rightarrow", " § daje §"), ("\\to", " § daje §"), ("\\leftarrow", " § z § "),
            ("\\cdot", " , razy , "), ("\\times", " , razy , "), ("\\pm", " , plus minus , "),
            ("\\leq", " , mniejsze lub równe , "), ("\\geq", " , większe lub równe , "),
            ("\\neq", " , różne od , "), ("\\approx", " , w przybliżeniu , "),
            ("\\Delta", " delta "), ("\\delta", " delta "), ("\\pi", " pi "),
            ("\\alpha", " alfa "), ("\\beta", " beta "), ("\\gamma", " gamma "),
            ("\\theta", " theta "), ("\\lambda", " lambda "), ("\\Omega", " omega "), ("\\omega", " omega "),
            ("\\degree", " stopni "), ("\\infty", " nieskończoność "), ("\\sum", " suma "), ("\\int", " całka "),
        ]
        for (k, v) in words { s = s.replacingOccurrences(of: k, with: v) }
        // unicode symbols
        let symbols: [(String, String)] = [
            ("→", " § daje §"), ("⟶", " § daje §"), ("⇒", " § daje §"), ("←", " § z § "),
            ("·", " , razy , "), ("×", " , razy , "),
            ("≤", " , mniejsze lub równe , "), ("≥", " , większe lub równe , "),
            ("≠", " , różne od , "), ("≈", " , w przybliżeniu , "),
            ("²", " do kwadratu "), ("³", " do sześcianu "),
        ]
        for (k, v) in symbols { s = s.replacingOccurrences(of: k, with: v) }
        // powers
        // Only a lone 2 or 3: x^{23} or x^25 are "do potęgi", not "do kwadratu" and the rest.
        s = sub(s, #"\^\s*(?:\{\s*2\s*\}|2(?![0-9A-Za-z]))"#, " do kwadratu ")
        s = sub(s, #"\^\s*(?:\{\s*3\s*\}|3(?![0-9A-Za-z]))"#, " do sześcianu ")
        s = sub(s, #"\^\s*\{([^{}]*)\}"#) { " do potęgi \($0[1]) " }
        s = sub(s, #"\^\s*([A-Za-z0-9]+)"#) { " do potęgi \($0[1]) " }
        // subscripts: Cl_2 → "Cl dwa". A one-digit subscript becomes a WORD, so the voice
        // doesn't say "dwóch" instead of "dwa".
        s = sub(s, #"_\{([^{}]*)\}"#) { " \(subscriptWord($0[1])) " }
        // Digits or one letter: H_2O is "H dwa O", not "H 2O".
        s = sub(s, #"_([0-9]+|[A-Za-z])"#) { " \(subscriptWord($0[1])) " }
        // operators - a medium pause (commas)
        s = s.replacingOccurrences(of: "+", with: " , plus , ").replacingOccurrences(of: "=", with: " , równa się , ")
        // unknown commands and leftovers
        s = sub(s, #"\\[a-zA-Z]+"#, " ")
        s = s.replacingOccurrences(of: "{", with: " ").replacingOccurrences(of: "}", with: " ")
            .replacingOccurrences(of: "\\", with: " ")
        // SPELL OUT symbols with a capital letter: Na → "N A", Cl → "C L", NaCl → "N A C L"
        s = sub(s, #"[A-Za-z]*[A-Z][A-Za-z]*"#) { $0[0].uppercased().map(String.init).joined(separator: " ") }
        // tidy commas and spaces (full stops don't come from here - long pauses are §,
        // turned into two full stops only in speech(_:))
        s = sub(s, #"\s*,[\s,]*"#, ", ")
        s = sub(s, #"\s+"#, " ").trimmingCharacters(in: .whitespaces)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }

    private static func subscriptWord(_ x: String) -> String {
        guard x.count == 1, let d = x.first?.wholeNumberValue else { return x }
        return ["zero", "jeden", "dwa", "trzy", "cztery", "pięć", "sześć", "siedem", "osiem", "dziewięć"][d]
    }

    // MARK: autoWrapMath - which parts of a card are formulas (also used to draw them)

    private static func fixBlanks(_ s: String) -> String {
        sub(s, #"_{2,}"#) { "\\text{" + $0[0] + "}" }
    }

    private static func has(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    static func autoWrap(_ input: String) -> String {
        var text = input
        if has(text, #"\$|\\\(|\\\["#) {
            text = sub(text, #"\$\$([\s\S]*?)\$\$"#) { "$$" + fixBlanks($0[1]) + "$$" }
            text = sub(text, #"\$([^$\n]+)\$"#) { "$" + fixBlanks($0[1]) + "$" }
            text = sub(text, #"\\\(([\s\S]*?)\\\)"#) { "\\(" + fixBlanks($0[1]) + "\\)" }
            text = sub(text, #"\\\[([\s\S]*?)\\\]"#) { "\\[" + fixBlanks($0[1]) + "\\]" }
            return text
        }
        let hasCmd = has(text, #"\\[a-zA-Z]"#)
        let hasSupSub = has(text, #"[A-Za-z0-9]\^[{A-Za-z0-9\-+]|[A-Za-z0-9]_[{0-9A-Za-z]"#)
        guard hasCmd || hasSupSub else { return text }

        text = fixBlanks(text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if has(text, #"\\begin\s*\{"#) { return "$$" + trimmed + "$$" }

        // "label: formula" - the first colon outside braces
        var depth = 0
        var splitAt: String.Index?
        let count = text.count
        for (n, i) in zip(0..., text.indices) {
            switch text[i] {
            case "{": depth += 1
            case "}": depth -= 1
            case ":" where depth == 0 && n < count - 2: splitAt = i
            default: break
            }
            if splitAt != nil { break }
        }
        let hasFrac = has(text, #"\\[dt]?frac"#)
        if let at = splitAt {
            let label = String(text[...at])
            let formula = String(text[text.index(after: at)...]).trimmingCharacters(in: .whitespaces)
            if has(formula, #"\\[a-zA-Z]|[\^_]"#) {
                return hasFrac ? label + "\n$$" + formula + "$$" : label + " $" + formula + "$"
            }
        }

        // words mixed with a few inline formulas
        // (not LaTeX commands: "\sqrt" or "\frac" are no words)
        let wordRe = try! NSRegularExpression(pattern: #"(?<!\\)\b[a-zA-ZąćęłńóśźżĄĆĘŁŃÓŚŹŻ]{3,}\b"#)
        if wordRe.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) >= 2 {
            return sub(text, #"((?:\\[a-zA-Z]+(?:\{[^}]*\}|\[[^\]]*\])*|[A-Za-z0-9]\^[{A-Za-z0-9\-+][^,;\s]*|[A-Za-z0-9]_[{0-9A-Za-z][^,;\s]*)+)"#) { m in
                has(m[0], #"\\[dt]?frac"#) ? "\n$$" + m[0] + "$$" : "$" + m[0] + "$"
            }
        }
        return hasFrac ? "$$" + trimmed + "$$" : "$" + trimmed + "$"
    }

    // MARK: regex helpers

    /// Replaces every match with a template ($1 and so on).
    static func sub(_ s: String, _ pattern: String, _ template: String) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                           withTemplate: template)
    }

    /// Replaces every match with what `f` makes of its groups (0 is the whole match).
    static func sub(_ s: String, _ pattern: String, _ f: ([String]) -> String) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += f(groups)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
