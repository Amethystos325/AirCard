import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - Card View Component (Apple Wallet Style)

private enum CardFaceGeometry {
    static let width: CGFloat = 290
    static let height: CGFloat = 182
    static let corner: CGFloat = 18
}

private struct CardFaceArtwork: View {
    let image: NSImage
    let fitsInsideCard: Bool

    @ViewBuilder var body: some View {
        if fitsInsideCard {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.controlBackgroundColor))
        } else {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        }
    }
}

private struct CardFaceFinish: ViewModifier {
    let hasArtwork: Bool

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: CardFaceGeometry.corner, style: .continuous))
            .overlay {
                if hasArtwork {
                    LinearGradient(colors: [.white.opacity(0.14), .clear, .black.opacity(0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .clipShape(RoundedRectangle(cornerRadius: CardFaceGeometry.corner, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct CardFaceHover: ViewModifier {
    @State private var isHovered = false
    @State private var pointer: CGSize = .zero

    func body(content: Content) -> some View {
        let maxTilt = 9.0
        return content
            .contentShape(RoundedRectangle(cornerRadius: CardFaceGeometry.corner, style: .continuous))
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .rotation3DEffect(.degrees(Double(-pointer.height) * maxTilt),
                              axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(Double(pointer.width) * maxTilt),
                              axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .shadow(color: .black.opacity(isHovered ? 0.28 : 0.12),
                    radius: isHovered ? 16 : 6,
                    x: pointer.width * 10,
                    y: isHovered ? 10 - pointer.height * 10 : 3)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: pointer)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isHovered)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    isHovered = true
                    pointer = CGSize(width: location.x / CardFaceGeometry.width - 0.5,
                                     height: location.y / CardFaceGeometry.height - 0.5)
                case .ended:
                    isHovered = false
                    pointer = .zero
                }
            }
    }
}

/// A glossy highlight that sweeps diagonally across the card while artwork is read.
private struct CardSheen: View {
    private static let sweep = 1.8
    private static let pause = 0.6
    private static let samples = 48

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            LinearGradient(stops: Self.stops(center: reduceMotion ? 0.5 : Self.center(at: context.date)),
                           startPoint: UnitPoint(x: 0, y: 0.1), endPoint: UnitPoint(x: 1, y: 0.9))
                .blendMode(.plusLighter)
        }
    }

    /// Band position along the gradient axis; it starts and ends fully off the card.
    private static func center(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: sweep + pause)
        let progress = min(t / sweep, 1)
        let eased = progress * progress * (3 - 2 * progress)
        return -0.6 + eased * 2.2
    }

    /// Samples a wide diffuse glow plus a softer, brighter centre. Sampling the brightness curve, rather
    /// than moving a gradient-filled shape, leaves no hard edges anywhere on the card.
    private static func stops(center: Double) -> [Gradient.Stop] {
        (0...samples).map { index in
            let location = Double(index) / Double(samples)
            let distance = location - center
            let glow = 0.16 * exp(-pow(distance / 0.3, 2))
            let core = 0.1 * exp(-pow(distance / 0.1, 2))
            return .init(color: .white.opacity(glow + core), location: location)
        }
    }
}

/// macOS 26 toolbars give every item a glass capsule; earlier systems need one drawn.
private struct LegacyToolbarCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.background(.quaternary, in: Capsule())
        }
    }
}

/// Slot frames of the cards in a grid, in the grid's coordinate space.
private struct CardFramePreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Marks the transaction that reorders cards, so the dragged card can skip its slot animation.
private struct CardReorderTransactionKey: TransactionKey {
    static let defaultValue = false
}

private struct CardDragState {
    let key: String
    /// Pointer position within the card when the drag began.
    let grab: CGSize
    /// The slot the card currently occupies, updated as soon as it moves.
    var slot: CGRect
    var location: CGPoint

    var offset: CGSize {
        CGSize(width: location.x - grab.width - slot.minX, height: location.y - grab.height - slot.minY)
    }
}

/// Drag-to-reorder that moves the card itself: it lifts, follows the pointer, and the other
/// cards make room as soon as the pointer is over their slot. System drag and drop would
/// leave the original in place under a separate drag image.
private struct ReorderableCard: ViewModifier {
    static let space = "cardGrid"

    let key: String
    let frames: [String: CGRect]
    @Binding var drag: CardDragState?
    let move: (String, String) -> Void
    let onEnd: () -> Void

    func body(content: Content) -> some View {
        let isDragging = drag?.key == key
        content
            .scaleEffect(isDragging ? 1.04 : 1)
            .shadow(color: .black.opacity(isDragging ? 0.28 : 0), radius: isDragging ? 22 : 0, y: isDragging ? 14 : 0)
            .offset(isDragging ? drag?.offset ?? .zero : .zero)
            // Measured after the offset so the frame is the card's slot, not where it is drawn.
            .background(GeometryReader { proxy in
                Color.clear.preference(key: CardFramePreference.self,
                                       value: [key: proxy.frame(in: .named(Self.space))])
            })
            .zIndex(isDragging ? 1 : 0)
            // The dragged card tracks the pointer directly; only the others animate into place.
            .transaction { if isDragging && $0[CardReorderTransactionKey.self] { $0.animation = nil } }
            .simultaneousGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
                    .onChanged(changed)
                    .onEnded { _ in
                        onEnd()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { drag = nil }
                    }
            )
    }

    private func changed(_ value: DragGesture.Value) {
        if drag?.key != key {
            guard drag == nil, let slot = frames[key] else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                drag = CardDragState(key: key,
                                     grab: CGSize(width: value.startLocation.x - slot.minX,
                                                  height: value.startLocation.y - slot.minY),
                                     slot: slot, location: value.location)
            }
        }
        drag?.location = value.location
        guard let target = frames.first(where: { $0.key != key && $0.value.contains(value.location) }) else { return }
        // The dragged card takes over the target's slot; record it now so the card stays
        // under the pointer instead of waiting for the next layout pass to report it.
        drag?.slot = target.value
        var transaction = Transaction(animation: .snappy(duration: 0.3))
        transaction[CardReorderTransactionKey.self] = true
        withTransaction(transaction) { move(key, target.key) }
    }
}

struct WalletCardView: View {
    @Binding var card: CardItem
    let cardIndex: Int
    let language: String
    let onPickImage: () -> Void
    let onClearImage: () -> Void
    let onRead: () -> Void
    let onImageDropped: (URL) -> Void
    let onViewLarge: () -> Void
    let onDelete: () -> Void
    let readDisabled: Bool
    let isReading: Bool
    let imageChangeDisabled: Bool

    private static let cardCorner = CardFaceGeometry.corner
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }

    @State private var isTargeted = false

    private var displayImage: NSImage? { card.customImage ?? card.cachedArtwork }
    private var hasArt: Bool { displayImage != nil }
    private var componentName: String? {
        guard card.customImage == nil,
              let name = card.cachedAssetNames.first,
              !name.hasPrefix("cardBackgroundCombined") else { return nil }
        return name
    }

    var body: some View {
        VStack(spacing: 12) {
            cardVisual
            infoRow
            actionRow
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: Card artwork with holographic hover tilt

    private var cardVisual: some View {
        return ZStack {
            if let img = displayImage {
                CardFaceArtwork(image: img, fitsInsideCard: componentName != nil)
            } else {
                placeholder
            }
        }
        .frame(width: CardFaceGeometry.width, height: CardFaceGeometry.height)
        .modifier(CardFaceFinish(hasArtwork: hasArt))
        // Scanning shimmer while reading artwork from the device.
        .overlay { scanOverlay.allowsHitTesting(false) }
        .overlay(alignment: .bottomLeading) {
            if let componentName {
                Text("\(t("素材", "Asset")) · \(componentName)")
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
            }
        }
        .overlay(alignment: .topTrailing) { clearButton }
        .overlay { targetHighlight.allowsHitTesting(false) }
        .modifier(CardFaceHover())
        .animation(.easeInOut(duration: 0.25), value: isReading)
        .onTapGesture { if hasArt { onViewLarge() } }
        .help(hasArt ? t("点击查看大图", "Click to view artwork") : t("拖入图片或点击下方“更换卡面”", "Drop an image or click Change artwork"))
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.cardCorner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(NSColor.controlBackgroundColor),
                                 Color(NSColor.windowBackgroundColor).opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: Self.cardCorner, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 5])
                )
            VStack(alignment: .leading) {
                HStack {
                    Image(systemName: "wave.3.right")
                    Spacer()
                    Image(systemName: "creditcard")
                }
                .font(.system(size: 15))
                .foregroundStyle(.secondary.opacity(0.45))
                .padding(16)
                Spacer()
            }
            VStack(spacing: 8) {
                Image(systemName: isTargeted ? "photo.badge.plus" : "creditcard")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                Text(isTargeted ? t("松开以预览图片", "Release to preview") : t("尚未指定卡面", "No artwork selected"))
                    .font(.subheadline.weight(.medium))
                Text(t("拖入图片，或点击下方“更换卡面”", "Drop an image or click Change artwork"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var scanOverlay: some View {
        if isReading {
            ZStack {
                // Frost the card into a skeleton-style placeholder while loading.
                RoundedRectangle(cornerRadius: Self.cardCorner, style: .continuous)
                    .fill(.ultraThinMaterial)

                CardSheen()

                Label(t("读取中…", "Reading…"), systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.cardCorner, style: .continuous))
            .transition(.opacity)
        }
    }

    @ViewBuilder private var targetHighlight: some View {
        if isTargeted {
            RoundedRectangle(cornerRadius: Self.cardCorner, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 3)
        }
    }

    @ViewBuilder private var clearButton: some View {
        if card.customImage != nil {
            Button(action: onClearImage) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .buttonStyle(.plain)
            .padding(10)
            .help(t("移除已选卡面", "Remove selected artwork"))
        }
    }

    // MARK: Info row (index and hash)

    private var infoRow: some View {
        HStack(spacing: 8) {
            Text(card.label.isEmpty ? t("卡片 #\(cardIndex + 1)", "Card #\(cardIndex + 1)") : card.label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Text(card.id.prefix(7))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(t("从当前列表隐藏", "Hide from this list"))
        }
        .padding(.horizontal, 2)
    }

    // MARK: Action row

    private var actionRow: some View {
        HStack(spacing: 8) {
                Button(action: onPickImage) {
                    Label(card.customImage == nil ? t("更换卡面", "Change artwork") : t("重新选择", "Choose again"),
                          systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(imageChangeDisabled)
                .help(t("选择图片并预览后再应用", "Choose and preview before applying"))

                Button(action: onRead) {
                    Label(isReading ? t("读取中…", "Reading…") : t("读取卡面", "Read artwork"),
                          systemImage: isReading ? "hourglass" : "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(readDisabled)
                .help(t("从 iPhone 读取卡面并保存首次备份", "Read artwork and save the first backup"))

        }
        .controlSize(.regular)
    }

    // MARK: Helpers

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !imageChangeDisabled else { return false }
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var fileURL: URL?
                if let url = item as? URL {
                    fileURL = url
                } else if let data = item as? Data, let urlStr = String(data: data, encoding: .utf8), let url = URL(string: urlStr) {
                    fileURL = url
                }
                if let url = fileURL, NSImage(contentsOf: url) != nil {
                    Task { @MainActor in
                        onImageDropped(url)
                    }
                }
            }
            return true
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                if let url = item as? URL, NSImage(contentsOf: url) != nil {
                    Task { @MainActor in
                        onImageDropped(url)
                    }
                } else if let img = item as? NSImage {
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("aircard_drop_\(UUID().uuidString).png")
                    var saved = false
                    if let tiff = img.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff),
                       let pngData = rep.representation(using: .png, properties: [:]) {
                        saved = (try? pngData.write(to: tempURL)) != nil
                    }
                    if saved {
                        Task { @MainActor in
                            onImageDropped(tempURL)
                        }
                    }
                }
            }
            return true
        }
        return false
    }
}

// MARK: - Main UI View

private struct CachedArtworkPreview: Identifiable {
    let id = UUID()
    let image: NSImage
    let url: URL?
    let cardID: String
    let deviceKey: String
    let cardLabel: String

    var pixelSize: NSSize { image.pixelSize }
    var pixelSizeText: String { "\(Int(pixelSize.width)) × \(Int(pixelSize.height))" }
}

private extension NSImage {
    /// Pixel dimensions, independent of the DPI metadata that drives `size`.
    var pixelSize: NSSize {
        representations.first { $0.pixelsWide > 0 }
            .map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? size
    }
}

private final class CenteredArtworkClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return bounds }
        if documentView.frame.width < bounds.width {
            bounds.origin.x = (documentView.frame.width - bounds.width) / 2
        }
        if documentView.frame.height < bounds.height {
            bounds.origin.y = (documentView.frame.height - bounds.height) / 2
        }
        return bounds
    }
}

private final class ArtworkScrollView: NSScrollView {
    static let maxZoom: CGFloat = 8
    static let zoomStep: CGFloat = 1.25

    var onZoomChange: ((_ zoom: CGFloat, _ range: ClosedRange<CGFloat>, _ isFitted: Bool) -> Void)?
    private var isFitted = true
    private var fittedSize: NSSize = .zero
    private var panAnchor: NSPoint?

    private var fitZoom: CGFloat {
        guard let size = documentView?.frame.size, size.width > 0, size.height > 0 else { return 1 }
        // The clip view's frame is unaffected by magnification, unlike its bounds.
        let visible = contentView.frame.size
        return min(visible.width / size.width, visible.height / size.height)
    }

    private var canPan: Bool {
        guard let size = documentView?.frame.size else { return false }
        return size.width * magnification > contentView.frame.width + 0.5
            || size.height * magnification > contentView.frame.height + 0.5
    }

    func installGestures() {
        addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
    }

    override func layout() {
        super.layout()
        let size = contentView.frame.size
        guard size.width > 0, size.height > 0, size != fittedSize else { return }
        fittedSize = size
        // Allow zooming out past fit so the whole card can sit small in a large window.
        minMagnification = min(fitZoom, 1) / 4
        maxMagnification = max(Self.maxZoom, fitZoom)
        // Keep a fitted image fitted while the sheet resizes; otherwise just re-clamp.
        if isFitted { fitArtwork() } else { setArtworkZoom(magnification) }
    }

    func fitArtwork() {
        setMagnification(fitZoom, centeredAt: NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
        notifyZoomChange()
    }

    /// `point` is in clip-view (document) coordinates and stays fixed on screen.
    func setArtworkZoom(_ value: CGFloat, at point: NSPoint? = nil) {
        let clamped = min(max(value, minMagnification), maxMagnification)
        setMagnification(clamped, centeredAt: point ?? NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
        notifyZoomChange()
    }

    func zoom(by factor: CGFloat, at point: NSPoint? = nil) {
        setArtworkZoom(magnification * factor, at: point)
    }

    private func toggleZoom(at point: NSPoint) {
        if isFitted {
            let fit = fitZoom
            setArtworkZoom(fit < 1 ? 1 : fit * 2, at: point)
        } else {
            fitArtwork()
        }
    }

    private func notifyZoomChange() {
        isFitted = abs(magnification - fitZoom) < 0.005
        documentCursor = canPan ? .openHand : nil
        onZoomChange?(magnification, minMagnification...maxMagnification, isFitted)
    }

    override func scrollWheel(with event: NSEvent) {
        // Two-finger trackpad scrolling pans like every other macOS scroll view, so it
        // follows the system's natural-scrolling setting. A mouse wheel or ⌘-scroll zooms.
        guard !event.hasPreciseScrollingDeltas || event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let step = event.hasPreciseScrollingDeltas ? min(abs(delta), 30) * 0.006 : min(abs(delta), 4) * 0.1
        // Scrolling up zooms in, as in Maps and in browsers.
        zoom(by: delta > 0 ? 1 + step : 1 / (1 + step),
             at: contentView.convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        notifyZoomChange()
    }

    override func smartMagnify(with event: NSEvent) {
        toggleZoom(at: contentView.convert(event.locationInWindow, from: nil))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), flags.isDisjoint(with: [.control, .option]) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "=", "+": zoom(by: Self.zoomStep)
        case "-": zoom(by: 1 / Self.zoomStep)
        case "0": setArtworkZoom(1)
        case "9": fitArtwork()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        // Keep the document point grabbed on mouse-down under the pointer. Working in
        // clip-view coordinates avoids mixing the flipped scroll view with the unflipped
        // clip view, which used to invert vertical dragging.
        let point = contentView.convert(gesture.location(in: nil), from: nil)
        switch gesture.state {
        case .began:
            panAnchor = point
            NSCursor.closedHand.push()
        case .changed:
            guard let anchor = panAnchor else { return }
            var bounds = contentView.bounds
            bounds.origin.x += anchor.x - point.x
            bounds.origin.y += anchor.y - point.y
            contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
            reflectScrolledClipView(contentView)
        default:
            if panAnchor != nil { NSCursor.pop() }
            panAnchor = nil
        }
    }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        toggleZoom(at: contentView.convert(gesture.location(in: nil), from: nil))
    }
}

@MainActor
private final class ArtworkZoomController: ObservableObject {
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var range: ClosedRange<CGFloat> = 1...ArtworkScrollView.maxZoom
    @Published private(set) var isFitted = true
    weak var scrollView: ArtworkScrollView?

    var canZoomIn: Bool { zoom < range.upperBound - 0.001 }
    var canZoomOut: Bool { zoom > range.lowerBound + 0.001 }

    func update(zoom: CGFloat, range: ClosedRange<CGFloat>, isFitted: Bool) {
        self.zoom = zoom
        self.range = range
        self.isFitted = isFitted
    }

    func zoomIn() { scrollView?.zoom(by: ArtworkScrollView.zoomStep) }
    func zoomOut() { scrollView?.zoom(by: 1 / ArtworkScrollView.zoomStep) }
    func zoom(to value: CGFloat) { scrollView?.setArtworkZoom(value) }
    func fit() { scrollView?.fitArtwork() }
}

private struct ZoomableArtworkCanvas: NSViewRepresentable {
    let image: NSImage
    let controller: ArtworkZoomController

    func makeNSView(context: Context) -> ArtworkScrollView {
        let scrollView = ArtworkScrollView()
        scrollView.contentView = CenteredArtworkClipView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true

        // Size by pixels so 100% means actual pixels regardless of the file's DPI metadata.
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.pixelSize))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        scrollView.documentView = imageView
        scrollView.installGestures()
        scrollView.onZoomChange = { [weak controller] zoom, range, isFitted in
            DispatchQueue.main.async { controller?.update(zoom: zoom, range: range, isFitted: isFitted) }
        }
        controller.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: ArtworkScrollView, context: Context) {}
}

private struct CachedArtworkViewer: View {
    let item: CachedArtworkPreview
    @ObservedObject var vm: AppViewModel
    let exportBackup: () -> Void
    @StateObject private var zoom = ArtworkZoomController()

    private func t(_ zh: String, _ en: String) -> String { vm.t(zh, en) }
    private var backupAvailable: Bool {
        vm.cards.contains { $0.id == item.cardID && $0.deviceKey == item.deviceKey && $0.backup }
    }

    var body: some View {
        ZoomableArtworkCanvas(image: item.image, controller: zoom)
            .frame(minWidth: 480, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
            .toolbar { toolbarContent }
            .preferredColorScheme(vm.appearance == "light" ? .light : vm.appearance == "dark" ? .dark : nil)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: zoom.zoomOut) {
                Label(t("缩小", "Zoom Out"), systemImage: "minus.magnifyingglass")
            }
            .disabled(!zoom.canZoomOut)
            .help(t("缩小（⌘−）", "Zoom Out (⌘−)"))
            Button(action: zoom.zoomIn) {
                Label(t("放大", "Zoom In"), systemImage: "plus.magnifyingglass")
            }
            .disabled(!zoom.canZoomIn)
            .help(t("放大（⌘+）", "Zoom In (⌘+)"))
            Menu {
                Button(t("适应窗口", "Zoom to Fit"), action: zoom.fit)
                    .keyboardShortcut("9")
                    .disabled(zoom.isFitted)
                Button(t("实际大小", "Actual Size")) { zoom.zoom(to: 1) }
                    .keyboardShortcut("0")
                Divider()
                ForEach([0.25, 0.5, 2, 4] as [CGFloat], id: \.self) { value in
                    Button("\(Int(value * 100))%") { zoom.zoom(to: value) }
                }
            } label: {
                Text("\(Int((zoom.zoom * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 44)
            }
            .help(t("缩放比例。双指开合、滚轮或 ⌘ + 滚动缩放，拖动平移，双击切换适应窗口。",
                    "Zoom level. Pinch, use the scroll wheel or ⌘-scroll to zoom, drag to pan, double-click to toggle fit."))
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        if let url = item.url {
            ToolbarItem(placement: .primaryAction) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label(t("在访达中显示", "Show in Finder"), systemImage: "folder")
                }
                .help(t("在访达中显示", "Show in Finder"))
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: exportBackup) {
                Label(t("导出备份", "Export Backup"), systemImage: "square.and.arrow.up")
            }
            .disabled(!backupAvailable || vm.isExporting)
            .help(t("导出首次备份（ZIP）", "Export first backup (ZIP)"))
        }
    }
}

/// Opens each artwork preview in its own resizable window with standard window controls.
@MainActor
private final class ArtworkWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = ArtworkWindowPresenter()
    private var windows: [String: NSWindow] = [:]

    func show(_ item: CachedArtworkPreview, vm: AppViewModel, exportBackup: @escaping () -> Void) {
        let key = item.deviceKey + ":" + item.cardID
        let previous = windows[key]
        let controller = NSHostingController(rootView: CachedArtworkViewer(item: item, vm: vm, exportBackup: exportBackup))
        controller.sceneBridgingOptions = [.toolbars]
        controller.sizingOptions = [.minSize]
        // The window's title is bound to its content view controller's title.
        controller.title = item.cardLabel

        let window = NSWindow(contentViewController: controller)
        window.subtitle = vm.t("卡面素材 · \(item.pixelSizeText) 像素", "Card artwork · \(item.pixelSizeText) px")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = vm.appearance == "light" ? NSAppearance(named: .aqua)
            : vm.appearance == "dark" ? NSAppearance(named: .darkAqua) : nil
        window.setContentSize(Self.initialContentSize(for: item.pixelSize, on: NSApp.keyWindow?.screen ?? NSScreen.main))
        if let previous {
            // Reopening the same card replaces its window in place with the latest artwork.
            window.setFrame(previous.frame, display: false)
            previous.delegate = nil
            previous.close()
        } else if let parent = NSApp.keyWindow {
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2,
                                          y: parent.frame.midY - window.frame.height / 2))
        } else {
            window.center()
        }
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }

    private static func initialContentSize(for pixels: NSSize, on screen: NSScreen?) -> NSSize {
        let visible = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let aspect = pixels.height > 0 ? pixels.width / pixels.height : 1.6
        var width = min(1000, visible.width * 0.7)
        var height = width / aspect
        let maxHeight = visible.height * 0.75
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        return NSSize(width: max(width, 480), height: max(height, 320))
    }
}

private struct CardEditorSelection: Identifiable {
    let cardID: String
    let deviceKey: String
    var id: String { deviceKey + ":" + cardID }
}

private struct CardEditorView: View {
    @ObservedObject var vm: AppViewModel
    let cardID: String
    let deviceKey: String
    let chooseImage: () -> Void
    let exportBackup: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 1.0
    @State private var horizontal = 0.5
    @State private var vertical = 0.5
    @State private var preparing = false

    private var card: CardItem? { vm.cards.first { $0.id == cardID && $0.deviceKey == deviceKey } }
    private var source: NSImage? { card?.customImageURL.flatMap { NSImage(contentsOf: $0) } }
    private var ratio: Double {
        guard let source, source.size.height > 0 else { return 1536.0 / 969.0 }
        return Double(source.size.width / source.size.height)
    }
    private var crop: [String: Double] {
        let target = 1536.0 / 969.0
        let width = min(1, target / ratio) / zoom
        let height = min(1, ratio / target) / zoom
        return ["x": (1 - width) * horizontal, "y": (1 - height) * vertical,
                "width": width, "height": height]
    }
    private func resetPreview() { vm.invalidatePreparedImage(for: cardID, deviceKey: deviceKey) }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(card?.label.isEmpty == false ? card!.label : vm.t("卡片编辑", "Card artwork"))
                        .font(.title3.weight(.semibold))
                    Text(vm.t("选图只改变预览；满意后再应用到手机。", "Choosing an image only changes the preview. Apply when ready."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(vm.t("关闭", "Close")) { dismiss() }
            }
            HStack(alignment: .top, spacing: 20) {
                artworkPanel(vm.t("当前卡面", "Current artwork"), image: card?.cachedArtwork)
                artworkPanel(vm.t("新的卡面", "New artwork"), image: card?.customImage)
            }
            if source != nil {
                VStack(spacing: 10) {
                    control(vm.t("缩放", "Zoom"), value: $zoom, range: 1...3)
                    control(vm.t("水平位置", "Horizontal position"), value: $horizontal, range: 0...1)
                    control(vm.t("垂直位置", "Vertical position"), value: $vertical, range: 0...1)
                    HStack {
                        Spacer()
                        Button(vm.t(preparing ? "正在生成…" : card?.preparedImageID == nil ? "生成预览" : "预览已生成",
                                    preparing ? "Preparing…" : card?.preparedImageID == nil ? "Prepare preview" : "Preview ready")) {
                            preparing = true
                            Task {
                                do { try await vm.prepareImage(for: cardID, deviceKey: deviceKey, crop: crop) }
                                catch { vm.present(error) }
                                preparing = false
                            }
                        }
                        .disabled(preparing || vm.isFlashing)
                    }
                }
            }
            Divider()
            HStack {
                Label(vm.t("首次备份会在更换前保存并校验。", "The first backup is saved and verified before changing artwork."),
                      systemImage: "shield.checkered")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) {
                Button(vm.t("选择图片", "Choose image"), action: chooseImage)
                    .disabled(vm.isFlashing || vm.isReadingArtwork || preparing)
                Spacer()
                Button(vm.t("导出备份", "Export backup"), action: exportBackup)
                    .disabled(card?.backup != true || vm.isExporting)
                Button(vm.t("恢复首次备份", "Restore first backup")) {
                    vm.restoreFirstBackup(for: cardID)
                    dismiss()
                }
                .disabled(card?.backup != true || !vm.canOperate)
                Button(vm.t("应用卡面", "Apply artwork")) {
                    vm.applySkin(for: cardID)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(card?.preparedImageID == nil || !vm.canOperate || preparing)
            }
        }
        .padding(22)
        .frame(width: 700)
        .background(.regularMaterial)
    }

    private func artworkPanel(_ title: String, image: NSImage?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color(NSColor.controlBackgroundColor))
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: 290, height: 182).clipped()
                } else {
                    VStack(spacing: 7) {
                        Image(systemName: "creditcard").font(.title)
                        Text(vm.t("暂无卡面", "No artwork"))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 290, height: 182)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .frame(maxWidth: .infinity)
    }

    private func control(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 100, alignment: .leading)
            Slider(value: value, in: range) { editing in if !editing { resetPreview() } }
            Text(String(format: "%.0f%%", value.wrappedValue * 100))
                .font(.caption.monospacedDigit()).frame(width: 48, alignment: .trailing)
        }
    }
}

struct ContentView: View {
    private static let brandIcon = Bundle.main.image(forResource: "BrandIcon")
    @StateObject private var vm = AppViewModel()
    @AppStorage("aircard.mainViewMode") private var mainViewMode = "cards"
    @State private var editorSelection: CardEditorSelection?
    @State private var cardDrag: CardDragState?
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var lastCardDragEnd = Date.distantPast

    private func reorderable(_ index: Int) -> ReorderableCard {
        ReorderableCard(key: AppViewModel.orderKey(vm.cards[index]), frames: cardFrames, drag: $cardDrag,
                        move: { vm.moveCard($0, to: $1) },
                        onEnd: { lastCardDragEnd = Date() })
    }

    private var visibleCardIndices: [Int] {
        vm.ordered(vm.cards.indices.filter { index in
            (vm.device == nil || vm.cards[index].deviceKey == vm.device?.key)
                && !vm.hiddenCards.contains(vm.cards[index].deviceKey + ":" + vm.cards[index].id)
        })
    }

    private var galleryCardIndices: [Int] {
        visibleCardIndices.filter { vm.cards[$0].customImage != nil || vm.cards[$0].cachedArtwork != nil }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. Live Scanner Notice Banner (if active)
            if vm.isScanningCards {
                scanningNoticeBanner
                Divider()
            }
            if mainViewMode == "cards" {
                ForEach(vm.pending) { recovery in
                    recoveryBanner(recovery)
                    Divider()
                }
                ForEach(vm.unresolved.filter { !vm.hiddenRecoveryReminders.contains($0.id) }) { recovery in
                    unresolvedBanner(recovery)
                    Divider()
                }
                if vm.device != nil && vm.device?.compatible == false {
                    Text(vm.t("当前 iOS build 尚未验证，卡片操作已暂停。", "This iOS build is not verified. Card operations are paused."))
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 7)
                }
            }
            
            // 3. Main Workspace
            ScrollView {
                if mainViewMode == "gallery" {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 290, maximum: 360), spacing: 28)],
                        spacing: 28
                    ) {
                        ForEach(galleryCardIndices, id: \.self) { idx in
                            let card = vm.cards[idx]
                            if let image = card.customImage ?? card.cachedArtwork {
                                CardFaceArtwork(image: image,
                                                fitsInsideCard: card.customImage == nil &&
                                                    card.cachedAssetNames.first.map { !$0.hasPrefix("cardBackgroundCombined") } == true)
                                    .frame(width: CardFaceGeometry.width, height: CardFaceGeometry.height)
                                    .modifier(CardFaceFinish(hasArtwork: true))
                                    .modifier(CardFaceHover())
                                    .accessibilityLabel(card.label.isEmpty
                                                        ? vm.t("卡片 #\(idx + 1)", "Card #\(idx + 1)")
                                                        : card.label)
                                    .modifier(reorderable(idx))
                            }
                        }
                    }
                    .coordinateSpace(name: ReorderableCard.space)
                    .onPreferenceChange(CardFramePreference.self) { cardFrames = $0 }
                    .padding(28)
                } else if vm.visibleCards.isEmpty {
                    emptyStateView
                        .padding(.top, 40)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 330, maximum: 380), spacing: 20)],
                        spacing: 20
                    ) {
                        ForEach(visibleCardIndices, id: \.self) { idx in
                            let cardId = vm.cards[idx].id
                            let cardKey = vm.cards[idx].deviceKey
                            WalletCardView(
                                card: $vm.cards[idx],
                                cardIndex: idx,
                                language: vm.language,
                                onPickImage: { editorSelection = CardEditorSelection(cardID: cardId, deviceKey: cardKey) },
                                onClearImage: { vm.clearCardImage(for: cardId, deviceKey: cardKey) },
                                onRead: { vm.readCardArtwork(cardId) },
                                onImageDropped: { url in selectForPreview(url, for: cardId, deviceKey: cardKey) },
                                onViewLarge: {
                                    // A click that ends a reorder drag should not open the preview.
                                    guard Date().timeIntervalSince(lastCardDragEnd) > 0.3 else { return }
                                    if let image = vm.cards[idx].customImage ?? vm.cards[idx].cachedArtwork {
                                        let preview = CachedArtworkPreview(
                                            image: image, url: vm.cards[idx].customImageURL,
                                            cardID: cardId, deviceKey: cardKey,
                                            cardLabel: vm.cards[idx].label.isEmpty
                                                ? vm.t("卡片 #\(idx + 1)", "Card #\(idx + 1)")
                                                : vm.cards[idx].label)
                                        ArtworkWindowPresenter.shared.show(preview, vm: vm) {
                                            exportCardArtwork(for: cardId, deviceKey: cardKey)
                                        }
                                    }
                                },
                                onDelete: { vm.hideCard(cardId, deviceKey: cardKey) },
                                readDisabled: !vm.canOperate || vm.isExporting,
                                isReading: vm.readingCardID == cardId,
                                imageChangeDisabled: vm.isFlashing || vm.isExporting || vm.isReadingArtwork
                            )
                            .modifier(reorderable(idx))
                        }
                    }
                    .coordinateSpace(name: ReorderableCard.space)
                    .onPreferenceChange(CardFramePreference.self) { cardFrames = $0 }
                    .padding(20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // 4. Collapsible Activity Console (if open or flashing)
            if mainViewMode == "cards" && vm.showLogs {
                Divider()
                activityLogView
            }
            
            if mainViewMode == "cards" {
                Divider()
                // 5. Bottom Action & Status Bar
                bottomBarView
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
        }
        .frame(minWidth: 880, minHeight: 680)
        .navigationTitle(vm.t("百变卡片", "Ditto Card"))
        .toolbar { mainToolbar }
        .preferredColorScheme(vm.appearance == "light" ? .light : vm.appearance == "dark" ? .dark : nil)
        .alert(vm.t("操作完成", "Success"), isPresented: $vm.showSuccessAlert) {
            Button("OK") {}
        } message: {
            Text(vm.t("请重新打开 iPhone 上的 Wallet 检查卡面。", "Reopen Wallet on your iPhone to check the artwork."))
        }
        .alert("卡面操作", isPresented: Binding(
            get: { vm.exportMessage != nil },
            set: { if !$0 { vm.exportMessage = nil } }
        )) {
            Button("OK") { vm.exportMessage = nil }
        } message: {
            Text(vm.exportMessage ?? "")
        }
        .alert("操作失败", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .sheet(item: $editorSelection) { item in
            CardEditorView(vm: vm, cardID: item.cardID, deviceKey: item.deviceKey,
                           chooseImage: { openCardImagePicker(for: item.cardID, deviceKey: item.deviceKey) },
                           exportBackup: { exportCardArtwork(for: item.cardID, deviceKey: item.deviceKey) })
        }
    }
    
    // MARK: - Subviews
    
    // The same items stay in the toolbar for every view mode, and the view switcher is
    // the centered principal item, so switching tabs never moves any control.
    @ToolbarContentBuilder private var mainToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { brandTitle }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { brandTitle }
        }
        ToolbarItem(placement: .principal) { viewModePicker }
        ToolbarItem(placement: .primaryAction) { deviceStatus }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) { scanButton }
        ToolbarItem(placement: .primaryAction) { settingsMenu }
    }

    private var brandTitle: some View {
        HStack(spacing: 8) {
            if let icon = Self.brandIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
            Text(vm.t("百变卡片", "Ditto Card"))
                .font(.title3.weight(.semibold))
            Text("v0.2")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15))
                .foregroundColor(.accentColor)
                .clipShape(Capsule())
        }
        .fixedSize()
    }

    private var viewModePicker: some View {
        Picker(vm.t("视图", "View"), selection: $mainViewMode) {
            Label(vm.t("卡片", "Cards"), systemImage: "creditcard").tag("cards")
            Label(vm.t("画廊", "Gallery"), systemImage: "photo.on.rectangle.angled").tag("gallery")
        }
        .pickerStyle(.segmented)
        .labelStyle(.titleAndIcon)
        .labelsHidden()
        .fixedSize()
        .help(vm.t("切换视图", "Switch view"))
    }

    private var deviceStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(vm.device != nil ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            if let dev = vm.device {
                VStack(alignment: .leading, spacing: 0) {
                    Text(dev.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text("\(dev.product) · iOS \(dev.version)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text(vm.t("未连接 iPhone (USB)", "No iPhone (USB)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button(action: { vm.checkDevice() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(vm.isCheckingDevice)
            .help(vm.t("刷新设备连接", "Refresh device connection"))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .modifier(LegacyToolbarCapsule())
        .fixedSize()
    }

    private var scanButton: some View {
        Button(action: { vm.toggleCardScanning() }) {
            Label(vm.isScanningCards ? vm.t("停止扫描", "Stop Scanning") : vm.t("扫描卡片", "Scan Cards"),
                  systemImage: vm.isScanningCards ? "stop.circle.fill" : "wave.3.forward.circle.fill")
                .labelStyle(.titleAndIcon)
                .fontWeight(.semibold)
        }
        .buttonStyle(.borderedProminent)
        .tint(vm.isScanningCards ? .red : .accentColor)
        .disabled(!vm.isScanningCards && !vm.canOperate)
        .help(vm.isScanningCards ? vm.t("停止扫描安全元件卡", "Stop scanning secure element cards")
                                 : vm.t("在 iPhone 上轻点卡片以添加", "Tap cards on your iPhone to add them"))
    }

    private var settingsMenu: some View {
        Menu {
            Section(vm.t("语言", "Language")) {
                Picker(vm.t("语言", "Language"), selection: Binding(
                    get: { vm.language }, set: { vm.setLanguage($0) })) {
                    Text("简体中文").tag("zh")
                    Text("English").tag("en")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section(vm.t("外观", "Appearance")) {
                Picker(vm.t("外观", "Appearance"), selection: Binding(
                    get: { vm.appearance }, set: { vm.setAppearance($0) })) {
                    Label(vm.t("跟随系统", "System"), systemImage: "circle.lefthalf.filled").tag("system")
                    Label(vm.t("浅色", "Light"), systemImage: "sun.max").tag("light")
                    Label(vm.t("深色", "Dark"), systemImage: "moon").tag("dark")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            if vm.hiddenRecoveryReminderCount > 0 {
                Section(vm.t("恢复提醒", "Recovery reminders")) {
                    Button {
                        vm.showHiddenRecoveryReminders()
                    } label: {
                        Label(vm.t("显示已隐藏的提醒（\(vm.hiddenRecoveryReminderCount)）",
                                   "Show hidden reminders (\(vm.hiddenRecoveryReminderCount))"),
                              systemImage: "exclamationmark.shield")
                    }
                }
            }
        } label: {
            Label(vm.t("设置", "Settings"), systemImage: "gearshape")
        }
        .menuIndicator(.hidden)
        .help(vm.t("设置", "Settings"))
    }

    private var scanningNoticeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 20))
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.t("正在扫描安全元件卡", "Scanning secure element cards"))
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
                Text(vm.t("双击侧边键、完成 Face ID 后轻点银行卡或交通卡；普通通行证会被跳过。",
                          "Double-click the side button, authenticate, then tap a payment or transit card."))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(vm.t("完成", "Done")) {
                vm.stopCardScanning()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.1))
    }

    private func recoveryBanner(_ item: RecoveryItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.t("上次操作需要恢复", "A previous operation needs recovery"))
                    .font(.caption.weight(.semibold))
                Text(vm.t("连接同一台 iPhone，完成恢复后再更换卡面。",
                          "Reconnect the same iPhone and finish recovery before changing artwork."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(vm.t("继续恢复", "Continue recovery")) { vm.resumeRecovery(item) }
                .disabled(vm.isFlashing || vm.device?.key != item.deviceKey)
            if item.canIsolate {
                Button(vm.t("隔离此卡", "Isolate this card")) { vm.isolateRecovery(item) }
                    .disabled(vm.isFlashing || vm.device?.key != item.deviceKey)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    private func unresolvedBanner(_ item: RecoveryItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.t("卡片 \(String(item.card.prefix(7))) 的原文件位置仍未确认",
                          "Card \(String(item.card.prefix(7))) has an unverified original file"))
                    .font(.caption.weight(.semibold))
                Text(vm.t("已恢复 Books 并保留恢复资料；此卡暂停操作，其他卡可扫描。",
                          "Books was restored and recovery data retained. This card is paused; other cards can be scanned."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(vm.t("重新检查", "Check again")) { vm.resumeRecovery(item) }
                .disabled(vm.isFlashing || vm.device?.key != item.deviceKey)
            Button(vm.t("隐藏提醒", "Hide reminder")) { vm.hideRecoveryReminder(item) }
                .help(vm.t("仅隐藏此提醒；恢复资料和此卡的隔离状态会保留。",
                           "Only hides this reminder; recovery data and the card's isolation remain."))
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 18) {
            Image(systemName: "creditcard.viewfinder")
                .font(.system(size: 54))
                .foregroundColor(.accentColor.opacity(0.8))
            
            Text(vm.t("尚未检测到卡片", "No Cards Detected Yet"))
                .font(.title3)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text("1.")
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Text(vm.t("点击上方的“扫描卡片”。", "Click Scan Cards in the toolbar."))
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("2.")
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Text(vm.t("在 iPhone 上双击侧边键、验证身份，然后轻点卡片。",
                              "On your iPhone, double-click the side button, authenticate, and tap a card."))
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("3.")
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Text(vm.t("通过类型确认的卡片会显示在这里。", "Verified cards will appear here."))
                }
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            .frame(maxWidth: 460)
            .padding(20)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            
            Button(action: { vm.startCardScanning() }) {
                Label(vm.t("开始扫描", "Start Scanning"), systemImage: "wave.3.forward.circle.fill")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!vm.canOperate)
        }
        .padding(40)
    }
    
    private var activityLogView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(vm.t("操作记录", "Activity Log"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Button(vm.t("清空", "Clear")) {
                    vm.logs.removeAll()
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(vm.logs.enumerated()), id: \.offset) { idx, log in
                            Text(log)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .id(idx)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
                .frame(height: 90)
                .onChange(of: vm.logs.count) { _, _ in
                    if let last = vm.logs.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }
    
    private var bottomBarView: some View {
        VStack(spacing: 8) {
            if vm.isFlashing || vm.isReadingArtwork {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            
            HStack(spacing: 16) {
                // Left Status Text
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(vm.statusText)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                    }
                    
                    if !vm.visibleCards.isEmpty {
                        Text(vm.t("\(vm.visibleCards.count) 张卡片", "\(vm.visibleCards.count) cards"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                if !vm.hiddenCards.isEmpty {
                    Button(vm.t("显示已隐藏卡片", "Show hidden cards")) { vm.hiddenCards.removeAll() }
                        .buttonStyle(.bordered)
                }
                if vm.isFlashing || vm.isReadingArtwork {
                    Button(vm.t("完成当前步骤后停止", "Stop after current step")) { vm.cancelCurrentOperation() }
                        .buttonStyle(.bordered)
                }
                
                // Toggle Log Drawer
                Button(action: { withAnimation { vm.showLogs.toggle() } }) {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal")
                            .frame(width: 14, height: 14)
                        Text(vm.t("日志", "Log"))
                        Image(systemName: vm.showLogs ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                
            }
        }
    }
    
    // MARK: - Sheets & Pickers
    
    private func openCardImagePicker(for cardId: String, deviceKey: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = vm.t("选择卡面图片", "Choose card artwork")
        if panel.runModal() == .OK, let url = panel.url {
            selectForPreview(url, for: cardId, deviceKey: deviceKey)
        }
    }

    private func selectForPreview(_ url: URL, for cardId: String, deviceKey: String) {
        vm.selectImage(url, for: cardId, deviceKey: deviceKey)
        editorSelection = CardEditorSelection(cardID: cardId, deviceKey: deviceKey)
    }

    private func exportCardArtwork(for cardId: String, deviceKey: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "DittoCard-\(cardId.prefix(12)).zip"
        panel.message = vm.t("导出首次备份（PNG 与 PDF）为 ZIP。", "Export the first backup as a ZIP.")
        if panel.runModal() == .OK, let url = panel.url {
            vm.exportCachedArtwork(cardId, deviceKey: deviceKey, to: url)
        }
    }
    


}

// MARK: - App Entry Point

@main
struct AirCardApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentSize)
    }
}
