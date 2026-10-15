import AppKit
import CoreGraphics

/// Wraps `EditCanvasView` as a subview. When a beautify preset is set, the
/// container grows to `innerSize + 2·padding`, repositions the canvas at
/// `(padding, padding)`, and draws the gradient background + inner shadow +
/// base screenshot behind the canvas. Rotation and display scaling preserve
/// the canvas's logical bounds so tools, hit tests, and editable text retain
/// their document coordinates in every orientation.
final class BeautifyContainerView: NSView {
    private(set) weak var canvasView: EditCanvasView?
    private(set) var beautifyPreset: BeautifyPreset?

    /// Cached wallpaper image for the wallpaper preset.
    var wallpaperImage: NSImage?

    /// Controls the extra beautify shadow cast by the inner rounded card.
    private(set) var shadowEnabled: Bool = true

    /// Corner radius used for the beautify shadow silhouette. The canvas may
    /// use an image alpha mask instead of a fixed clip for clicked-window
    /// captures, but the shadow still needs a close window-shaped fallback.
    private var innerShadowCornerRadius: CGFloat = BeautifyRenderer.innerCornerRadius

    /// Insets the shadow source for clicked-window captures. This is much
    /// cheaper than extracting the exact window alpha and avoids corner bleed.
    private var innerShadowInset: CGFloat = 0

    private(set) var shadowSize: CGFloat = BeautifyRenderer.shadowSizeDefault

    var contentPadding: CGFloat {
        guard isBeautifyEnabled else { return 0 }
        return BeautifyRenderer.padding(forShadowSize: shadowSize, shadowEnabled: shadowEnabled)
    }

    var isBeautifyEnabled: Bool { beautifyPreset != nil }

    var innerImageSize: CGSize {
        canvasView?.orientedDisplaySize ?? .zero
    }

    var outerSize: CGSize { frame.size }

    init(canvasView: EditCanvasView) {
        self.canvasView = canvasView
        super.init(frame: NSRect(origin: .zero, size: canvasView.frame.size))
        addSubview(canvasView)
        canvasView.setFrameOrigin(.zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Let mouse events route normally to the canvas subview.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point)
    }

    override var isFlipped: Bool { false }

    // MARK: - Beautify API

    func setBeautify(preset: BeautifyPreset?) {
        beautifyPreset = preset
        // A beautify preset owns the area behind the canvas (gradient,
        // wallpaper, or its own checkerboard). In normal editing the canvas
        // supplies a stable transparency preview instead of exposing the
        // frozen desktop snapshot beneath it.
        canvasView?.drawsTransparencyBackdrop = preset == nil
        relayout()
        needsDisplay = true
    }

    func setShadowSize(_ size: CGFloat) {
        let size = BeautifyRenderer.normalizedShadowSize(size)
        guard shadowSize != size else { return }
        shadowSize = size
        relayout()
        needsDisplay = true
    }

    func setShadowEnabled(_ enabled: Bool) {
        guard shadowEnabled != enabled else { return }
        shadowEnabled = enabled
        relayout()
        needsDisplay = true
    }

    func setInnerShadowCornerRadius(_ radius: CGFloat) {
        innerShadowCornerRadius = radius
        needsDisplay = true
    }

    func setInnerShadowInset(_ inset: CGFloat) {
        innerShadowInset = inset
        needsDisplay = true
    }

    /// Called by the controller when the canvas's intrinsic size changes
    /// (selection resize or long-screenshot preview load).
    func canvasSizeDidChange() {
        if let canvasView {
            canvasView.setPresentationScale(canvasView.presentationScale)
        }
        relayout()
        needsDisplay = true
    }

    private func relayout() {
        guard let canvasView else { return }
        let inner = canvasView.orientedDisplaySize
        let p: CGFloat
        let newSize: CGSize
        if beautifyPreset != nil, inner.width > 0, inner.height > 0 {
            p = contentPadding
            newSize = CGSize(
                width: inner.width + 2 * p,
                height: inner.height + 2 * p
            )
        } else {
            p = 0
            newSize = inner
        }
        if frame.size != newSize {
            setFrameSize(newSize)
        }
        // frameRotation rotates around the frame origin. Locate the actual
        // rotated bounds before translating them into the inner card rect.
        let rotatedBounds = canvasView.convert(canvasView.bounds, to: self)
        let origin = NSPoint(
            x: canvasView.frame.origin.x + p - rotatedBounds.minX,
            y: canvasView.frame.origin.y + p - rotatedBounds.minY
        )
        if canvasView.frame.origin != origin {
            canvasView.setFrameOrigin(origin)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard
            let preset = beautifyPreset,
            let canvasView,
            let context = NSGraphicsContext.current?.cgContext
        else { return }

        let inner = canvasView.orientedDisplaySize
        guard inner.width > 0, inner.height > 0 else { return }

        let outerRect = CGRect(origin: .zero, size: bounds.size)
        let innerRect = canvasView.convert(canvasView.bounds, to: self)

        // 1. Background — transparent uses a checkerboard so empty padding
        // and rounded corners are visible; export stays pure alpha.
        if preset.isTransparent {
            BeautifyRenderer.drawCheckerboard(in: outerRect)
        } else if preset.isWallpaper, let wp = wallpaperImage {
            BeautifyRenderer.drawWallpaperBackground(in: outerRect, wallpaper: wp)
        } else {
            BeautifyRenderer.drawBackground(in: outerRect, preset: preset)
        }

        // 2. Soft shadow silhouette under the canvas's rounded rect
        if shadowEnabled {
            BeautifyRenderer.drawInnerShadow(
                innerRect: innerRect,
                cornerRadius: innerShadowCornerRadius,
                inset: innerShadowInset,
                shadowSize: shadowSize,
                context: context
            )
        }
    }
}
