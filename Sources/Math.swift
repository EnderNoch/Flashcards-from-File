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
        let latex: String
        let block: Bool
    }

    /// The side's text cut into lines: plain words go into `\text{}` one by one so they can
    /// wrap, inline formulas stay between them, block formulas and line breaks start a new line.
    static func lines(_ raw: String) -> [Line] {
        var out: [Line] = []
        var current: [String] = []
        func flush() {
            if !current.isEmpty { out.append(Line(latex: current.joined(separator: "\\ "), block: false)) }
            current = []
        }
        for seg in PolishReading.segments(raw) {
            if seg.math {
                if seg.display {
                    flush()
                    out.append(Line(latex: seg.text, block: true))
                } else {
                    current.append(seg.text)
                }
            } else {
                for (n, part) in seg.text.components(separatedBy: "\n").enumerated() {
                    if n > 0 { flush() }
                    for word in part.split(separator: " ", omittingEmptySubsequences: true) {
                        current.append("\\text{" + escape(String(word)) + "}")
                    }
                }
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
        let lines = CardMath.lines(text)
        let dark = scheme == .dark
        // LaTeX SwiftMath can't read shows as the text it is.
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
