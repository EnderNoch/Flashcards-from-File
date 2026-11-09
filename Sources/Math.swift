import SwiftUI
import SwiftMath

/// Formulas on cards, typeset natively by SwiftMath (Vendor/SwiftMath) and drawn by SwiftUI
/// itself - no web view. A side with math becomes lines of LaTeX: words and inline formulas
/// wrap together, `$$…$$` formulas stand on lines of their own.
enum CardMath {
    /// Text the formula detection (autoWrap) would treat as math.
    static func hasMath(_ text: String) -> Bool {
        text.contains("$") || text.contains("\\(") || text.contains("\\[")
            || text.range(of: #"\\[a-zA-Z]"#, options: .regularExpression) != nil
            || text.range(of: #"[A-Za-z0-9]\^[{A-Za-z0-9+-]|[A-Za-z0-9]_[{0-9A-Za-z]"#, options: .regularExpression) != nil
    }

    struct Line {
        /// Words as `\text{}` and formulas, each its own piece, so one formula SwiftMath can't
        /// read can be shown as written while the rest of the line stays typeset.
        var parts: [Part]
        let block: Bool

        /// Pieces with a space between them where the card has one: "$\\mathrm{HF}$," keeps its
        /// comma right after the formula.
        var latex: String {
            parts.enumerated().map { i, p in (i == 0 || p.glued ? "" : "\\ ") + p.latex }.joined()
        }

        /// The line with every formula SwiftMath can't read turned into its own text.
        func readable(size: CGFloat) -> Line {
            var line = self
            line.parts = parts.flatMap { p -> [Part] in
                guard p.math, MathLayout(p.latex, size: size, maxWidth: 0, block: block) == nil else { return [p] }
                return words(p.raw, glued: p.glued)
            }
            return line
        }
    }

    struct Part {
        let latex: String
        let math: Bool
        let raw: String
        /// Written right after the previous piece, with no space between.
        var glued = false
    }

    /// Words of plain text; the first is glued to what came before when the text doesn't start
    /// with a space.
    static func words(_ text: String, glued: Bool) -> [Part] {
        text.split(separator: " ", omittingEmptySubsequences: true).enumerated().map { i, w in
            Part(latex: "\\text{" + escape(String(w)) + "}", math: false, raw: String(w), glued: i == 0 && glued)
        }
    }

    /// The side's text cut into lines: plain words go into `\text{}` one by one so they can
    /// wrap, inline formulas stay between them, block formulas and line breaks start a new line.
    static func lines(_ raw: String) -> [Line] {
        var out: [Line] = []
        var current: [Part] = []
        func flush() {
            if !current.isEmpty { out.append(Line(parts: current, block: false)) }
            current = []
        }
        // Whether the text so far ends in a space - the next piece is glued to it if not.
        var spaced = true
        for seg in PolishReading.segments(raw) {
            if seg.math {
                let part = Part(latex: seg.text, math: true, raw: seg.text, glued: !spaced)
                spaced = false
                if seg.display {
                    flush()
                    out.append(Line(parts: [part], block: true))
                } else {
                    current.append(part)
                }
            } else {
                for (n, piece) in seg.text.components(separatedBy: "\n").enumerated() {
                    if n > 0 { flush() }
                    current += words(piece, glued: n == 0 && !spaced && !(piece.first?.isWhitespace ?? true))
                }
                spaced = seg.text.last?.isWhitespace ?? spaced
            }
        }
        flush()
        return out
    }

    /// Plain text inside `\text{}`: braces and backslashes would be read as LaTeX.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "{", with: "(")
            .replacingOccurrences(of: "}", with: ")")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "&", with: "\\&")
            .replacingOccurrences(of: "#", with: "\\#")
    }
}

/// A card side with formulas, drawn into a Canvas in the space it is given: lines centred,
/// the type made smaller until everything fits, like `minimumScaleFactor` on plain text.
struct MathText: View {
    let text: String
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // A formula SwiftMath can't read shows as written; the rest of its line stays typeset.
        let lines = CardMath.lines(text).map { line in
            MathLayout(line.latex, size: size, maxWidth: 0, block: line.block) == nil ? line.readable(size: size) : line
        }
        let dark = scheme == .dark
        if lines.contains(where: { MathLayout($0.latex, size: size, maxWidth: 0, block: $0.block) == nil }) {
            Text(text)
                .font(.system(size: size, weight: .medium))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.3)
        } else {
            canvas(lines, dark: dark)
        }
    }

    private func canvas(_ lines: [CardMath.Line], dark: Bool) -> some View {
        Canvas { context, area in
            guard let fit = Self.fit(lines, size: size, in: area) else { return }
            let color: NSColor = dark ? .white.withAlphaComponent(0.88) : .black.withAlphaComponent(0.86)
            let gap = fit.size * 0.35
            let total = fit.layouts.reduce(0) { $0 + $1.height } + gap * CGFloat(max(0, fit.layouts.count - 1))
            var y = (area.height - total) / 2
            context.withCGContext { cg in
                for l in fit.layouts {
                    l.draw(in: cg, at: CGPoint(x: (area.width - l.width) / 2, y: y), color: color)
                    y += l.height + gap
                }
            }
        }
        .accessibilityLabel(text)
    }

    /// The largest type, from `size` down, at which all lines fit in `area`.
    private static func fit(_ lines: [CardMath.Line], size: CGFloat, in area: CGSize) -> (size: CGFloat, layouts: [MathLayout])? {
        var s = size
        var best: (size: CGFloat, layouts: [MathLayout])?
        for _ in 0..<10 {
            let layouts = lines.compactMap { MathLayout($0.latex, size: s, maxWidth: area.width, block: $0.block) }
            guard layouts.count == lines.count else { return nil }
            best = (s, layouts)
            let height = layouts.reduce(0) { $0 + $1.height } + s * 0.35 * CGFloat(max(0, layouts.count - 1))
            let width = layouts.map(\.width).max() ?? 0
            if height <= area.height && width <= area.width + 1 { break }
            s *= 0.85
        }
        return best
    }
}
