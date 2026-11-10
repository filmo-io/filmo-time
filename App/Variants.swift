import AppKit
import CoreImage
import SwiftUI
import Vision

// MARK: - Variants
//
// Every card has art variants (another poster, a drawn version…) and finishes
// (holo, gold). They live inside the card, never as separate cards:
// repeats are what unlock them.

enum Art: String, Codable, CaseIterable, Comparable {
    case base, alt, alt2, scene

    static func < (a: Art, b: Art) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }

    var name: String {
        switch self {
        case .base: "Clásico"
        case .alt: "Alternativo"
        case .alt2: "Alternativo II"
        case .scene: "Escena mítica"
        }
    }

    /// How likely a repeat brings this art, among the ones still missing.
    var weight: Double {
        switch self {
        case .base: 0
        case .alt: 50
        case .alt2: 30
        case .scene: 20
        }
    }
}

enum Finish: String, Codable, CaseIterable, Comparable {
    case normal, holo, gold

    static func < (a: Finish, b: Finish) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }

    var name: String {
        switch self {
        case .normal: "Normal"
        case .holo: "Holográfica"
        case .gold: "Dorada"
        }
    }

    /// Chance of each card in a pack coming out with this finish.
    var chance: Double {
        switch self {
        case .normal: 0
        case .holo: 0.05
        case .gold: 0.003
        }
    }

    /// Repeats with a finish are worth more Tokens.
    var tokenFactor: Int { [1, 4, 25][Finish.allCases.firstIndex(of: self)!] }

    static func roll() -> Finish {
        let r = Double.random(in: 0..<1)
        if r < Finish.gold.chance { return .gold }
        if r < Finish.gold.chance + Finish.holo.chance { return .holo }
        return .normal
    }
}

/// Hand-picked extra art for a card: beautiful alternative posters and its most famous scene.
struct CardExtras {
    var alts: [String] = []
    var scene: String? = nil
    /// What is said in the scene, or how it is known.
    var sceneLine: String? = nil
}

extension CardDef {
    var extras: CardExtras { cardExtras[id] ?? CardExtras() }
    var quote: String? { cardQuotes[id] }

    /// Arts this card can have.
    var arts: [Art] {
        let e = extras
        return [.base] + (e.alts.count > 0 ? [.alt] : []) + (e.alts.count > 1 ? [.alt2] : []) + (e.scene != nil ? [.scene] : [])
    }

    /// Logos come with the app; snapshots run from the source folder.
    var bundledLogo: URL {
        Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "logos")
            ?? URL(fileURLWithPath: "Resources/logos/\(id).png")
    }

    func imageURL(_ a: Art) -> URL {
        let e = extras
        func tmdb(_ p: String) -> URL { URL(string: "https://image.tmdb.org/t/p/w780\(p)")! }
        switch a {
        case .alt where !e.alts.isEmpty: return tmdb(e.alts[0])
        case .alt2 where e.alts.count > 1: return tmdb(e.alts[1])
        case .scene where e.scene != nil: return tmdb(e.scene!)
        default:
            if case .logo = art { return bundledLogo }
            return art.url
        }
    }
}

/// Polished gold, light and dark bands, for borders and gold backgrounds.
let polishedGold: [Color] = [0x8A5A0C, 0xE0AE3C, 0xFFF3C4, 0xFFFFFF, 0xF0C75E, 0x9C6A14, 0xE8BC4F, 0xFFF0B5, 0xA4741A].map(hex)

/// Hand-made gold art for cards where the automatic cut-out falls short: card id → image URL.
let customGold: [String: String] = [:]

/// Posters whose automatic cut-out was reviewed one by one and looks clean: their gold keeps the
/// subject over gold foil. Every other poster, and every other art, gets the gold frame.
let goldCutouts: Set<String> = [
    "alien",
    "blancanieves",
    "casablanca",
    "chernobyl",
    "club-lucha",
    "como-conoci",
    "grease",
    "hombres-paco",
    "house",
    "kill-bill",
    "la-la-land",
    "mago-oz",
    "pretty-woman",
    "top-gun",
    "totoro",
]

// MARK: - Image effects

enum ArtEffects {
    private static let context = CIContext()

    /// Gold finish. Reviewed posters keep their subject over gold foil, with soft edges and a light
    /// shadow; the rest are set whole inside a wide gold frame.
    static func goldBackground(_ img: NSImage, id: String = "") -> NSImage? {
        guard let tiff = img.tiffRepresentation, let ci = CIImage(data: tiff),
              let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        guard goldCutouts.contains(id), let cut = goldCutout(ci, cg, force: true) else { return nil }
        return render(cut, ci.extent, img.size)
    }

    private static func render(_ out: CIImage, _ r: CGRect, _ size: NSSize) -> NSImage? {
        guard let result = context.createCGImage(out, from: r) else { return nil }
        return NSImage(cgImage: result, size: size)
    }

    /// The subject over gold foil; nil when the cut-out would cover too little or too much of the poster.
    static func goldCutout(_ ci: CIImage, _ cg: CGImage, force: Bool = false) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first,
              let maskBuffer = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) else { return nil }
        let raw = CIImage(cvPixelBuffer: maskBuffer)
        if !force {
            let avg = raw.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: raw.extent)])
            var px = [UInt8](repeating: 0, count: 4)
            context.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: nil)
            let coverage = Double(px[0]) / 255
            guard coverage > 0.12, coverage < 0.8 else { return nil }
        }
        let r = ci.extent
        let soft = raw.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r.width * 0.003]).cropped(to: r)
        // A soft shadow of the subject, a little down and to the right, so it sits on the gold.
        let shadowMask = raw.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r.width * 0.02])
            .transformed(by: CGAffineTransform(translationX: r.width * 0.012, y: -r.width * 0.018)).cropped(to: r)
        let foil = goldFoil(r)
        let shade = CIImage(color: CIColor(red: 0.25, green: 0.15, blue: 0.02, alpha: 0.55)).cropped(to: r)
        let shadowed = shade.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: foil, kCIInputMaskImageKey: shadowMask,
        ])
        return ci.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: shadowed, kCIInputMaskImageKey: soft,
        ])
    }

    /// The whole poster, untouched, inside a wide frame of gold foil.
    static func goldFrame(_ ci: CIImage) -> CIImage {
        let r = ci.extent
        let inset = r.width * 0.085
        let inner = r.insetBy(dx: inset, dy: inset * 1.0)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: inner.width / r.width, y: inner.height / r.height))
            .transformed(by: CGAffineTransform(translationX: inner.minX, y: inner.minY))
        // A thin dark line and a soft shadow where the poster meets the frame.
        let shadow = CIImage(color: CIColor(red: 0.2, green: 0.12, blue: 0.0, alpha: 0.5)).cropped(to: inner.insetBy(dx: -2, dy: -2))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r.width * 0.012])
        let bevel = CIImage(color: CIColor(red: 1, green: 0.95, blue: 0.75, alpha: 0.9)).cropped(to: inner.insetBy(dx: -3, dy: -3))
        let line = CIImage(color: CIColor(red: 0.35, green: 0.22, blue: 0.02)).cropped(to: inner.insetBy(dx: -1.5, dy: -1.5))
        return scaled.composited(over: line).composited(over: bevel.composited(over: shadow.composited(over: goldFoil(r)))).cropped(to: r)
    }

    /// Brushed gold: a diagonal gradient with a fine grain.
    static func goldFoil(_ r: CGRect) -> CIImage {
        // Polished gold: hard light and dark bands across the diagonal, like a mirror finish.
        let w = max(Int(r.width), 1), h = max(Int(r.height), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        let stops: [(CGFloat, UInt32)] = [(0, 0x8A5A0C), (0.18, 0xD9A532), (0.30, 0xFFF3C4), (0.36, 0xFFFFFF),
                                          (0.44, 0xF0C75E), (0.60, 0x9C6A14), (0.74, 0xE8BC4F), (0.84, 0xFFF0B5),
                                          (1, 0xA4741A)]
        let colors = stops.map { CGColor(srgbRed: CGFloat($0.1 >> 16 & 255) / 255, green: CGFloat($0.1 >> 8 & 255) / 255,
                                         blue: CGFloat($0.1 & 255) / 255, alpha: 1) } as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: stops.map(\.0))!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
        // A soft glow near the top, where the light falls.
        let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [CGColor(red: 1, green: 1, blue: 0.95, alpha: 0.35), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: CGFloat(w) * 0.35, y: CGFloat(h) * 0.8), startRadius: 0,
                               endCenter: CGPoint(x: CGFloat(w) * 0.35, y: CGFloat(h) * 0.8), endRadius: CGFloat(w) * 0.7, options: [])
        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: r.minX, y: r.minY))
    }

    /// Whether a logo is drawn mostly in light colours (a white logo), judged on its visible pixels.
    static func isLightLogo(_ img: NSImage) -> Bool {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let n = 64
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var light = 0, seen = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 128 {
            let a = Double(px[i + 3]) / 255
            let l = (0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])) / 255 / a
            seen += 1
            if l > 0.6 { light += 1 }
        }
        return seen > 0 && Double(light) / Double(seen) > 0.6
    }

    /// A logo without its empty margins. When it comes on a solid background, that colour is
    /// returned too, so the card can take it and the logo's box disappears.
    static func trimLogo(_ img: NSImage) -> (NSImage, NSColor?) {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return (img, nil) }
        let scale = min(1, 600 / Double(max(cg.width, cg.height)))
        let w = max(Int(Double(cg.width) * scale), 1), h = max(Int(Double(cg.height) * scale), 1)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (img, nil) }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func at(_ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
            let i = (y * w + x) * 4
            return (Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255, Double(px[i + 3]) / 255)
        }
        let corners = [at(0, 0), at(w - 1, 0), at(0, h - 1), at(w - 1, h - 1)]
        let transparent = corners.allSatisfy { $0.3 < 0.2 }
        let c0 = corners[0]
        let uniform = corners.allSatisfy { abs($0.0 - c0.0) + abs($0.1 - c0.1) + abs($0.2 - c0.2) < 0.3 && $0.3 > 0.9 }
        guard transparent || uniform else { return (img, nil) }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let p = at(x, y)
                let ink = transparent ? p.3 > 0.15 : abs(p.0 - c0.0) + abs(p.1 - c0.1) + abs(p.2 - c0.2) > 0.3
                if ink { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= minX, maxY >= minY else { return (img, nil) }
        let pad = Int(Double(max(maxX - minX, maxY - minY)) * 0.03)
        // CGContext rows start at the bottom; CGImage cropping counts from the top.
        let rect = CGRect(x: max(minX - pad, 0), y: max(h - 1 - maxY - pad, 0),
                          width: min(maxX - minX + 1 + 2 * pad, w), height: min(maxY - minY + 1 + 2 * pad, h))
        guard let full = ctx.makeImage(), let cropped = full.cropping(to: rect) else { return (img, nil) }
        let bg = transparent ? nil : NSColor(srgbRed: c0.0, green: c0.1, blue: c0.2, alpha: 1)
        return (NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height)), bg)
    }

    /// The average colour of an image, for the minimal art.
    static func average(_ img: NSImage) -> NSColor? {
        guard let tiff = img.tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
        let avg = ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)])
        var px = [UInt8](repeating: 0, count: 4)
        context.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }
}

// MARK: - Variant views

private extension Color {
    func mix(_ other: NSColor, _ f: Double) -> Color {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return Color(nsColor: c.blended(withFraction: f, of: other) ?? c)
    }
}

/// The finish drawn over the art.
struct FinishOverlay: View {
    let finish: Finish
    let width: CGFloat

    var body: some View {
        switch finish {
        case .normal: EmptyView()
        case .holo: HoloShine()
        case .gold: gold
        }
    }

    /// Gold is drawn by GoldFrame around the card; nothing on top here.
    private var gold: some View {
        Color.clear
        .allowsHitTesting(false)
    }
}
