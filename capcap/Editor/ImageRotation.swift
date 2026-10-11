import AppKit

/// Quarter turns in the document's unflipped, bottom-left coordinate system.
/// The source image and annotations stay in this coordinate system while the
/// view hierarchy handles conversion of pointer events into document points.
enum ImageRotation: Int {
    case none, left, upsideDown, right

    var degrees: CGFloat { CGFloat(rawValue) * 90 }

    func turned(clockwise: Bool) -> ImageRotation {
        ImageRotation(rawValue: (rawValue + (clockwise ? 3 : 1)) % 4)!
    }

    func orientedSize(_ size: NSSize) -> NSSize {
        rawValue.isMultiple(of: 2) ? size : NSSize(width: size.height, height: size.width)
    }

    func transform(for size: NSSize) -> CGAffineTransform {
        switch self {
        case .none: return .identity
        case .left: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
        case .upsideDown: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height)
        case .right: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
        }
    }

    func documentDelta(fromDisplay delta: NSPoint) -> NSPoint {
        let inverse = transform(for: .zero).inverted()
        return delta.applying(inverse)
    }

    /// Rasterization happens only at an output boundary, at the source pixel
    /// dimensions. Editing never replaces the independent annotation layers.
    func render(_ image: NSImage) -> NSImage? {
        guard self != .none else { return image }
        guard let source = image.cgImagePreservingBacking() else { return nil }
        let pixelSize = orientedSize(NSSize(width: source.width, height: source.height))
        let outputSize = orientedSize(image.size)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = outputSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .none
        graphics.cgContext.concatenate(transform(for: image.size))
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1)
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: outputSize)
        result.addRepresentation(bitmap)
        return result
    }
}
