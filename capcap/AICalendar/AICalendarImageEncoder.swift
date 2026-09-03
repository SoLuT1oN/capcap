import AppKit
import ImageIO
import UniformTypeIdentifiers

enum AICalendarImageEncodingError: Error, Equatable {
    case invalidImage
    case cannotCreateBitmap
    case cannotCreateJPEG
}

enum AICalendarImageEncoder {
    static let defaultQuality: CGFloat = 0.88
    static let maxPixelDimension = 2560

    static func jpegData(
        from image: NSImage,
        quality: CGFloat = defaultQuality,
        maxPixelDimension: Int = Self.maxPixelDimension
    ) throws -> Data {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard image.size.width > 0,
              image.size.height > 0,
              let source = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil),
              source.width > 0,
              source.height > 0 else {
            throw AICalendarImageEncodingError.invalidImage
        }

        let longestEdge = max(source.width, source.height)
        let limit = max(1, maxPixelDimension)
        let scale = min(1, CGFloat(limit) / CGFloat(longestEdge))
        let width = max(1, Int(round(CGFloat(source.width) * scale)))
        let height = max(1, Int(round(CGFloat(source.height) * scale)))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            throw AICalendarImageEncodingError.cannotCreateBitmap
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let resized = context.makeImage() else {
            throw AICalendarImageEncodingError.cannotCreateBitmap
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw AICalendarImageEncodingError.cannotCreateJPEG
        }

        let clampedQuality = min(max(quality, 0), 1)
        CGImageDestinationAddImage(
            destination,
            resized,
            [kCGImageDestinationLossyCompressionQuality: clampedQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw AICalendarImageEncodingError.cannotCreateJPEG
        }
        return output as Data
    }

    static func encode(
        image: NSImage,
        quality: CGFloat = defaultQuality,
        maxPixelDimension: Int = Self.maxPixelDimension
    ) throws -> Data {
        try jpegData(from: image, quality: quality, maxPixelDimension: maxPixelDimension)
    }

    static func dataURL(
        from image: NSImage,
        quality: CGFloat = defaultQuality,
        maxPixelDimension: Int = Self.maxPixelDimension
    ) throws -> String {
        let data = try jpegData(from: image, quality: quality, maxPixelDimension: maxPixelDimension)
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }
}
