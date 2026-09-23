import SwiftUI
import AppKit

struct DeviceInfo {
    let udid: String
    let key: String
    let name: String
    let version: String
    let product: String
    let build: String
    let compatible: Bool
    var connected: Bool { true }
}

struct RecoveryItem: Identifiable {
    let id: String
    let deviceKey: String
    let card: String
}

struct CardItem: Identifiable, Hashable {
    let id: String
    let deviceKey: String
    var label: String
    var backup: Bool
    var customImageURL: URL?
    var customImage: NSImage?
    var preparedImageID: String?
    var cachedArtwork: NSImage?
    var cachedAssetNames: [String] = []

    static func == (lhs: CardItem, rhs: CardItem) -> Bool {
        lhs.id == rhs.id && lhs.deviceKey == rhs.deviceKey && lhs.preparedImageID == rhs.preparedImageID
    }
    func hash(into hasher: inout Hasher) { hasher.combine(deviceKey); hasher.combine(id) }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var device: DeviceInfo?
    @Published var cards: [CardItem] = []
    @Published var pending: [RecoveryItem] = []
    @Published var isCheckingDevice = false
    @Published var isScanningCards = false
    @Published var isClassifyingCard = false
    @Published var isFlashing = false
    @Published var isReadingArtwork = false
    @Published var isExporting = false
    @Published var readingCardID: String?
    @Published var exportingCardID: String?
    @Published var progress = 0.0
    @Published var statusText = "准备就绪"
    @Published var logs: [String] = []
    @Published var showLogs = false
    @Published var showSuccessAlert = false
    @Published var errorMessage: String?
    @Published var exportMessage: String?
    @Published var hiddenCards: Set<String> = []
    @Published var language = UserDefaults.standard.string(forKey: "aircard.language") ?? "zh"
    @Published var appearance = UserDefaults.standard.string(forKey: "aircard.appearance") ?? "system"

    let bridge = SwiftDesktopBridge()

    var visibleCards: [CardItem] {
        cards.filter { ($0.deviceKey == device?.key || device == nil) && !hiddenCards.contains($0.deviceKey + ":" + $0.id) }
    }
    var canOperate: Bool {
        device?.compatible == true && pending.first(where: { $0.deviceKey == device?.key }) == nil
            && !isFlashing && !isReadingArtwork && !isScanningCards && !isClassifyingCard && !isExporting
    }

    init() {
        bridge.onEvent = { [weak self] event in self?.handle(event) }
        AppLifecycle.bridge = bridge
        do {
            try bridge.start()
            Task {
                if let hello = try? await bridge.request("hello"),
                   let legacy = hello["legacyCandidates"] as? [[String: Any]], !legacy.isEmpty {
                    log(t("已保留 \(legacy.count) 张旧版卡片记录；请重新扫描以绑定当前设备。",
                          "Kept \(legacy.count) legacy card records. Scan again to assign them to this device."))
                }
                await refresh()
                checkDevice()
            }
        } catch {
            errorMessage = "找不到卡片操作后端。请重新构建应用。"
            statusText = "后端不可用"
        }
    }

    func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    func setLanguage(_ value: String) { language = value; UserDefaults.standard.set(value, forKey: "aircard.language") }
    func setAppearance(_ value: String) { appearance = value; UserDefaults.standard.set(value, forKey: "aircard.appearance") }

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("[\(formatter.string(from: Date()))] \(message)")
        if logs.count > 250 { logs.removeFirst(logs.count - 250) }
    }

    private func decodeImage(_ value: Any?) -> NSImage? {
        guard let encoded = value as? String, let comma = encoded.firstIndex(of: ","),
              let bytes = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])) else { return nil }
        return NSImage(data: bytes)
    }

    func refresh() async {
        do {
            let overview = try await bridge.request("overview")
            let previous = Dictionary(uniqueKeysWithValues: cards.map { ($0.deviceKey + ":" + $0.id, $0) })
            cards = (overview["cards"] as? [[String: Any]] ?? []).compactMap { row in
                guard row["card"] is String, row["deviceKey"] is String,
                      row["kind"] as? String == "secure-element" else { return nil }
                let id = row["card"] as! String, key = row["deviceKey"] as! String
                var card = CardItem(id: id, deviceKey: key,
                                    label: row["label"] as? String ?? "",
                                    backup: row["backup"] as? Bool ?? false)
                card.cachedArtwork = decodeImage(row["preview"])
                if let old = previous[key + ":" + id] {
                    card.customImageURL = old.customImageURL
                    card.customImage = old.customImage
                    card.preparedImageID = old.preparedImageID
                }
                return card
            }
            pending = (overview["pending"] as? [[String: Any]] ?? []).compactMap { row in
                guard let id = row["id"] as? String, let key = row["deviceKey"] as? String,
                      let card = row["card"] as? String else { return nil }
                return RecoveryItem(id: id, deviceKey: key, card: card)
            }
            isScanningCards = overview["scanning"] as? Bool ?? isScanningCards
        } catch { report(error) }
    }

    func checkDevice() {
        guard !isCheckingDevice else { return }
        isCheckingDevice = true
        Task {
            defer { isCheckingDevice = false }
            do {
                let row = try await bridge.request("device")
                guard let id = row["id"] as? String, let key = row["key"] as? String else {
                    throw SwiftDesktopBridge.BridgeError.backend("NO_DEVICE")
                }
                device = DeviceInfo(udid: id, key: key, name: row["name"] as? String ?? "iPhone",
                                    version: row["version"] as? String ?? "",
                                    product: row["product"] as? String ?? "iPhone",
                                    build: row["build"] as? String ?? "",
                                    compatible: row["compatible"] as? Bool ?? false)
                statusText = device?.compatible == true ? t("已连接 \(device!.name)", "Connected to \(device!.name)")
                    : t("当前 iOS build 尚未验证，卡片操作已暂停。", "This iOS build is not verified; card operations are paused.")
                log(statusText)
            } catch {
                device = nil
                statusText = t("未连接 iPhone，请使用 USB 连接并解锁。", "No iPhone. Connect with USB and unlock it.")
                log(statusText)
            }
        }
    }

    func toggleCardScanning() { isScanningCards ? stopCardScanning() : startCardScanning() }
    func startCardScanning() {
        guard canOperate, let device else { return }
        Task {
            do {
                _ = try await bridge.request("scan.start", ["device": device.udid])
                isScanningCards = true
                statusText = t("正在扫描卡片…", "Scanning cards…")
            } catch { report(error) }
        }
    }
    func stopCardScanning() {
        Task {
            do {
                _ = try await bridge.request("scan.stop")
                isScanningCards = false
                isClassifyingCard = false
                statusText = t("扫描结束。", "Scanning stopped.")
                await refresh()
            } catch { report(error) }
        }
    }

    func selectImage(_ url: URL, for id: String, deviceKey: String) {
        guard let index = cards.firstIndex(where: { $0.id == id && $0.deviceKey == deviceKey }),
              let image = NSImage(contentsOf: url) else {
            errorMessage = t("无法打开所选图片。", "Could not open the selected image.")
            return
        }
        cards[index].customImageURL = url
        cards[index].customImage = image
        cards[index].preparedImageID = nil
    }

    func prepareImage(for id: String, deviceKey: String, crop: [String: Double]) async throws {
        guard let index = cards.firstIndex(where: { $0.id == id && $0.deviceKey == deviceKey }),
              let url = cards[index].customImageURL else { throw SwiftDesktopBridge.BridgeError.backend("FILE_NOT_FOUND") }
        let row = try await bridge.request("image.prepare", ["path": url.path, "crop": crop])
        guard let imageID = row["imageId"] as? String, let image = decodeImage(row["preview"]) else {
            throw SwiftDesktopBridge.BridgeError.backend("INVALID_IMAGE")
        }
        cards[index].preparedImageID = imageID
        cards[index].customImage = image
    }

    func clearCardImage(for id: String, deviceKey: String) {
        guard let index = cards.firstIndex(where: { $0.id == id && $0.deviceKey == deviceKey }) else { return }
        cards[index].customImageURL = nil
        cards[index].customImage = nil
        cards[index].preparedImageID = nil
    }

    func invalidatePreparedImage(for id: String, deviceKey: String) {
        guard let index = cards.firstIndex(where: { $0.id == id && $0.deviceKey == deviceKey }) else { return }
        cards[index].preparedImageID = nil
        if let url = cards[index].customImageURL { cards[index].customImage = NSImage(contentsOf: url) }
    }

    func readCardArtwork(_ id: String) {
        guard canOperate, let device else { return }
        isReadingArtwork = true
        readingCardID = id
        runCard("card.read", id: id, device: device) {
            self.isReadingArtwork = false
            self.readingCardID = nil
        }
    }

    func applySkin(for id: String) {
        guard canOperate, let device,
              let imageID = cards.first(where: { $0.id == id && $0.deviceKey == device.key })?.preparedImageID else { return }
        isFlashing = true
        runCard("card.apply", id: id, device: device, extra: ["imageId": imageID]) {
            self.isFlashing = false
            self.showSuccessAlert = true
        }
    }

    func restoreFirstBackup(for id: String) {
        guard canOperate, let device,
              cards.contains(where: { $0.id == id && $0.deviceKey == device.key && $0.backup }) else { return }
        isFlashing = true
        runCard("card.restore", id: id, device: device) {
            self.isFlashing = false
            self.showSuccessAlert = true
        }
    }

    private func runCard(_ method: String, id: String, device: DeviceInfo,
                         extra: [String: Any] = [:], done: @escaping () -> Void) {
        showLogs = true
        statusText = t("正在处理卡片…", "Working on card…")
        Task {
            defer { if method == "card.read" { isReadingArtwork = false; readingCardID = nil }
                    else { isFlashing = false } }
            do {
                var params: [String: Any] = ["device": device.udid, "card": id]
                params.merge(extra) { _, new in new }
                _ = try await bridge.request(method, params)
                await refresh()
                if method == "card.apply" || method == "card.restore" {
                    clearCardImage(for: id, deviceKey: device.key)
                }
                statusText = t("操作完成，请重新打开手机 Wallet 检查。", "Done. Reopen Wallet on your iPhone to check.")
                log(statusText)
                done()
            } catch {
                await refresh()
                report(error)
            }
        }
    }

    func exportCachedArtwork(_ id: String, deviceKey: String, to output: URL) {
        guard let card = cards.first(where: { $0.id == id && $0.deviceKey == deviceKey && $0.backup }) else { return }
        isExporting = true
        exportingCardID = id
        Task {
            defer { isExporting = false; exportingCardID = nil }
            do {
                _ = try await bridge.request("card.export", ["card": id, "deviceKey": card.deviceKey,
                                                               "destination": output.path])
                exportMessage = t("首次备份已导出：\n\(output.path)", "First backup exported:\n\(output.path)")
            } catch { report(error) }
        }
    }

    func resumeRecovery(_ item: RecoveryItem) {
        guard !isFlashing && device?.key == item.deviceKey else { return }
        isFlashing = true
        showLogs = true
        Task {
            defer { isFlashing = false }
            do {
                _ = try await bridge.request("recovery.resume", ["operationId": item.id])
                await refresh()
                statusText = t("恢复完成。", "Recovery completed.")
            } catch { await refresh(); report(error) }
        }
    }

    func cancelCurrentOperation() {
        Task { _ = try? await bridge.request("cancel") }
        statusText = t("将在当前安全步骤结束后停止…", "Stopping after the current safe step…")
    }

    func hideCard(_ id: String, deviceKey: String) {
        hiddenCards.insert(deviceKey + ":" + id)
    }

    private func handle(_ message: [String: Any]) {
        guard let event = message["event"] as? String else { return }
        switch event {
        case "changed": Task { await refresh() }
        case "candidate": isClassifyingCard = true; statusText = t("发现卡片，正在核验类型…", "Card found; verifying its type…")
        case "scanStopped": isScanningCards = false; isClassifyingCard = false; Task { await refresh() }
        case "progress":
            let stage = message["stage"] as? String ?? ""
            let names: [String: (String, String)] = [
                "classifying": ("正在核验卡片类型…", "Checking card type…"),
                "backingUp": ("正在保存并校验原始素材…", "Backing up and verifying originals…"),
                "writing": ("正在写入并校验卡面…", "Writing and verifying artwork…"),
                "invalidating": ("正在刷新 Wallet 缓存…", "Refreshing Wallet cache…"),
                "cleaning": ("正在恢复临时文件…", "Restoring temporary files…"),
                "recovering": ("正在恢复操作前状态…", "Recovering previous state…")]
            let pair = names[stage]
            statusText = t(pair?.0 ?? stage, pair?.1 ?? stage)
            log(statusText)
        case "scanError", "fatal":
            errorMessage = friendly(message["code"] as? String ?? "OPERATION_FAILED")
        default: break
        }
    }

    private func friendly(_ code: String) -> String {
        let names: [String: (String, String)] = [
            "NO_DEVICE": ("未发现 iPhone，请连接并解锁。", "No iPhone. Connect and unlock it."),
            "UNSUPPORTED_DEVICE": ("此 iOS build 尚未验证。", "This iOS build has not been verified."),
            "RECOVERY_REQUIRED": ("请先完成待处理的恢复。", "Complete pending recovery first."),
            "CARD_QUARANTINED": ("此卡片仍有未解决的恢复记录。", "This card has an unresolved recovery record."),
            "INVALID_BACKUP": ("备份校验失败，请保留备份文件。", "Backup verification failed. Keep the backup files."),
            "CARD_NOT_CLASSIFIED": ("只能操作已确认的支付卡或交通卡。", "Only verified payment or transit cards can be changed."),
            "ARTWORK_UNAVAILABLE": ("未找到受支持的卡面素材。", "No supported artwork was found."),
            "CANCELLED": ("操作已停止，原状态已恢复。", "Stopped and restored the previous state."),
            "BACKEND_OFFLINE": ("设备服务已停止，请重启应用检查恢复状态。", "The device service stopped. Restart to inspect recovery."),
            "IMAGE_FORMAT": ("请选择 PNG、JPEG 或 WebP 图片。", "Choose a PNG, JPEG or WebP image."),
            "IMAGE_TOO_LARGE": ("图片超过 32 MB 或四千万像素。", "Image exceeds 32 MB or 40 megapixels."),
            "INVALID_CROP": ("裁剪范围超出了图片。", "Crop is outside the image."),
            "WRITE_NOT_VERIFIED": ("新卡面未通过回读校验，请检查恢复状态。", "Artwork write did not verify. Check recovery."),
            "READ_INDETERMINATE": ("未能确认原文件位置，恢复资料已保留。", "Original file location is uncertain; recovery data was kept.")]
        let pair = names[code]
        return t(pair?.0 ?? "操作失败（\(code)）。请查看日志和恢复状态。",
                 pair?.1 ?? "Operation failed (\(code)). Check logs and recovery status.")
    }
    private func report(_ error: Error) {
        let code = (error as? SwiftDesktopBridge.BridgeError)?.errorDescription ?? error.localizedDescription
        errorMessage = friendly(code)
        statusText = errorMessage ?? ""
        log(statusText)
    }
    func present(_ error: Error) { report(error) }
}
