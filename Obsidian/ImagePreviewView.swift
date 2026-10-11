import AppKit
import ImageIO
import SwiftUI

struct ImagePreview: View {
    private static let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 20
        cache.totalCostLimit = 256 * 1024 * 1024 // 256 MB of decoded pixels
        return cache
    }()

    /// A decoded bitmap plus the point size the file declares, so zoom math
    /// is unchanged even when the pixels were capped by the memory budget.
    struct DecodedImage: Sendable {
        let bitmap: CGImage
        let pointSize: CGSize

        var byteCount: Int { bitmap.bytesPerRow * bitmap.height }
    }

    /// Estimated decoded byte cost of an image, used as the NSCache cost so the
    /// totalCostLimit can evict large images rather than letting them accumulate.
    /// Derived from pixels, not points, so a 2x asset is charged for all of its bytes.
    private static func cacheCost(for image: NSImage) -> Int {
        let pixelCost = image.representations.map { representation -> Int in
            if let bitmap = representation as? NSBitmapImageRep { return bitmap.bytesPerRow * bitmap.pixelsHigh }
            return representation.pixelsWide * representation.pixelsHigh * 4
        }.max() ?? 0
        if pixelCost > 0 { return pixelCost }
        let size = image.size
        let bytes = size.width * size.height * 4
        return bytes.isFinite && bytes > 0 ? Int(min(bytes, CGFloat(Int.max))) : 1
    }

    let url: URL
    @State private var zoomScale: CGFloat = 1
    @State private var isShowingControls = false
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var image: NSImage?
    @State private var isLoadingImage = false
    @FocusState private var isControlsFocused: Bool

    var body: some View {
        Group {
            if let image {
                imageView(image)
            } else if isLoadingImage {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.18))
            } else {
                ContentUnavailableView(
                    "Image Unavailable",
                    systemImage: "photo",
                    description: Text("This image couldn't be loaded.")
                )
            }
        }
        .task(id: url) {
            await loadImage()
        }
        .onDisappear {
            controlsHideTask?.cancel()
        }
    }

    private var minimumZoomScale: CGFloat { 0.25 }
    private var maximumZoomScale: CGFloat { 4 }

    private func clampedZoom(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimumZoomScale), maximumZoomScale)
    }

    private func revealControls() {
        controlsHideTask?.cancel()
        isShowingControls = true
        scheduleControlsHide(after: .seconds(2))
    }

    private func scheduleControlsHide(after duration: Duration) {
        controlsHideTask?.cancel()
        // Keep the controls visible while a control has keyboard/VoiceOver focus so
        // keyboard-only and assistive-tech users can always reach them.
        guard !isControlsFocused else { return }
        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, !isControlsFocused else { return }
            isShowingControls = false
        }
    }

    private func imageView(_ image: NSImage) -> some View {
        ZoomableImageScrollView(image: image, accessibilityLabel: "Image: \(url.lastPathComponent)", zoomScale: $zoomScale)
            .padding(24)
            .overlay(alignment: .topTrailing) {
                zoomControls
                    .focused($isControlsFocused)
                    .padding(16)
                    .opacity(isShowingControls ? 1 : 0)
                    .offset(y: isShowingControls ? 0 : -6)
                    .animation(.easeInOut(duration: 0.18), value: isShowingControls)
                    // Keep controls hit-testable while focused so keyboard/VoiceOver
                    // users can activate them even during the hide animation.
                    .allowsHitTesting(isShowingControls || isControlsFocused)
                    .onChange(of: isControlsFocused) { _, focused in
                        if focused {
                            // Reveal (and keep revealed) as soon as focus lands here.
                            controlsHideTask?.cancel()
                            isShowingControls = true
                        } else {
                            scheduleControlsHide(after: .milliseconds(900))
                        }
                    }
            }
            .onHover { isHovering in
                if isHovering {
                    revealControls()
                } else {
                    scheduleControlsHide(after: .milliseconds(900))
                }
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    revealControls()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.18))
    }

    @MainActor
    private func loadImage() async {
        // The key tracks the file's identity, so an image edited on disk is
        // decoded again instead of served stale from the cache.
        let cacheKey = Self.cacheKey(for: url)
        if let cachedImage = Self.imageCache.object(forKey: cacheKey) {
            image = cachedImage
            isLoadingImage = false
            return
        }

        image = nil
        isLoadingImage = true

        // Decode off the main actor via a nonisolated async helper. Because it stays
        // within the current `.task(id:)`'s structured task tree, cancellation (a new
        // URL or onDisappear) propagates: the helper bails before/after the decode
        // instead of continuing for an image the user has already navigated away from.
        let decoded = await Self.decodeImage(at: url)
        guard !Task.isCancelled else { return }

        let loadedImage: NSImage?
        let cost: Int
        if let decoded {
            loadedImage = NSImage(cgImage: decoded.bitmap, size: decoded.pointSize)
            cost = decoded.byteCount
        } else {
            // ImageIO cannot decode every type the sidebar offers (for example SVG).
            let data = await Self.readImageData(at: url)
            guard !Task.isCancelled else { return }
            loadedImage = data.flatMap(NSImage.init(data:))
            cost = loadedImage.map(Self.cacheCost(for:)) ?? 0
        }
        if let loadedImage {
            Self.imageCache.setObject(loadedImage, forKey: cacheKey, cost: max(1, cost))
        }

        image = loadedImage
        isLoadingImage = false
    }

    /// Decoded bitmaps are kept at full resolution up to this many pixels
    /// (about 200 MB of RGBA), so zooming stays sharp for any normal photo.
    nonisolated static let decodedPixelBudget = 50_000_000

    /// The longest-edge cap that keeps a `width` x `height` decode within
    /// `pixelBudget`, or the full longest edge when it already fits.
    nonisolated static func maximumPixelSize(width: Int, height: Int, pixelBudget: Int) -> Int {
        let longest = max(width, height)
        guard width > 0, height > 0, pixelBudget > 0 else { return max(1, longest) }
        let pixels = Double(width) * Double(height)
        guard pixels > Double(pixelBudget) else { return longest }
        return max(1, Int((Double(longest) * (Double(pixelBudget) / pixels).squareRoot()).rounded(.down)))
    }

    private nonisolated static func cacheKey(for url: URL) -> NSString {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let size = values?.fileSize ?? 0
        return "\(url.absoluteString)|\(modified)|\(size)" as NSString
    }

    /// Decodes a still image fully (no deferred draw-time decode) off the main
    /// actor, downsampling only when it exceeds `pixelBudget`. Returns nil for
    /// animated or multi-frame files so `NSImage(data:)` keeps their frames.
    nonisolated static func decodeImage(at url: URL, pixelBudget: Int = ImagePreview.decodedPixelBudget) async -> DecodedImage? {
        guard !Task.isCancelled, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize(width: width, height: height, pixelBudget: pixelBudget)
        ]
        guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        guard !Task.isCancelled else { return nil }
        return DecodedImage(bitmap: bitmap, pointSize: pointSize(for: bitmap, properties: properties))
    }

    /// Mirrors `NSImage(data:)`: pixel dimensions scaled by the file's DPI,
    /// swapped when the EXIF orientation applied above rotated the bitmap.
    private nonisolated static func pointSize(for bitmap: CGImage, properties: [CFString: Any]) -> CGSize {
        func number(_ key: CFString) -> Double? { (properties[key] as? NSNumber)?.doubleValue }
        let pixelWidth = number(kCGImagePropertyPixelWidth) ?? Double(bitmap.width)
        let pixelHeight = number(kCGImagePropertyPixelHeight) ?? Double(bitmap.height)
        let dpiWidth = number(kCGImagePropertyDPIWidth) ?? 72
        let dpiHeight = number(kCGImagePropertyDPIHeight) ?? 72
        var size = CGSize(
            width: pixelWidth * 72 / (dpiWidth > 0 ? dpiWidth : 72),
            height: pixelHeight * 72 / (dpiHeight > 0 ? dpiHeight : 72)
        )
        if (number(kCGImagePropertyOrientation) ?? 1) >= 5 {
            size = CGSize(width: size.height, height: size.width)
        }
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            return CGSize(width: bitmap.width, height: bitmap.height)
        }
        return size
    }

    /// Reads a file's bytes off the main actor in a cancellation-aware manner. Kept
    /// `nonisolated` so awaiting it from `loadImage()` hops off `@MainActor` while
    /// remaining part of the calling `.task`'s structured tree.
    private nonisolated static func readImageData(at url: URL) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let bytes = try? Data(contentsOf: url, options: .mappedIfSafe)
        return Task.isCancelled ? nil : bytes
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button {
                revealControls()
                zoomScale = clampedZoom(zoomScale - 0.2)
            } label: {
                Image(systemName: "minus")
            }
            .help("Zoom Out")
            .accessibilityLabel("Zoom Out")
            .disabled(zoomScale <= minimumZoomScale)

            Text("\(Int(zoomScale * 100))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44)
                .accessibilityLabel("Current zoom")
                .accessibilityValue("\(Int(zoomScale * 100)) percent")

            Button {
                revealControls()
                zoomScale = clampedZoom(zoomScale + 0.2)
            } label: {
                Image(systemName: "plus")
            }
            .help("Zoom In")
            .accessibilityLabel("Zoom In")
            .disabled(zoomScale >= maximumZoomScale)

            Button("Reset") {
                revealControls()
                zoomScale = 1
            }
            .font(.caption)
            .help("Reset Zoom")
            .accessibilityLabel("Reset Zoom")
            .disabled(abs(zoomScale - 1) < 0.01)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }
}

// MARK: - Zoomable Image Scroll View

struct ZoomableImageScrollView: NSViewRepresentable {
    let image: NSImage
    var accessibilityLabel: String = ""
    @Binding var zoomScale: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomScale: $zoomScale)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 4
        scrollView.magnification = 1

        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        imageView.setAccessibilityElement(true)
        imageView.setAccessibilityRole(.image)
        if !accessibilityLabel.isEmpty {
            imageView.setAccessibilityLabel(accessibilityLabel)
        }

        let documentView = FlippedDocumentView(frame: CGRect(origin: .zero, size: image.size))
        documentView.addSubview(imageView)
        scrollView.documentView = documentView

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleLiveMagnify(_:)),
            name: NSScrollView.willStartLiveMagnifyNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleEndMagnify(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let documentView = scrollView.documentView,
              let imageView = documentView.subviews.first as? NSImageView else {
            return
        }

        if imageView.image != image {
            imageView.image = image
        }

        if !accessibilityLabel.isEmpty, imageView.accessibilityLabel() != accessibilityLabel {
            imageView.setAccessibilityLabel(accessibilityLabel)
        }

        if imageView.frame.size != image.size {
            imageView.frame = CGRect(origin: .zero, size: image.size)
        }

        if documentView.frame.size != image.size {
            documentView.frame = CGRect(origin: .zero, size: image.size)
        }

        let imageSize = image.size
        if context.coordinator.lastImageSize != imageSize {
            context.coordinator.lastImageSize = imageSize
            context.coordinator.didApplyInitialZoom = false
        }

        if !context.coordinator.didApplyInitialZoom {
            let visibleSize = scrollView.contentView.bounds.size
            if visibleSize.width > 0, visibleSize.height > 0 {
                let fittedScale = fittedZoomScale(for: imageSize, in: visibleSize)
                context.coordinator.didApplyInitialZoom = true
                if abs(zoomScale - fittedScale) > 0.001 {
                    // SwiftUI forbids mutating a binding while it is updating this
                    // view, so the coordinator publishes the fitted scale afterwards.
                    let coordinator = context.coordinator
                    Task { @MainActor in coordinator.setZoomScale(fittedScale) }
                }
                scrollView.setMagnification(
                    fittedScale,
                    centeredAt: CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY)
                )
                return
            }
        }

        if abs(scrollView.magnification - zoomScale) > 0.001 {
            scrollView.setMagnification(zoomScale, centeredAt: CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY))
        }
    }

    private func fittedZoomScale(for imageSize: CGSize, in visibleSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let widthScale = visibleSize.width / imageSize.width
        let heightScale = visibleSize.height / imageSize.height
        return min(max(min(widthScale, heightScale), 0.25), 1)
    }

    @MainActor
    final class Coordinator: NSObject {
        @Binding private var zoomScale: CGFloat
        var didApplyInitialZoom = false
        var lastImageSize = CGSize.zero

        init(zoomScale: Binding<CGFloat>) {
            _zoomScale = zoomScale
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc
        func handleEndMagnify(_ notification: Notification) {
            updateZoomScale(from: notification.object)
        }

        @objc
        func handleLiveMagnify(_ notification: Notification) {
            updateZoomScale(from: notification.object)
        }

        func setZoomScale(_ scale: CGFloat) {
            if abs(zoomScale - scale) > 0.001 {
                zoomScale = scale
            }
        }

        private func updateZoomScale(from object: Any?) {
            guard let scrollView = object as? NSScrollView else { return }
            setZoomScale(scrollView.magnification)
        }
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)

        guard let documentSize = documentView?.frame.size else {
            return constrained
        }

        if documentSize.width < proposedBounds.width {
            constrained.origin.x = -(proposedBounds.width - documentSize.width) / 2
        }

        if documentSize.height < proposedBounds.height {
            constrained.origin.y = -(proposedBounds.height - documentSize.height) / 2
        }

        return constrained
    }
}
