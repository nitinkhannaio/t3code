import AppKit

/// Decoded provider icons, keyed by driver kind and card appearance. The PNGs are compiled into the binary
/// (ProviderIconData); nothing is read from disk or the network. At most ProviderDriver.allCases.count * 2 images
/// are ever held, decoded on first use and kept for the process lifetime.
@MainActor
enum ProviderIconImages {
    private struct Key: Hashable {
        let driver: ProviderDriver
        let appearance: CardAppearance
    }

    private static var cache: [Key: NSImage] = [:]
    static let capacity = ProviderDriver.allCases.count * 2
    static var cachedCount: Int { cache.count }

    /// Square image sized to `points`; the 32 px bitmap keeps the exported aspect (letterboxed by the exporter) and
    /// its own colours. Not a template, so it is never tinted. Nil only if the bundled data is missing or invalid.
    static func image(for driver: ProviderDriver, appearance: CardAppearance, points: CGFloat = CardMetrics.iconSize) -> NSImage? {
        let key = Key(driver: driver, appearance: appearance)
        if let hit = cache[key] { return sized(hit, points) }
        guard cache.count < capacity,
              let pair = ProviderIconData.pngBase64[driver.rawValue],
              let data = Data(base64Encoded: appearance == .dark ? pair.dark : pair.light),
              let rep = NSBitmapImageRep(data: data),
              rep.pixelsWide == ProviderIconData.pixelSize, rep.pixelsHigh == ProviderIconData.pixelSize else { return nil }
        let image = NSImage(size: CGSize(width: points, height: points))
        image.addRepresentation(rep)
        image.isTemplate = false
        image.accessibilityDescription = driver.displayName
        cache[key] = image
        return sized(image, points)
    }

    private static func sized(_ image: NSImage, _ points: CGFloat) -> NSImage {
        if image.size == CGSize(width: points, height: points) { return image }
        let copy = image.copy() as! NSImage
        copy.size = CGSize(width: points, height: points)
        return copy
    }
}
