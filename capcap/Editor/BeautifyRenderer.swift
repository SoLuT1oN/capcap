import AppKit
import CoreGraphics
import ImageIO

enum BeautifyRenderer {
    // MARK: - Layout constants

    static let innerCornerRadius: CGFloat = 12
    // Ambient shadow (uniform glow around all edges)
    static let ambientShadowBlur: CGFloat = 24
    static let ambientShadowOpacity: CGFloat = 0.30
    static let ambientShadowOffset: CGSize = CGSize(width: 0, height: 0)
    // Key shadow (slight downward bias for natural depth)
    static let keyShadowBlur: CGFloat = 38
    static let keyShadowOpacity: CGFloat = 0.36
    static let keyShadowOffset: CGSize = CGSize(width: 0, height: -7)
    /// Window captures already carry the real system corner alpha. Their
    /// beautify shadow only needs to start slightly inside that edge so the
    /// light background does not peek through corner mismatches.
    static let windowInnerShadowInset: CGFloat = 5

    // MARK: - Beautify projection (independent of window-capture settings)
    static let shadowSizeMin: CGFloat = 0
    static let shadowSizeMax: CGFloat = 56
    static let shadowSizeDefault: CGFloat = 24

    private struct ShadowLayer {
        let blur: CGFloat
        let offset: CGSize
        let opacity: CGFloat
    }

    static func normalizedShadowSize(_ size: CGFloat) -> CGFloat {
        guard size.isFinite else { return shadowSizeDefault }
        return min(max(size, shadowSizeMin), shadowSizeMax)
    }

    private static func shadowLayers(for size: CGFloat) -> [ShadowLayer] {
        let scale = normalizedShadowSize(size) / shadowSizeDefault
        guard scale > 0 else { return [] }
        return [
            ShadowLayer(
                blur: ambientShadowBlur * scale,
                offset: CGSize(width: ambientShadowOffset.width * scale, height: ambientShadowOffset.height * scale),
                opacity: ambientShadowOpacity
            ),
            ShadowLayer(
                blur: keyShadowBlur * scale,
                offset: CGSize(width: keyShadowOffset.width * scale, height: keyShadowOffset.height * scale),
                opacity: keyShadowOpacity
            ),
        ]
    }

    /// Reserve the full drawing extent of both shadow layers. Preview and export
    /// use this same margin, including the offset and antialiasing fringe.
    static func padding(forShadowSize size: CGFloat, shadowEnabled: Bool) -> CGFloat {
        let size = normalizedShadowSize(size)
        guard shadowEnabled else { return size }
        let outset = shadowLayers(for: size).map {
            shadowOutset(blur: $0.blur, offset: $0.offset)
        }.max() ?? 0
        return max(size, ceil(outset))
    }

    // MARK: - Wallpaper

    /// Longest-edge pixel cap for the cached wallpaper bitmap. The raw desktop
    /// image is often a multi-frame "dynamic" HEIC well over 100 MB; that only
    /// ever fills the thin padding band, so a 2560 px copy is plenty.
    private static let wallpaperMaxEdge: CGFloat = 2560

    /// Decoded + downscaled wallpaper bitmaps, keyed by source file path.
    private static var wallpaperCache: [String: NSImage] = [:]
    private static var wallpaperLoadCallbacks: [String: [(NSImage?) -> Void]] = [:]
    private static let wallpaperCacheLock = NSLock()
    private static let wallpaperDecodeQueue = DispatchQueue(
        label: "capcap.beautify.wallpaper.decode",
        qos: .userInitiated
    )

    /// Loads the desktop wallpaper image for the given screen.
    ///
    /// The desktop image returned by `desktopImageURL` can be a dynamic HEIC
    /// containing many full-resolution frames. Decoding that synchronously —
    /// and re-decoding it on every swatch/preview redraw, since nothing was
    /// cached — froze the editor for several seconds on machines using the
    /// default macOS dynamic wallpaper. We instead decode a single downscaled
    /// thumbnail once (ImageIO never expands the full-size image) and cache it.
    static func wallpaperImage(for screen: NSScreen) -> NSImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return nil
        }
        return cachedOrLoadWallpaper(url: url)
    }

    /// Asynchronously loads the desktop wallpaper image for the given screen.
    /// Completion is always delivered on the main queue.
    static func loadWallpaperImage(for screen: NSScreen, completion: @escaping (NSImage?) -> Void) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            DispatchQueue.main.async {
                completion(nil)
            }
            return
        }

        if let cached = cachedWallpaper(url: url) {
            DispatchQueue.main.async {
                completion(cached)
            }
            return
        }

        let key = url.path
        wallpaperCacheLock.lock()
        if var callbacks = wallpaperLoadCallbacks[key] {
            callbacks.append(completion)
            wallpaperLoadCallbacks[key] = callbacks
            wallpaperCacheLock.unlock()
            return
        }
        wallpaperLoadCallbacks[key] = [completion]
        wallpaperCacheLock.unlock()

        wallpaperDecodeQueue.async {
            let image = autoreleasepool {
                downscaledWallpaper(url: url)
            }
            if let image {
                storeWallpaper(image, url: url)
            }

            wallpaperCacheLock.lock()
            let callbacks = wallpaperLoadCallbacks.removeValue(forKey: key) ?? []
            wallpaperCacheLock.unlock()

            DispatchQueue.main.async {
                callbacks.forEach { $0(image) }
            }
        }
    }

    private static func cachedOrLoadWallpaper(url: URL) -> NSImage? {
        if let cached = cachedWallpaper(url: url) {
            return cached
        }

        guard let image = downscaledWallpaper(url: url) else { return nil }
        storeWallpaper(image, url: url)
        return image
    }

    private static func cachedWallpaper(url: URL) -> NSImage? {
        let key = url.path
        wallpaperCacheLock.lock()
        let cached = wallpaperCache[key]
        wallpaperCacheLock.unlock()
        return cached
    }

    private static func storeWallpaper(_ image: NSImage, url: URL) {
        wallpaperCacheLock.lock()
        wallpaperCache[url.path] = image
        wallpaperCacheLock.unlock()
    }

    /// Decodes only the primary frame of `url`, downscaled so the longest edge
    /// is at most `wallpaperMaxEdge`. `CGImageSourceCreateThumbnailAtIndex`
    /// performs the scaling inside ImageIO, so a 100 MB+ dynamic wallpaper is
    /// never fully decoded into memory.
    private static func downscaledWallpaper(url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: wallpaperMaxEdge,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - Drawing primitives

    /// Quartz path clips have hard pixel edges. Rasterize a filled path instead
    /// so the clip carries fractional coverage at the destination's pixel scale.
    /// The live canvas retains this cache across annotation redraws.
    final class CornerMask {
        private var cachedSize: CGSize = .zero
        private var cachedRadius: CGFloat = -1
        private var cachedPixelWidth = 0
        private var cachedPixelHeight = 0
        private var cachedImage: CGImage?

        func clip(_ context: CGContext, to rect: CGRect, radius: CGFloat) {
            guard rect.width > 0, rect.height > 0 else { return }
            let transform = context.ctm
            let pixelWidth = max(1, Int(ceil(rect.width * hypot(transform.a, transform.b))))
            let pixelHeight = max(1, Int(ceil(rect.height * hypot(transform.c, transform.d))))
            let radius = max(0, min(radius, min(rect.width, rect.height) / 2))

            if cachedImage == nil || cachedSize != rect.size || cachedRadius != radius
                || cachedPixelWidth != pixelWidth || cachedPixelHeight != pixelHeight {
                guard let maskContext = CGContext(
                    data: nil,
                    width: pixelWidth,
                    height: pixelHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return }

                maskContext.setFillColor(gray: 0, alpha: 1)
                maskContext.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                maskContext.scaleBy(
                    x: CGFloat(pixelWidth) / rect.width,
                    y: CGFloat(pixelHeight) / rect.height
                )
                maskContext.setAllowsAntialiasing(true)
                maskContext.setShouldAntialias(true)
                maskContext.setFillColor(gray: 1, alpha: 1)
                maskContext.addPath(CGPath(
                    roundedRect: CGRect(origin: .zero, size: rect.size),
                    cornerWidth: radius,
                    cornerHeight: radius,
                    transform: nil
                ))
                maskContext.fillPath()
                guard let image = maskContext.makeImage() else { return }
                cachedImage = image
                cachedSize = rect.size
                cachedRadius = radius
                cachedPixelWidth = pixelWidth
                cachedPixelHeight = pixelHeight
            }

            if let cachedImage {
                context.clip(to: rect, mask: cachedImage)
            }
        }
    }

    /// Draws a linear gradient across `outerRect` using the preset colors and angle.
    /// Wallpaper and transparent presets leave the area empty (caller draws
    /// wallpaper / checkerboard separately for preview; export clears alpha).
    static func drawBackground(in outerRect: CGRect, preset: BeautifyPreset) {
        if preset.isWallpaper || preset.isTransparent { return }
        guard let gradient = NSGradient(starting: preset.startColor, ending: preset.endColor) else {
            preset.startColor.setFill()
            outerRect.fill()
            return
        }
        gradient.draw(in: outerRect, angle: preset.angleDegrees)
    }

    /// Checkerboard used only in the editor preview so transparent padding
    /// and rounded corners stay visible. Never baked into exported images.
    static func drawCheckerboard(in rect: CGRect, square: CGFloat = 14) {
        guard square > 0, rect.width > 0, rect.height > 0 else { return }
        var y = rect.minY
        var row = 0
        while y < rect.maxY {
            var x = rect.minX
            var column = 0
            while x < rect.maxX {
                let isLight = (row + column).isMultiple(of: 2)
                (isLight
                    ? NSColor(calibratedWhite: 0.88, alpha: 1)
                    : NSColor(calibratedWhite: 0.72, alpha: 1)
                ).setFill()
                NSRect(
                    x: x,
                    y: y,
                    width: min(square, rect.maxX - x),
                    height: min(square, rect.maxY - y)
                ).fill()
                x += square
                column += 1
            }
            y += square
            row += 1
        }
    }

    /// Draws a wallpaper image as background, aspect-fill centered in `outerRect`.
    static func drawWallpaperBackground(in outerRect: CGRect, wallpaper: NSImage) {
        let wpSize = wallpaper.size
        guard wpSize.width > 0, wpSize.height > 0 else { return }
        let scaleX = outerRect.width / wpSize.width
        let scaleY = outerRect.height / wpSize.height
        let scale = max(scaleX, scaleY)
        let drawSize = CGSize(width: wpSize.width * scale, height: wpSize.height * scale)
        let drawRect = CGRect(
            x: outerRect.origin.x + (outerRect.width - drawSize.width) / 2,
            y: outerRect.origin.y + (outerRect.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        wallpaper.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
    }

    /// Draws a two-layer shadow (ambient + key light) cast by a rounded-rect
    /// silhouette at `innerRect`, creating a natural floating-card effect.
    /// The fill used to cast the shadow is moved off-canvas, so transparent pixels
    /// in the screenshot reveal the beautify background instead of a black
    /// backing rectangle.
    static func drawInnerShadow(innerRect: CGRect, cornerRadius: CGFloat, context: CGContext) {
        drawInnerShadow(
            innerRect: innerRect,
            cornerRadius: cornerRadius,
            inset: 0,
            context: context
        )
    }

    static func drawInnerShadow(
        innerRect: CGRect,
        cornerRadius: CGFloat,
        inset: CGFloat,
        shadowSize: CGFloat = shadowSizeDefault,
        shadowBaseScale: CGSize = CGSize(width: 1, height: 1),
        context: CGContext
    ) {
        let shadowRect = innerRect.insetBy(dx: inset, dy: inset)
        guard shadowRect.width > 0, shadowRect.height > 0 else { return }
        let radius = max(0, cornerRadius - inset)
        let path = CGPath(
            roundedRect: shadowRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        for layer in shadowLayers(for: shadowSize) {
            drawShadowOnly(
                path: path,
                innerRect: shadowRect,
                offset: layer.offset,
                blur: layer.blur,
                opacity: layer.opacity,
                baseScale: shadowBaseScale,
                context: context
            )
        }
    }

    private static func drawShadowOnly(
        path: CGPath,
        innerRect: CGRect,
        offset: CGSize,
        blur: CGFloat,
        opacity: CGFloat,
        baseScale: CGSize,
        context: CGContext
    ) {
        let shadowOutset = shadowOutset(blur: blur, offset: offset)
        let clipRect = innerRect.insetBy(dx: -shadowOutset, dy: -shadowOutset)
        // Keep the opaque source entirely outside the visible clip, moving its
        // shadow back into place. An inverse path clip lets black source pixels
        // leak into the partially covered corner edge and produces a dark rim.
        let displacement = clipRect.width + shadowOutset
        var translation = CGAffineTransform(translationX: displacement, y: 0)
        guard let shadowSource = path.copy(using: &translation) else { return }

        context.saveGState()
        context.clip(to: clipRect)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.saveGState()
        // Quartz shadows use the context's base space, ignoring later CTM
        // scaling. The source path above is in user-space points. A raw bitmap
        // export scales those points into pixels, so its entire return offset
        // (including the off-canvas displacement) and blur must scale as well.
        // AppKit preview contexts already establish their own point base space.
        context.setShadow(
            offset: CGSize(
                width: (offset.width - displacement) * baseScale.width,
                height: offset.height * baseScale.height
            ),
            blur: blur * max(baseScale.width, baseScale.height),
            color: NSColor.black.withAlphaComponent(opacity).cgColor
        )
        context.addPath(shadowSource)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()

        // Remove the interior with antialiased coverage, preserving the hollow
        // shadow for transparent screenshots without introducing a hard clip.
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setBlendMode(.destinationOut)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func shadowOutset(blur: CGFloat, offset: CGSize) -> CGFloat {
        blur * 3 + max(abs(offset.width), abs(offset.height)) + 2
    }

    // MARK: - Full composite

    /// Automatically fits the projection unless an explicit margin is supplied
    /// by the pixel-based agent API, which owns its output dimensions and offsets.
    static func render(
        innerImage: NSImage,
        preset: BeautifyPreset,
        padding: CGFloat? = nil,
        wallpaperImage: NSImage? = nil,
        shadowEnabled: Bool = true,
        shadowSize: CGFloat = shadowSizeDefault,
        innerClipRadius: CGFloat? = BeautifyRenderer.innerCornerRadius,
        innerShadowCornerRadius: CGFloat = BeautifyRenderer.innerCornerRadius,
        innerShadowInset: CGFloat = 0
    ) -> NSImage {
        let innerSize = innerImage.size
        guard innerSize.width > 0, innerSize.height > 0 else { return innerImage }

        guard let source = innerImage.cgImagePreservingBacking() else { return innerImage }

        let padding = padding ?? self.padding(forShadowSize: shadowSize, shadowEnabled: shadowEnabled)

        // Sliders retain fractional points even when their labels show integers.
        // Align each margin to backing pixels and keep the screenshot's exact
        // pixel dimensions; rounding only the outer size resamples its contents.
        let scaleX = CGFloat(source.width) / innerSize.width
        let scaleY = CGFloat(source.height) / innerSize.height
        let paddingPixelsX = Int((max(0, padding) * scaleX).rounded())
        let paddingPixelsY = Int((max(0, padding) * scaleY).rounded())
        let pixelsWide = source.width + 2 * paddingPixelsX
        let pixelsHigh = source.height + 2 * paddingPixelsY
        let outer = CGSize(width: CGFloat(pixelsWide) / scaleX, height: CGFloat(pixelsHigh) / scaleY)
        let outerRect = CGRect(origin: .zero, size: outer)
        let inner = CGRect(
            x: CGFloat(paddingPixelsX) / scaleX,
            y: CGFloat(paddingPixelsY) / scaleY,
            width: innerSize.width,
            height: innerSize.height
        )

        guard let cg = CGContext(
            data: nil,
            width: pixelsWide,
            height: pixelsHigh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return innerImage }
        cg.scaleBy(x: scaleX, y: scaleY)
        let ctx = NSGraphicsContext(cgContext: cg, flipped: false)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high

        // 1. Background — transparent presets keep pure alpha (no desktop,
        // no wallpaper, no gradient). Checkerboard is preview-only.
        if preset.isTransparent {
            cg.clear(outerRect)
        } else if preset.isWallpaper, let wp = wallpaperImage {
            drawWallpaperBackground(in: outerRect, wallpaper: wp)
        } else {
            drawBackground(in: outerRect, preset: preset)
        }

        // 2. Soft shadow under the inner rounded rect
        if shadowEnabled {
            drawInnerShadow(
                innerRect: inner,
                cornerRadius: innerShadowCornerRadius,
                inset: innerShadowInset,
                shadowSize: shadowSize,
                shadowBaseScale: CGSize(width: scaleX, height: scaleY),
                context: cg
            )
        }

        // 3. Draw the image. Normal selections use the beautify card's fixed
        // rounded clip; clicked-window captures pass nil here because their
        // base image is already cut to the window's own alpha/rounded shape.
        cg.saveGState()
        if let innerClipRadius {
            CornerMask().clip(cg, to: inner, radius: innerClipRadius)
        }
        // Draw the original backing directly, without AppKit representation
        // selection or interpolation of text and single-pixel lines.
        cg.interpolationQuality = .none
        cg.draw(source, in: inner)
        cg.restoreGState()

        NSGraphicsContext.restoreGraphicsState()

        guard let rendered = cg.makeImage() else { return innerImage }
        let rep = NSBitmapImageRep(cgImage: rendered)
        rep.size = outer
        let image = NSImage(size: outer)
        image.addRepresentation(rep)
        return image
    }
}
