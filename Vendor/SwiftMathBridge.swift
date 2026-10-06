// Our own file, built into the SwiftMath module (build.sh): SwiftMath without Swift Package
// Manager, and the one call the app needs - typeset LaTeX, then draw it into a CGContext.

import Foundation
import CoreGraphics
import AppKit

extension Bundle {
    /// SwiftPM's resource bundle; here mathFonts.bundle sits in the app's own Resources.
    static var module: Bundle { .main }
}

/// One typeset formula (or line of words and formulas), ready to draw.
public final class MathLayout {
    public let width: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    private let display: MTMathListDisplay

    public var height: CGFloat { ascent + descent }

    /// `latex` typeset in Fira Math at `size` points, wrapped at `maxWidth` (0: no wrapping);
    /// `block` is display style, as `$$…$$`. Nil when the LaTeX can't be read.
    public init?(_ latex: String, size: CGFloat, maxWidth: CGFloat, block: Bool) {
        guard let list = MTMathListBuilder.build(fromString: latex),
              let font = MTFontManager.fontManager.firaRegularFont(withSize: size),
              let d = MTTypesetter.createLineForMathList(list, font: font, style: block ? .display : .text,
                                                          maxWidth: maxWidth)
        else { return nil }
        display = d
        width = d.width
        ascent = d.ascent
        descent = d.descent
    }

    /// Draws with the top-left corner at `origin`, in a context whose y axis points down (as
    /// SwiftUI's Canvas gives it).
    public func draw(in context: CGContext, at origin: CGPoint, color: NSColor) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + height)
        context.scaleBy(x: 1, y: -1)
        display.textColor = color
        display.position = CGPoint(x: 0, y: descent)
        // Fraction bars and root signs are NSBezierPaths, drawn into the current AppKit context.
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        display.draw(context)
        NSGraphicsContext.current = previous
        context.restoreGState()
    }
}
