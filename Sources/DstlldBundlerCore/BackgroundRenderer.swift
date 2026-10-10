//
//  BackgroundRenderer.swift
//  DstlldBundlerCore
//
//  Draws the picture behind a disk image's window: a soft gradient in the app icon's colours, the
//  app's name, and a hand-drawn arrow from where the app sits to the Applications folder. Every
//  app gets its own picture with no design work. The drawing is a pure function of the name, the
//  palette and the scale, so the same app always gets the same picture.
//
//  The picture stays light because Finder draws the icons' labels in dark text.
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum BackgroundRenderer {
    /// The window's content size in points.
    public static let size = (width: 660, height: 400)
    /// The centres of the app's icon and the Applications folder's, from the top left.
    public static let appPosition = (x: 165, y: 205)
    public static let applicationsPosition = (x: 495, y: 205)
    public static let iconSize = 128
    public static let textSize = 13

    /// A colour, each component from 0 to 1.
    public struct Colour: Sendable, Equatable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// This colour moved `amount` of the way to `other`.
        func mixed(with other: Colour, _ amount: Double) -> Colour {
            Colour(
                red: red + (other.red - red) * amount,
                green: green + (other.green - green) * amount,
                blue: blue + (other.blue - blue) * amount)
        }

        var saturation: Double {
            let high = max(red, green, blue)
            let low = min(red, green, blue)
            return high == 0 ? 0 : (high - low) / high
        }

        /// Relative luminance, as WCAG defines it.
        var luminance: Double {
            func linear(_ component: Double) -> Double {
                component <= 0.039_28 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        func cgColor(alpha: Double = 1) -> CGColor {
            CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }

        static let white = Colour(red: 1, green: 1, blue: 1)
        static let black = Colour(red: 0, green: 0, blue: 0)
    }

    /// The two colours the picture is made from.
    public struct Palette: Sendable, Equatable {
        public var primary: Colour
        public var secondary: Colour

        public init(primary: Colour, secondary: Colour) {
            self.primary = primary
            self.secondary = secondary
        }

        /// A quiet blue and violet for apps without an icon.
        public static let neutral = Palette(
            primary: Colour(red: 0.30, green: 0.45, blue: 0.85), secondary: Colour(red: 0.55, green: 0.40, blue: 0.80))

        /// The icon's two most common colourful colours, found by k-means over its opaque pixels.
        public static func from(icon: CGImage) -> Palette {
            let pixels = samplePixels(icon, side: 40)
            let colourful = pixels.filter { $0.saturation > 0.18 }
            let clusters = kMeans(colourful.count >= 20 ? colourful : pixels, k: 4)
            let ranked = clusters.filter { $0.colour.saturation > 0.18 }.map(\.colour)
            switch ranked.count {
            case 0:
                return clusters.first.map { cluster in
                    Palette(primary: cluster.colour, secondary: cluster.colour.mixed(with: neutral.secondary, 0.5))
                } ?? neutral
            case 1:
                return Palette(primary: ranked[0], secondary: ranked[0].mixed(with: neutral.secondary, 0.4))
            default:
                return Palette(primary: ranked[0], secondary: ranked[1])
            }
        }

        static func samplePixels(_ image: CGImage, side: Int) -> [Colour] {
            var bytes = [UInt8](repeating: 0, count: side * side * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            guard drawn else { return [] }
            return stride(from: 0, to: bytes.count, by: 4).compactMap { index in
                let alpha = Double(bytes[index + 3]) / 255
                guard alpha > 0.8 else { return nil }
                return Colour(
                    red: Double(bytes[index]) / 255 / alpha, green: Double(bytes[index + 1]) / 255 / alpha,
                    blue: Double(bytes[index + 2]) / 255 / alpha)
            }
        }

        /// Clusters, largest first. Seeded from evenly spaced pixels in brightness order, so the
        /// result never varies.
        static func kMeans(_ colours: [Colour], k: Int) -> [(colour: Colour, count: Int)] {
            guard !colours.isEmpty else { return [] }
            let byBrightness = colours.sorted { $0.luminance < $1.luminance }
            var centres = (0..<k).map { byBrightness[($0 * 2 + 1) * byBrightness.count / (k * 2)] }
            var assignment = [Int](repeating: 0, count: colours.count)
            for _ in 0..<12 {
                for (index, colour) in colours.enumerated() {
                    assignment[index] = centres.indices.min { distance(colour, centres[$0]) < distance(colour, centres[$1]) } ?? 0
                }
                for centre in centres.indices {
                    let members = colours.indices.filter { assignment[$0] == centre }.map { colours[$0] }
                    guard !members.isEmpty else { continue }
                    let count = Double(members.count)
                    centres[centre] = Colour(
                        red: members.map(\.red).reduce(0, +) / count,
                        green: members.map(\.green).reduce(0, +) / count,
                        blue: members.map(\.blue).reduce(0, +) / count)
                }
            }
            return centres.indices
                .map { centre in (colour: centres[centre], count: assignment.filter { $0 == centre }.count) }
                .filter { $0.count > 0 }
                .sorted { $0.count > $1.count }
        }

        static func distance(_ left: Colour, _ right: Colour) -> Double {
            let red = left.red - right.red
            let green = left.green - right.green
            let blue = left.blue - right.blue
            return red * red + green * green + blue * blue
        }
    }

    /// The largest picture in an `.icns` or other image file.
    public static func largestImage(in file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return (0..<CGImageSourceGetCount(source))
            .compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
            .max { $0.width < $1.width }
    }

    // MARK: - Drawing

    /// The picture at `scale` (1 or 2) pixels per point.
    public static func render(name: String, palette: Palette, scale: Int) -> CGImage? {
        let width = size.width * scale
        let height = size.height * scale
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Draw in points from the top left, as Finder places icons.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))

        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let light = palette.primary.mixed(with: .white, 0.86)
        let lighter = palette.secondary.mixed(with: .white, 0.80)
        drawGradient(in: context, bounds: bounds, from: light, to: lighter)
        drawGlow(in: context, centre: CGPoint(x: 90, y: 40), radius: 320, colour: palette.primary, alpha: 0.22)
        drawGlow(in: context, centre: CGPoint(x: 600, y: 390), radius: 300, colour: palette.secondary, alpha: 0.20)
        drawGrain(in: context, bounds: bounds, scale: scale)

        let ink = readableInk(on: light, from: palette.primary)
        drawText(name, in: context, size: 30, bold: true, colour: ink, alpha: 1, centreX: bounds.midX, baseline: 78)
        drawArrow(in: context, colour: ink)
        // Under the arrow, not along the bottom: Finder's path bar, a setting of the whole Finder
        // that a .DS_Store cannot turn off, covers the bottom of the window.
        drawText(
            "Drag to Applications", in: context, size: 13, bold: false, colour: ink, alpha: 0.75,
            centreX: CGFloat(appPosition.x + applicationsPosition.x) / 2, baseline: 262)
        return context.makeImage()
    }

    /// The darkest version of `colour` needed to read well on `background`: WCAG's 4.5 to 1.
    static func readableInk(on background: Colour, from colour: Colour) -> Colour {
        var ink = colour
        var darkening = 0.0
        while contrast(ink, background) < 4.5, darkening < 1 {
            darkening += 0.05
            ink = colour.mixed(with: .black, darkening)
        }
        return ink
    }

    static func contrast(_ left: Colour, _ right: Colour) -> Double {
        let lighter = max(left.luminance, right.luminance)
        let darker = min(left.luminance, right.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func drawGradient(in context: CGContext, bounds: CGRect, from start: Colour, to end: Colour) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [start.cgColor(), end.cgColor()] as CFArray, locations: [0, 1])
        else { return }
        context.drawLinearGradient(
            gradient, start: CGPoint(x: bounds.minX, y: bounds.minY), end: CGPoint(x: bounds.maxX, y: bounds.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func drawGlow(in context: CGContext, centre: CGPoint, radius: CGFloat, colour: Colour, alpha: Double) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [colour.cgColor(alpha: alpha), colour.cgColor(alpha: 0)] as CFArray, locations: [0, 1])
        else { return }
        context.drawRadialGradient(
            gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [])
    }

    /// A faint, fixed speckle, so the gradient doesn't band.
    private static func drawGrain(in context: CGContext, bounds: CGRect, scale: Int) {
        var random = SplitMix(seed: 0x0D57_11D)
        let dot = 1 / CGFloat(scale)
        let count = Int(bounds.width * bounds.height) * scale * scale / 5
        for _ in 0..<count {
            let x = CGFloat(random.next() % UInt64(bounds.width * CGFloat(scale))) * dot
            let y = CGFloat(random.next() % UInt64(bounds.height * CGFloat(scale))) * dot
            let isLight = random.next() % 2 == 0
            context.setFillColor(gray: isLight ? 1 : 0, alpha: isLight ? 0.05 : 0.025)
            context.fill(CGRect(x: x, y: y, width: dot, height: dot))
        }
    }

    /// A loose arc over the gap between the two icons, drawn twice a hair apart so it looks inked
    /// rather than ruled.
    private static func drawArrow(in context: CGContext, colour: Colour) {
        let start = CGPoint(x: CGFloat(appPosition.x) + 88, y: CGFloat(appPosition.y) + 6)
        let end = CGPoint(x: CGFloat(applicationsPosition.x) - 92, y: CGFloat(applicationsPosition.y) - 2)
        let control1 = CGPoint(x: start.x + 36, y: start.y - 70)
        let control2 = CGPoint(x: end.x - 70, y: end.y - 34)

        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(colour.cgColor(alpha: 0.8))
        for (offset, width) in [(CGFloat(0), CGFloat(5)), (CGFloat(1.2), CGFloat(2.2))] {
            context.setLineWidth(width)
            context.move(to: CGPoint(x: start.x, y: start.y + offset))
            context.addCurve(
                to: CGPoint(x: end.x, y: end.y + offset * 0.5),
                control1: CGPoint(x: control1.x, y: control1.y + offset * 2),
                control2: CGPoint(x: control2.x, y: control2.y - offset))
            context.strokePath()
        }
        // The head follows the curve's last tangent.
        let angle = atan2(end.y - control2.y, end.x - control2.x)
        let length: CGFloat = 22
        context.setLineWidth(5)
        for spread in [CGFloat.pi * 0.83, -CGFloat.pi * 0.80] {
            context.move(to: end)
            context.addLine(to: CGPoint(x: end.x + cos(angle + spread) * length, y: end.y + sin(angle + spread) * length))
        }
        context.strokePath()
        context.restoreGState()
    }

    private static func drawText(
        _ text: String, in context: CGContext, size: CGFloat, bold: Bool, colour: Colour, alpha: Double,
        centreX: CGFloat, baseline: CGFloat
    ) {
        var font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        if bold, let heavier = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) {
            font = heavier
        }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: colour.cgColor(alpha: alpha),
            kCTKernAttributeName: bold ? -0.4 : 0.2,
        ]
        guard let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(string)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.saveGState()
        // Core Text draws upright in a y-up space, so undo the flip around the baseline.
        context.textMatrix = .identity
        context.translateBy(x: centreX - CGFloat(width) / 2, y: baseline)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: - Writing

    /// Writes the 1× and 2× pictures as one TIFF, which Finder shows at the screen's resolution.
    public static func writeTIFF(oneX: CGImage, twoX: CGImage?, to file: URL) throws(BundlerError) {
        let images = [(oneX, 72)] + (twoX.map { [($0, 144)] } ?? [])
        guard let destination = CGImageDestinationCreateWithURL(
            file as CFURL, UTType.tiff.identifier as CFString, images.count, nil)
        else { throw BundlerError("could not write the disk image's background") }
        for (image, dpi) in images {
            let properties: [CFString: Any] = [
                kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5],  // LZW
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw BundlerError("could not write the disk image's background")
        }
    }

    /// Reads a project's own background, `background.png` and optionally `background@2x.png`.
    public static func loadOverride(in directory: URL) -> (oneX: CGImage, twoX: CGImage?)? {
        let oneX = directory.appending(path: "background.png")
        let twoX = directory.appending(path: "background@2x.png")
        guard let image = largestImage(in: oneX) else { return nil }
        return (image, largestImage(in: twoX))
    }
}

/// A small, fast, seeded random number generator, so the grain is the same every time.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
