import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - Card View Component (Apple Wallet Style)

struct WalletCardView: View {
    @Binding var card: CardItem
    let cardIndex: Int
    let language: String
    let onPickImage: () -> Void
    let onClearImage: () -> Void
    let onRead: () -> Void
    let onExport: () -> Void
    let onImageDropped: (URL) -> Void
    let onViewLarge: () -> Void
    let onDelete: () -> Void
    let readDisabled: Bool
    let isReading: Bool
    let isExporting: Bool
    let imageChangeDisabled: Bool

    private static let cardCorner: CGFloat = 18
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }

    @State private var isHovered = false
    @State private var isTargeted = false
    @State private var copied = false
    // Normalized pointer position within the card (-0.5 ... 0.5) for the tilt.
    @State private var pointer: CGSize = .zero
    // Drives the sweeping scan shimmer while reading (-1 ... 1).
    @State private var scanX: CGFloat = -1

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
        let maxTilt = 9.0
        return ZStack {
            if let img = displayImage {
                if componentName != nil {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(NSColor.controlBackgroundColor))
                } else {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                }
            } else {
                placeholder
            }
        }
        .frame(width: 290, height: 182)
        .clipShape(RoundedRectangle(cornerRadius: Self.cardCorner, style: .continuous))
        // Base gloss for real artwork so it reads as a physical card.
        .overlay {
            if hasArt {
                LinearGradient(colors: [.white.opacity(0.14), .clear, .black.opacity(0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cardCorner, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
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
        .contentShape(RoundedRectangle(cornerRadius: Self.cardCorner, style: .continuous))
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .rotation3DEffect(.degrees(Double(-pointer.height) * maxTilt),
                          axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .rotation3DEffect(.degrees(Double(pointer.width) * maxTilt),
                          axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .shadow(color: .black.opacity(isHovered ? 0.28 : 0.12),
                radius: isHovered ? 16 : 6,
                x: CGFloat(pointer.width) * 10,
                y: isHovered ? 10 - CGFloat(pointer.height) * 10 : 3)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: pointer)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isHovered)
        .animation(.easeInOut(duration: 0.25), value: isReading)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                isHovered = true
                pointer = CGSize(width: location.x / 290 - 0.5,
                                 height: location.y / 182 - 0.5)
            case .ended:
                isHovered = false
                pointer = .zero
            }
        }
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

                // Soft diagonal light sweep that feathers along its travel axis.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .white.opacity(0.35), location: 0.5),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: 170)
                .rotationEffect(.degrees(18))
                .offset(x: scanX * 280)
                .blendMode(.screen)

                Label(t("读取中…", "Reading…"), systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.cardCorner, style: .continuous))
            .transition(.opacity)
            .onAppear {
                scanX = -1
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    scanX = 1
                }
            }
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

            HStack(spacing: 4) {
                Text(card.id.prefix(8) + "…" + card.id.suffix(6))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button(action: copyHash) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(copied ? Color.green : .secondary)
                }
                .buttonStyle(.plain)
                .help(copied ? t("已复制", "Copied") : t("复制完整标识", "Copy card identifier"))
            }
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

                Button(action: onExport) {
                    Image(systemName: isExporting ? "hourglass" : "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(!card.backup || isExporting)
                .help(t("导出首次备份（ZIP）", "Export first backup (ZIP)"))
        }
        .controlSize(.regular)
    }

    // MARK: Helpers

    private func copyHash() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(card.id, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

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
    let cardLabel: String
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
    var onZoomChange: ((CGFloat) -> Void)?
    private var hasFitted = false

    override func layout() {
        super.layout()
        if !hasFitted, contentView.bounds.width > 0, contentView.bounds.height > 0 {
            fitArtwork()
        }
    }

    func fitArtwork() {
        guard let documentView, contentView.bounds.width > 0,
              contentView.bounds.height > 0 else { return }
        hasFitted = true
        let fit = min(contentView.bounds.width / max(documentView.frame.width, 1),
                      contentView.bounds.height / max(documentView.frame.height, 1))
        setArtworkZoom(min(max(fit, minMagnification), maxMagnification))
    }

    func setArtworkZoom(_ value: CGFloat) {
        let center = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(min(max(value, minMagnification), maxMagnification), centeredAt: center)
        onZoomChange?(magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = min(abs(event.scrollingDeltaY), 10)
        guard delta > 0 else { return }
        let factor = pow(CGFloat(1.015), CGFloat(delta))
        setArtworkZoom(magnification * (event.scrollingDeltaY < 0 ? factor : 1 / factor))
    }
}

private struct ZoomableArtworkCanvas: NSViewRepresentable {
    let image: NSImage
    @Binding var zoom: CGFloat
    let fitRequest: Int

    final class Coordinator: NSObject {
        var zoom: Binding<CGFloat>
        var fitRequest = 0
        weak var scrollView: ArtworkScrollView?

        init(zoom: Binding<CGFloat>) {
            self.zoom = zoom
        }

        @objc func pan(_ gesture: NSPanGestureRecognizer) {
            guard let scrollView else { return }
            let translation = gesture.translation(in: scrollView)
            let clip = scrollView.contentView
            let origin = clip.bounds.origin
            clip.scroll(to: NSPoint(x: origin.x - translation.x / scrollView.magnification,
                                    y: origin.y - translation.y / scrollView.magnification))
            scrollView.reflectScrolledClipView(clip)
            gesture.setTranslation(.zero, in: scrollView)
            if gesture.state == .began || gesture.state == .changed {
                NSCursor.closedHand.set()
            } else if gesture.state == .ended || gesture.state == .cancelled {
                NSCursor.openHand.set()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(zoom: $zoom) }

    func makeNSView(context: Context) -> ArtworkScrollView {
        let scrollView = ArtworkScrollView()
        scrollView.contentView = CenteredArtworkClipView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1)
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 5

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        imageView.image = image
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.addGestureRecognizer(NSPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        scrollView.documentView = imageView
        context.coordinator.scrollView = scrollView
        scrollView.onZoomChange = { value in
            DispatchQueue.main.async { context.coordinator.zoom.wrappedValue = value }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: ArtworkScrollView, context: Context) {
        context.coordinator.zoom = $zoom
        if context.coordinator.fitRequest != fitRequest {
            context.coordinator.fitRequest = fitRequest
            scrollView.fitArtwork()
        } else if abs(scrollView.magnification - zoom) > 0.01 {
            scrollView.setArtworkZoom(zoom)
        }
    }
}

private struct CachedArtworkViewer: View {
    let item: CachedArtworkPreview
    let language: String
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var fitRequest = 0

    private var image: NSImage? { item.image }
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "photo")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("素材预览", "Artwork preview")).font(.headline)
                    Text(item.cardLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let url = item.url {
                    Button(t("在访达中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button(t("关闭", "Close")) { dismiss() }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            if let image {
                ZoomableArtworkCanvas(image: image, zoom: $zoom, fitRequest: fitRequest)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(t("无法显示卡面", "Cannot display artwork"), systemImage: "photo",
                                       description: Text(t("图片文件可能已移动或损坏。", "The image may have moved or become damaged.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 12) {
                Text(t("滚轮缩放 · 拖动查看", "Scroll to zoom · drag to pan"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { zoom = max(0.05, zoom / 1.2) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help(t("缩小", "Zoom out"))
                Slider(value: $zoom, in: 0.05...5)
                    .frame(width: 180)
                Button { zoom = min(5, zoom * 1.2) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help(t("放大", "Zoom in"))
                Text("\(Int(zoom * 100))%")
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
                Button(t("适应窗口", "Fit window")) { fitRequest += 1 }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 900, minHeight: 650)
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
    @StateObject private var vm = AppViewModel()
    @State private var artworkPreview: CachedArtworkPreview?
    @State private var editorSelection: CardEditorSelection?
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. Top Header Bar
            headerView
                .padding(.leading, 20)
                .padding(.trailing, 20)
                .frame(height: 62)
                .background(.bar)

            Divider()
            
            // 2. Live Scanner Notice Banner (if active)
            if vm.isScanningCards {
                scanningNoticeBanner
                Divider()
            }
            ForEach(vm.pending) { recovery in
                recoveryBanner(recovery)
                Divider()
            }
            if vm.device != nil && vm.device?.compatible == false {
                Text(vm.t("当前 iOS build 尚未验证，卡片操作已暂停。", "This iOS build is not verified. Card operations are paused."))
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 7)
            }
            
            // 3. Main Workspace
            ScrollView {
                if vm.visibleCards.isEmpty {
                    emptyStateView
                        .padding(.top, 40)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 330, maximum: 380), spacing: 20)],
                        spacing: 20
                    ) {
                        ForEach(Array(vm.cards.indices.filter { index in
                            vm.device == nil || vm.cards[index].deviceKey == vm.device?.key
                        }.filter { index in
                            !vm.hiddenCards.contains(vm.cards[index].deviceKey + ":" + vm.cards[index].id)
                        }), id: \.self) { idx in
                            let cardId = vm.cards[idx].id
                            let cardKey = vm.cards[idx].deviceKey
                            WalletCardView(
                                card: $vm.cards[idx],
                                cardIndex: idx,
                                language: vm.language,
                                onPickImage: { editorSelection = CardEditorSelection(cardID: cardId, deviceKey: cardKey) },
                                onClearImage: { vm.clearCardImage(for: cardId, deviceKey: cardKey) },
                                onRead: { vm.readCardArtwork(cardId) },
                                onExport: { exportCardArtwork(for: cardId, deviceKey: cardKey) },
                                onImageDropped: { url in selectForPreview(url, for: cardId, deviceKey: cardKey) },
                                onViewLarge: {
                                    if let image = vm.cards[idx].customImage ?? vm.cards[idx].cachedArtwork {
                                        artworkPreview = CachedArtworkPreview(
                                            image: image, url: vm.cards[idx].customImageURL,
                                            cardLabel: vm.cards[idx].label.isEmpty ? "卡片 #\(idx + 1)" : vm.cards[idx].label)
                                    }
                                },
                                onDelete: { vm.hideCard(cardId, deviceKey: cardKey) },
                                readDisabled: !vm.canOperate || vm.isExporting,
                                isReading: vm.readingCardID == cardId,
                                isExporting: vm.exportingCardID == cardId,
                                imageChangeDisabled: vm.isFlashing || vm.isExporting || vm.isReadingArtwork
                            )
                        }
                    }
                    .padding(20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // 4. Collapsible Activity Console (if open or flashing)
            if vm.showLogs {
                Divider()
                activityLogView
            }
            
            Divider()
            
            // 5. Bottom Action & Status Bar
            bottomBarView
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
        }
        .frame(minWidth: 880, minHeight: 680)
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
        .sheet(item: $artworkPreview) { item in
            CachedArtworkViewer(item: item, language: vm.language)
        }
        .sheet(item: $editorSelection) { item in
            CardEditorView(vm: vm, cardID: item.cardID, deviceKey: item.deviceKey,
                           chooseImage: { openCardImagePicker(for: item.cardID, deviceKey: item.deviceKey) },
                           exportBackup: { exportCardArtwork(for: item.cardID, deviceKey: item.deviceKey) })
        }
    }
    
    // MARK: - Subviews
    
    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "creditcard.circle.fill")
                .font(.system(size: 30))
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("AirCard Lite")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("v0.2")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(Capsule())
                }
                Text(vm.t("Wallet 卡面定制", "Wallet Card Skins"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Device Status Capsule
            HStack(spacing: 8) {
                Circle()
                    .fill(vm.device != nil ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                
                if let dev = vm.device {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(dev.name)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Text("\(dev.product) · iOS \(dev.version)")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(vm.t("未连接 iPhone (USB)", "No iPhone (USB)"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Button(action: { vm.checkDevice() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .disabled(vm.isCheckingDevice)
                .help(vm.t("刷新设备连接", "Refresh device connection"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(height: 32)
            .background(.quaternary, in: Capsule())

            Button(action: { vm.toggleCardScanning() }) {
                HStack(spacing: 6) {
                    if vm.isScanningCards {
                        ProgressView()
                            .scaleEffect(0.65)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "wave.3.forward.circle.fill")
                            .frame(width: 16, height: 16)
                    }
                    Text(vm.isScanningCards ? vm.t("停止扫描", "Stop scanning") : vm.t("扫描卡片", "Scan Cards"))
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(vm.isScanningCards ? Color.red : Color.blue, in: Capsule())
            }
            .buttonStyle(.plain)
            .opacity(vm.device != nil ? 1 : 0.45)
            .disabled(!vm.isScanningCards && !vm.canOperate)
            Menu {
                Picker(vm.t("语言", "Language"), selection: Binding(
                    get: { vm.language }, set: { vm.setLanguage($0) })) {
                    Text("简体中文").tag("zh")
                    Text("English").tag("en")
                }
                Picker(vm.t("外观", "Appearance"), selection: Binding(
                    get: { vm.appearance }, set: { vm.setAppearance($0) })) {
                    Text(vm.t("跟随系统", "System")).tag("system")
                    Text(vm.t("浅色", "Light")).tag("light")
                    Text(vm.t("深色", "Dark")).tag("dark")
                }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 16))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .help(vm.t("设置", "Settings"))
        }
        .controlSize(.regular)
        .frame(height: 54)
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
        panel.nameFieldStringValue = "AirCard-\(cardId.prefix(12)).zip"
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
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
