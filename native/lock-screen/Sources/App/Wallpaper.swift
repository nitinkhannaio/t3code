import AppKit
import ImageIO

/// Picks the glass variant from the desktop picture behind the card (NSWorkspace's public wallpaper URL and options,
/// so no screen-recording permission). Any failure (no URL, a folder, an undecodable or dynamic image) reads as dark.
@MainActor
final class WallpaperSampler {
    /// What decides the pixels and how they are drawn; a replaced file at the same path has a new date.
    private struct Source: Equatable {
        let url: URL
        let modified: Date?
        let placement: WallpaperTone.Placement
        let fillLuminance: Double
        let backingScale: CGFloat
    }

    private struct Key: Equatable {
        let card: CGRect
        let screen: CGRect
        let source: Source?
    }

    private var lastKey: Key?
    /// The decoded thumbnail and the image's size in points (for native-size placements).
    private var cached: (source: Source, image: CGImage, points: CGSize)?

    /// Nil when nothing changed since the last call (same card rect, screen, wallpaper file and options); else the
    /// variant and the sampled luminance (nil on failure).
    func evaluate(card: CGRect, screen: NSScreen) -> (appearance: CardAppearance, luminance: Double?)? {
        let source = Self.source(for: screen)
        let key = Key(card: card, screen: screen.frame, source: source)
        guard key != lastKey else { return nil }
        lastKey = key
        guard let source, let decoded = decode(source),
              let sample = WallpaperTone.sample(card: card, screen: screen.frame, image: decoded.points, placement: source.placement) else {
            return (.dark, nil)
        }
        let size = CGSize(width: decoded.image.width, height: decoded.image.height)
        var imageLuminance: Double?
        if let unit = sample.imageRect {
            let rect = CGRect(x: unit.minX * size.width, y: unit.minY * size.height, width: unit.width * size.width, height: unit.height * size.height)
            imageLuminance = Self.luminance(of: decoded.image, in: rect)
        }
        let luminance = WallpaperTone.blend(image: imageLuminance, fill: source.fillLuminance, coverage: sample.coverage)
        return (WallpaperTone.appearance(luminance: luminance), luminance)
    }

    /// Screen configuration or wallpaper changed: re-read everything on the next call.
    func invalidate() {
        lastKey = nil
        cached = nil
    }

    private static func source(for screen: NSScreen) -> Source? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) } ?? .scaleProportionallyUpOrDown
        let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        let placement: WallpaperTone.Placement = switch scaling {
        case .scaleAxesIndependently: .stretch
        case .scaleNone: .center
        case .scaleProportionallyDown: .shrinkToFit
        default: clipping ? .fill : .fit
        }
        // No fill colour reads as black, the conservative (dark) side.
        let fill = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB)
        let fillLuminance = fill.map { WallpaperTone.relativeLuminance(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent) } ?? 0
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return Source(url: url, modified: modified, placement: placement, fillLuminance: fillLuminance, backingScale: screen.backingScaleFactor)
    }

    /// Decoded once per source, as a thumbnail no larger than 512 px.
    private func decode(_ source: Source) -> (image: CGImage, points: CGSize)? {
        if let cached, cached.source == source { return (cached.image, cached.points) }
        guard let file = CGImageSourceCreateWithURL(source.url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(file, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512,
              ] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        // The thumbnail carries the oriented aspect; the file carries the native size.
        let native = CGFloat(max(pixelWidth, pixelHeight)) / CGFloat(max(image.width, image.height)) / max(source.backingScale, 1)
        let points = CGSize(width: CGFloat(image.width) * native, height: CGFloat(image.height) * native)
        cached = (source, image, points)
        return (image, points)
    }

    /// Mean relative luminance of `rect` (image pixels, y down), averaged over a 16x16 sRGB downsample.
    static func luminance(of image: CGImage, in rect: CGRect) -> Double? {
        guard let crop = image.cropping(to: rect.integral), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? WallpaperTone.averageLuminance(rgba: pixels) : nil
    }
}
