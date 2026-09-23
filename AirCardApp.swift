import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - Models

struct DeviceInfo: Codable {
    var udid: String?
    var name: String?
    var version: String?
    var product: String?
    var airlift_compatible: Bool?
    var connected: Bool
    var error: String?
}

struct CardItem: Identifiable, Hashable {
    let id: String
    var isSelected: Bool = true
    var customImageURL: URL? = nil
    var customImage: NSImage? = nil
    var cachedArtworkURL: URL? = nil
    var cachedArtwork: NSImage? = nil
    var cachedAssetNames: [String] = []
    var cachedFiles: [String: String] = [:]

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: CardItem, rhs: CardItem) -> Bool {
        lhs.id == rhs.id && lhs.isSelected == rhs.isSelected &&
        lhs.customImageURL == rhs.customImageURL &&
        lhs.cachedArtworkURL == rhs.cachedArtworkURL &&
        lhs.cachedAssetNames == rhs.cachedAssetNames &&
        lhs.cachedFiles == rhs.cachedFiles
    }
}

// MARK: - View Model

@MainActor
class AppViewModel: ObservableObject {
    @Published var device: DeviceInfo?
    @Published var isCheckingDevice = false
    @Published var isScanningCards = false
    @Published var cards: [CardItem] = []
    
    @Published var isFlashing = false
    @Published var progress: Double = 0.0
    @Published var statusText: String = "Ready"
    @Published var logs: [String] = []
    @Published var showSuccessAlert = false
    @Published var errorMessage: String?
    @Published var isExporting = false
    @Published var isReadingArtwork = false
    @Published var exportingCardID: String?
    @Published var readingCardID: String?
    @Published var exportMessage: String?
    
    @Published var showAddCardSheet = false
    @Published var manualHashInput = ""
    @Published var showLogs = false
    
    private var scanProcess: Process?
    private let scriptDir: String
    private let storageKey = "mak5er.aircard.savedCards"
    private let legacyStorageKey1 = "mak5er.savedCards"
    private let legacyStorageKey2 = "LumiCards.savedCards"
    
    nonisolated static let cardRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: "/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,44})(?:\\.pkpass|\\.cache|\\.pkcache|/|\\s|\"|'|\\)|,|$)"),
        try! NSRegularExpression(pattern: "/([-A-Za-z0-9_+=]{20,44})\\.(?:pkpass|cache|pkcache)"),
        try! NSRegularExpression(pattern: "(?<![A-Za-z0-9+/_-])([A-Za-z0-9+/_-]{27}=)(?![A-Za-z0-9+/_-])")
    ]
    
    init() {
        let cwd = FileManager.default.currentDirectoryPath
        if let resPath = Bundle.main.resourcePath, FileManager.default.fileExists(atPath: resPath + "/aircard_backend.py") {
            self.scriptDir = resPath
        } else if FileManager.default.fileExists(atPath: cwd + "/aircard_backend.py") {
            self.scriptDir = cwd
        } else {
            self.scriptDir = Bundle.main.bundleURL.deletingLastPathComponent().path
        }
        
        loadSavedCards()
        loadCachedArtworks()
        checkDevice()
    }
    
    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        logs.append("[\(timestamp)] \(message)")
    }
    
    nonisolated private static var pythonExecutableURL: URL {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }
    
    nonisolated private static var deviceHelperExecutableURL: URL? {
        var candidates: [String] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("bin/device_helper").path)
        }
        candidates.append("/Applications/AirCard.app/Contents/Resources/bin/device_helper")
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
    
    nonisolated private static var processEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        var extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        if let res = Bundle.main.resourceURL {
            extraPaths.insert(res.appendingPathComponent("bin").path, at: 0)
        }
        extraPaths.insert("/Applications/AirCard.app/Contents/Resources/bin", at: 0)
        env["PATH"] = (extraPaths + [path]).joined(separator: ":")
        
        var libPaths = ["/Applications/AirCard.app/Contents/Resources/lib"]
        if let res = Bundle.main.resourceURL {
            libPaths.insert(res.appendingPathComponent("lib").path, at: 0)
        }
        let curDyld = env["DYLD_LIBRARY_PATH"] ?? ""
        env["DYLD_LIBRARY_PATH"] = (libPaths + (curDyld.isEmpty ? [] : [curDyld])).joined(separator: ":")
        return env
    }
    
    nonisolated static func prepareCardImage(srcURL: URL, dstURL: URL) -> Bool {
        guard let image = NSImage(contentsOf: srcURL) else { return false }
        let targetSize = CGSize(width: 1536, height: 969)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return false }
        
        rep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        
        let imgSize = image.size
        let scale = max(targetSize.width / imgSize.width, targetSize.height / imgSize.height)
        let scaledWidth = imgSize.width * scale
        let scaledHeight = imgSize.height * scale
        let x = (targetSize.width - scaledWidth) / 2.0
        let y = (targetSize.height - scaledHeight) / 2.0
        
        image.draw(in: CGRect(x: x, y: y, width: scaledWidth, height: scaledHeight),
                   from: CGRect(origin: .zero, size: imgSize),
                   operation: .copy,
                   fraction: 1.0)
        
        NSGraphicsContext.restoreGraphicsState()
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try pngData.write(to: dstURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
    
    // MARK: - Persistence
    
    func loadSavedCards() {
        var loaded: [String] = []
        
        if let saved = UserDefaults.standard.stringArray(forKey: storageKey), !saved.isEmpty {
            loaded.append(contentsOf: saved)
        } else if let saved = UserDefaults.standard.stringArray(forKey: legacyStorageKey1), !saved.isEmpty {
            loaded.append(contentsOf: saved)
        } else if let saved = UserDefaults.standard.stringArray(forKey: legacyStorageKey2), !saved.isEmpty {
            loaded.append(contentsOf: saved)
        }
        
        for p in ["~/.aircard_cards.json", "~/.lumicards_cards.json"] {
            let jsonPath = NSString(string: p).expandingTildeInPath
            if let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
               let jsonHashes = try? JSONDecoder().decode([String].self, from: data) {
                for h in jsonHashes where !loaded.contains(h) {
                    loaded.append(h)
                }
            }
        }
        
        let dummyHashes = [
            "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
            "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
            "hwAtAmHKYwsQrJbT5cTNDsaxVME="
        ]
        loaded.removeAll { dummyHashes.contains($0) || ($0.contains("-") && $0.count == 36) }
        
        self.cards = loaded.map { CardItem(id: $0, isSelected: true) }
        log("Loaded \(cards.count) real card(s) from storage.")
    }
    
    func saveCards() {
        let hashes = cards.map { $0.id }
        UserDefaults.standard.set(hashes, forKey: storageKey)
        
        let jsonPath = NSString(string: "~/.aircard_cards.json").expandingTildeInPath
        if let data = try? JSONEncoder().encode(hashes) {
            try? data.write(to: URL(fileURLWithPath: jsonPath), options: .atomic)
        }
    }

    private func applyCachedArtwork(_ info: [String: Any], to cardHash: String) {
        guard let index = cards.firstIndex(where: { $0.id == cardHash }),
              let files = info["files"] as? [String: String],
              let names = info["assets"] as? [String] else { return }
        let preferred = ["cardBackgroundCombined@3x.png",
                         "cardBackgroundCombined@2x.png",
                         "cardBackgroundCombined.pdf"]
        for name in preferred {
            guard let path = files[name] else { continue }
            let url = URL(fileURLWithPath: path)
            let image: NSImage?
            if url.pathExtension.lowercased() == "pdf" {
                image = PDFDocument(url: url)?.page(at: 0)?.thumbnail(
                    of: CGSize(width: 1536, height: 969), for: .mediaBox)
            } else {
                image = NSImage(contentsOf: url)
            }
            if let image {
                cards[index].cachedArtworkURL = url
                cards[index].cachedArtwork = image
                cards[index].cachedAssetNames = names
                cards[index].cachedFiles = files
                return
            }
        }
        log("Cached files for \(cardHash.prefix(12)) could not be displayed as an image.")
    }

    func loadCachedArtworks() {
        let hashes = cards.map(\.id)
        guard !hashes.isEmpty,
              let input = try? JSONSerialization.data(withJSONObject: hashes),
              let json = String(data: input, encoding: .utf8) else { return }
        let scriptDir = self.scriptDir
        Task.detached {
            let process = Process()
            process.executableURL = AppViewModel.pythonExecutableURL
            process.environment = AppViewModel.processEnvironment
            process.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
            process.arguments = ["aircard_backend.py", "--cached-cards", json]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let found = result["cards"] as? [String: [String: Any]] else { return }
                await MainActor.run {
                    for (hash, info) in found {
                        self.applyCachedArtwork(info, to: hash)
                    }
                }
            } catch {
                await MainActor.run { self.log("Could not load cached artwork: \(error.localizedDescription)") }
            }
        }
    }
    
    func addCardHash(_ raw: String) {
        let components = raw.components(separatedBy: CharacterSet(charactersIn: " \n\r\t,;"))
        var addedCount = 0
        for comp in components {
            let clean = comp.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if clean.count >= 16 && clean.count <= 64 && !cards.contains(where: { $0.id == clean }) {
                cards.append(CardItem(id: clean, isSelected: true))
                addedCount += 1
                log("Added card: \(clean)")
            }
        }
        if addedCount > 0 {
            saveCards()
            loadCachedArtworks()
        }
    }
    
    func deleteCard(id: String) {
        cards.removeAll { $0.id == id }
        saveCards()
        log("Removed card: \(id)")
    }
    
    func clearAllCards() {
        cards.removeAll()
        saveCards()
        log("Cleared all cards.")
    }
    
    func setCardImage(for cardId: String, url: URL) {
        if let idx = cards.firstIndex(where: { $0.id == cardId }) {
            cards[idx].customImageURL = url
            cards[idx].customImage = NSImage(contentsOf: url)
            cards[idx].isSelected = true
            log("Assigned custom skin to card: \(cardId.prefix(12))...")
        }
    }
    
    func clearCardImage(for cardId: String) {
        if let idx = cards.firstIndex(where: { $0.id == cardId }) {
            cards[idx].customImageURL = nil
            cards[idx].customImage = nil
            log("Cleared custom skin for: \(cardId.prefix(12))...")
        }
    }
    
    // MARK: - Device Connection
    
    func checkDevice() {
        isCheckingDevice = true
        statusText = "Checking connected devices..."
        let scriptDir = self.scriptDir
        
        Task.detached {
            let process = Process()
            process.executableURL = AppViewModel.pythonExecutableURL
            process.environment = AppViewModel.processEnvironment
            process.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
            process.arguments = ["aircard_backend.py", "--device"]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                
                if let dev = try? JSONDecoder().decode(DeviceInfo.self, from: data) {
                    await MainActor.run {
                        self.device = dev
                        self.isCheckingDevice = false
                        if dev.connected {
                            self.statusText = "Connected to \(dev.name ?? "iPhone")"
                            self.log("Device connected: \(dev.name ?? "iPhone") (\(dev.product ?? ""), iOS \(dev.version ?? ""))")
                        } else if dev.error == "device_helper_missing" {
                            self.statusText = "Device tools are missing from this build."
                            self.log("Bundled device_helper not found — detection cannot run.")
                        } else {
                            self.statusText = "No iPhone found. Please connect via USB."
                        }
                    }
                } else {
                    await MainActor.run {
                        self.isCheckingDevice = false
                        self.statusText = "No iPhone found. Please connect via USB."
                    }
                }
            } catch {
                await MainActor.run {
                    self.isCheckingDevice = false
                    self.statusText = "Device detection failed: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // MARK: - Live Card Scanner
    
    func toggleCardScanning() {
        if isScanningCards {
            stopCardScanning()
        } else {
            startCardScanning()
        }
    }
    
    func startCardScanning() {
        guard !isScanningCards else { return }
        guard let deviceHelper = AppViewModel.deviceHelperExecutableURL else {
            errorMessage = "Device tools are missing from this build."
            log("Bundled device_helper not found — cannot scan.")
            return
        }
        guard let udid = device?.udid else {
            errorMessage = "No iPhone connected."
            return
        }
        isScanningCards = true
        statusText = "Double-click Side button, pass Face ID, then tap your card..."
        log("Started scanning device logs for cards...")
        
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = deviceHelper
        proc.environment = AppViewModel.processEnvironment
        proc.arguments = ["syslog", udid]
        proc.standardOutput = pipe
        proc.standardError = pipe
        
        self.scanProcess = proc
        // Launch before yielding so Stop cannot race with a pending launch.
        do {
            try proc.run()
        } catch {
            scanProcess = nil
            isScanningCards = false
            statusText = "Could not start card scanning."
            log("Syslog monitor failed to start: \(error.localizedDescription)")
            return
        }
        
        let dummyHashes = [
            "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
            "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
            "hwAtAmHKYwsQrJbT5cTNDsaxVME="
        ]
        
        Task.detached {
            do {
                let handle = pipe.fileHandleForReading
                var buffer = Data()
                
                // Drain the pipe through EOF, including the last buffered record
                // when the helper exits. isRunning can become false too early.
                while true {
                    let chunk = try handle.read(upToCount: 65536) ?? Data()
                    if chunk.isEmpty {
                        if buffer.isEmpty { break }
                        buffer.append(0x0A)
                    } else {
                        buffer.append(chunk)
                    }
                    
                    while let newlineRange = buffer.range(of: Data([0x0A])) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                        buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
                        
                        guard let line = String(data: lineData, encoding: .utf8) else { continue }
                        if line.hasPrefix("AirCard scanner: ") {
                            await MainActor.run {
                                guard self.scanProcess === proc else { return }
                                self.log(line)
                            }
                            continue
                        }
                        let lower = line.lowercased()
                        
                        let isWalletSubsystem = lower.contains("passd") ||
                                                lower.contains("passbook") ||
                                                lower.contains("passkit") ||
                                                lower.contains("stockholm") ||
                                                lower.contains("nanopassd") ||
                                                lower.contains("wallet") ||
                                                lower.contains("/cards/")
                        
                        guard isWalletSubsystem else { continue }
                        
                        let isWalletContext = lower.contains("card") ||
                                              lower.contains("pass") ||
                                              lower.contains("payment") ||
                                              lower.contains("pkpass") ||
                                              lower.contains("uniqueid") ||
                                              lower.contains("identifier") ||
                                              lower.contains("face") ||
                                              lower.contains("cache") ||
                                              lower.contains("stockholm") ||
                                              lower.contains("/cards/")
                        
                        guard isWalletContext else { continue }
                        
                        for regex in AppViewModel.cardRegexes {
                            let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
                            for m in matches {
                                if m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: line) {
                                    let candidate = String(line[r])
                                    if candidate.count == 36 && candidate.contains("-") { continue }
                                    if dummyHashes.contains(candidate) { continue }
                                    
                                    await MainActor.run {
                                        guard self.scanProcess === proc else { return }
                                        if !self.cards.contains(where: { $0.id == candidate }) {
                                            self.cards.append(CardItem(id: candidate, isSelected: true))
                                            self.saveCards()
                                            self.log("Found card: \(candidate)")
                                            NSSound(named: "Glass")?.play()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if chunk.isEmpty { break }
                }
                proc.waitUntilExit()
                await MainActor.run {
                    guard self.scanProcess === proc else { return }
                    self.scanProcess = nil
                    self.isScanningCards = false
                    self.statusText = "Card scanning ended. Check the log and reconnect the iPhone to retry."
                    self.log("Syslog monitor exited (status \(proc.terminationStatus)). Total cards: \(self.cards.count).")
                    self.saveCards()
                }
            } catch {
                if proc.isRunning { proc.terminate() }
                proc.waitUntilExit()
                await MainActor.run {
                    guard self.scanProcess === proc else { return }
                    self.scanProcess = nil
                    self.log("Syslog monitor stopped: \(error.localizedDescription)")
                    self.isScanningCards = false
                    self.statusText = "Card scanning failed. Check the log and retry."
                }
            }
        }
    }
    
    func stopCardScanning() {
        let process = scanProcess
        scanProcess = nil
        if let process, process.isRunning { process.terminate() }
        isScanningCards = false
        if statusText.contains("Double-click Side button") {
            statusText = "Ready"
        }
        saveCards()
        loadCachedArtworks()
        log("Scanning stopped. Total cards: \(cards.count).")
    }
    
    // MARK: - Skin Application

    /// Reads every available artwork asset (all @3x/@2x PNG and PDF variants)
    /// from the device and caches them so they can be previewed and exported.
    func readCardArtwork(_ cardHash: String) {
        guard let udid = device?.udid else {
            exportMessage = "请先连接 iPhone。"
            return
        }
        guard !isExporting && !isReadingArtwork && !isFlashing else { return }
        isReadingArtwork = true
        readingCardID = cardHash
        showLogs = true
        statusText = "正在读取卡面…"
        log(statusText)
        let scriptDir = self.scriptDir
        Task.detached {
            let process = Process()
            process.executableURL = AppViewModel.pythonExecutableURL
            process.environment = AppViewModel.processEnvironment
            process.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
            process.arguments = ["aircard_backend.py", "--read-card", udid, cardHash]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let lines = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n")
                let result = lines.reversed().compactMap { line -> [String: Any]? in
                    guard let bytes = String(line).data(using: .utf8) else { return nil }
                    return try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                }.first
                let succeeded = process.terminationStatus == 0 && (result?["ok"] as? Bool == true)
                let message = (result?["message"] as? String) ?? "卡面读取失败，请查看日志。"
                await MainActor.run {
                    self.isReadingArtwork = false
                    self.readingCardID = nil
                    self.statusText = succeeded ? "卡面读取成功。" : "卡面读取失败。"
                    self.log(message)
                    if let recovery = result?["recovery"] as? String {
                        self.log("Recovery copies: \(recovery)")
                    }
                    if succeeded, let cache = result?["cache"] as? [String: Any] {
                        self.applyCachedArtwork(cache, to: cardHash)
                    } else {
                        self.exportMessage = message
                    }
                }
            } catch {
                await MainActor.run {
                    self.isReadingArtwork = false
                    self.readingCardID = nil
                    self.statusText = "卡面读取失败。"
                    self.exportMessage = "无法启动卡面读取：\(error.localizedDescription)"
                    self.log(self.exportMessage ?? "卡面读取失败")
                }
            }
        }
    }

    /// Exports the already-read artwork files as a ZIP without touching the
    /// device again. Includes every cached asset variant.
    func exportCachedArtwork(_ cardHash: String, to output: URL) {
        guard let idx = cards.firstIndex(where: { $0.id == cardHash }) else { return }
        let files = cards[idx].cachedFiles
        guard !files.isEmpty else {
            exportMessage = "请先读取卡面，再导出素材。"
            return
        }
        isExporting = true
        exportingCardID = cardHash
        statusText = "正在导出卡面素材…"
        log(statusText)
        Task.detached {
            let paths = files.values.filter { FileManager.default.fileExists(atPath: $0) }
            var errorText: String?
            if paths.isEmpty {
                errorText = "缓存文件已失效，请重新读取卡面。"
            } else {
                try? FileManager.default.removeItem(at: output)
                let zip = Process()
                zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                zip.arguments = ["-j", "-q", output.path] + paths
                zip.standardOutput = FileHandle.nullDevice
                zip.standardError = FileHandle.nullDevice
                do {
                    try zip.run()
                    zip.waitUntilExit()
                    if zip.terminationStatus != 0 || !FileManager.default.fileExists(atPath: output.path) {
                        errorText = "打包 ZIP 失败（代码 \(zip.terminationStatus)）。"
                    }
                } catch {
                    errorText = "无法启动打包程序：\(error.localizedDescription)"
                }
            }
            let count = paths.count
            let finalError = errorText
            await MainActor.run {
                self.isExporting = false
                self.exportingCardID = nil
                if let errorText = finalError {
                    self.statusText = "卡面素材导出失败。"
                    self.exportMessage = errorText
                } else {
                    self.statusText = "卡面素材导出成功。"
                    self.exportMessage = "已导出 \(count) 个卡面素材文件至：\n\(output.path)"
                }
                self.log(self.exportMessage ?? "")
            }
        }
    }
    
    func applySkin() {
        guard !isExporting && !isReadingArtwork && !isFlashing else { return }
        guard let udid = device?.udid else {
            errorMessage = "No iPhone connected."
            return
        }
        let selectedCardsWithSkin = cards.filter { $0.isSelected && $0.customImageURL != nil }
        guard !selectedCardsWithSkin.isEmpty else {
            errorMessage = "Please assign a skin image to at least one selected card."
            return
        }
        
        isFlashing = true
        showLogs = true
        progress = 0.0
        log("Starting skin application for \(selectedCardsWithSkin.count) card(s)...")
        let scriptDir = self.scriptDir
        
        Task.detached {
            var flashFailed = false
            let totalCards = Double(selectedCardsWithSkin.count)
            for (idx, card) in selectedCardsWithSkin.enumerated() {
                guard let imgURL = card.customImageURL else { continue }
                
                let preparedPath = "/tmp/aircard_prep_\(idx).png"
                
                await MainActor.run {
                    self.statusText = "[\(idx + 1)/\(selectedCardsWithSkin.count)] Preparing skin for \(card.id.prefix(10))..."
                    self.progress = (Double(idx) + 0.05) / totalCards
                    self.log("Flashing card [\(idx + 1)/\(selectedCardsWithSkin.count)]: \(card.id)")
                }
                
                // 1. Prepare image natively in Swift (0 external dependencies!)
                let preparedURL = URL(fileURLWithPath: preparedPath)
                let prepped = AppViewModel.prepareCardImage(srcURL: imgURL, dstURL: preparedURL)
                if !prepped {
                    let prepProcess = Process()
                    prepProcess.executableURL = AppViewModel.pythonExecutableURL
                    prepProcess.environment = AppViewModel.processEnvironment
                    prepProcess.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
                    prepProcess.arguments = ["aircard_backend.py", "--prepare-image", imgURL.path, preparedPath]
                    try? prepProcess.run()
                    prepProcess.waitUntilExit()
                }
                
                // 2. Flash card
                let flashProcess = Process()
                flashProcess.executableURL = AppViewModel.pythonExecutableURL
                flashProcess.environment = AppViewModel.processEnvironment
                flashProcess.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
                flashProcess.arguments = ["aircard_backend.py", "--flash", udid, card.id, preparedPath]
                
                let pipe = Pipe()
                let errPipe = Pipe()
                flashProcess.standardOutput = pipe
                flashProcess.standardError = errPipe
                errPipe.fileHandleForReading.readabilityHandler = { h in
                    let data = h.availableData
                    if !data.isEmpty, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        Task { @MainActor in
                            self.log("  [err] \(text)")
                        }
                    }
                }
                
                do {
                    try flashProcess.run()
                } catch {
                    let message = error.localizedDescription
                    flashFailed = true
                    await MainActor.run {
                        self.log("Failed to launch card flasher: \(message)")
                    }
                    break
                }
                
                let handle = pipe.fileHandleForReading
                var lineBuffer = ""
                
                let handleJSONLine: (String) async -> Void = { line in
                    guard !line.isEmpty,
                          let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let msg = json["message"] as? String else { return }
                    
                    let step = (json["step"] as? NSNumber)?.doubleValue
                    let total = (json["total"] as? NSNumber)?.doubleValue
                    
                    await MainActor.run {
                        if let step = step, let total = total, total > 0 {
                            let subProgress = step / total
                            let currentProgress = (Double(idx) + subProgress) / totalCards
                            self.progress = min(currentProgress, 1.0)
                        }
                        self.statusText = "[\(idx + 1)/\(selectedCardsWithSkin.count)] \(msg)"
                        self.log("  \(msg)")
                    }
                }
                
                let processChunk: (Data) async -> Void = { data in
                    guard let text = String(data: data, encoding: .utf8) else { return }
                    lineBuffer.append(text)
                    let parts = lineBuffer.components(separatedBy: .newlines)
                    if parts.count > 1 {
                        for line in parts.dropLast() {
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                await handleJSONLine(trimmed)
                            }
                        }
                        lineBuffer = parts.last ?? ""
                    }
                }
                
                while flashProcess.isRunning {
                    let data = handle.availableData
                    if data.isEmpty { usleep(50000); continue }
                    await processChunk(data)
                }
                
                let remainingData = handle.readDataToEndOfFile()
                if !remainingData.isEmpty {
                    await processChunk(remainingData)
                }
                let finalLine = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !finalLine.isEmpty {
                    await handleJSONLine(finalLine)
                }
                flashProcess.waitUntilExit()
                errPipe.fileHandleForReading.readabilityHandler = nil

                if flashProcess.terminationStatus != 0 {
                    flashFailed = true
                    await MainActor.run {
                        self.log("Card update failed for \(card.id.prefix(12))...")
                    }
                    break
                }
                
                await MainActor.run {
                    self.progress = Double(idx + 1) / totalCards
                }
            }
            
            let didFail = flashFailed
            await MainActor.run {
                self.isFlashing = false
                if didFail {
                    self.statusText = "Failed to apply card skins."
                    self.errorMessage = "One or more cards could not be updated. Check the log and try again."
                    self.log("Skin application stopped after a card update failed.")
                } else {
                    self.statusText = "Complete! All cards updated."
                    self.showSuccessAlert = true
                    self.log("Skins successfully applied to all selected cards!")
                }
            }
        }
    }
}

// MARK: - Card View Component (Apple Wallet Style)

struct WalletCardView: View {
    @Binding var card: CardItem
    let cardIndex: Int
    let onPickImage: () -> Void
    let onClearImage: () -> Void
    let onRead: () -> Void
    let onExport: () -> Void
    let onViewLarge: () -> Void
    let onDelete: () -> Void
    let readDisabled: Bool
    let isReading: Bool
    let isExporting: Bool

    private static let cardCorner: CGFloat = 18

    @State private var isHovered = false
    @State private var isTargeted = false
    @State private var copied = false
    // Normalized pointer position within the card (-0.5 ... 0.5) for the tilt.
    @State private var pointer: CGSize = .zero
    // Drives the sweeping scan shimmer while reading (-1 ... 1).
    @State private var scanX: CGFloat = -1

    private var displayImage: NSImage? { card.customImage ?? card.cachedArtwork }
    private var hasArt: Bool { displayImage != nil }

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
                .strokeBorder(card.isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06),
                              lineWidth: 1)
        )
    }

    // MARK: Card artwork with holographic hover tilt

    private var cardVisual: some View {
        let maxTilt = 9.0
        return ZStack {
            if let img = displayImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
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
        .help(hasArt ? "点击查看大图" : "拖入图片或点击下方“更换卡面”")
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
                Text(isTargeted ? "松开以放入图片" : "尚未指定卡面")
                    .font(.subheadline.weight(.medium))
                Text("拖入图片，或点击下方“更换卡面”")
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

                Label("读取中…", systemImage: "dot.radiowaves.left.and.right")
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
            .help("移除已选卡面")
        }
    }

    // MARK: Info row (selection, index, hash)

    private var infoRow: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $card.isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("加入刷写队列")

            Text("Card #\(cardIndex + 1)")
                .font(.system(size: 12, weight: .semibold))

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
                .help(copied ? "已复制" : "复制完整标识")
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())

            Spacer()

            if card.customImage != nil {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13))
                    .help("卡面已就绪，可刷写")
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("从列表移除")
        }
        .padding(.horizontal, 2)
    }

    // MARK: Action row

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(action: onPickImage) {
                Label(card.customImage == nil ? "更换卡面" : "重新选择",
                      systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("从本机选择一张图片作为卡面")

            Button(action: onRead) {
                Label(isReading ? "读取中…" : "读取卡面",
                      systemImage: isReading ? "hourglass" : "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(readDisabled)
            .help("从 iPhone 读取全部卡面素材并缓存")

            Button(action: onExport) {
                Image(systemName: isExporting ? "hourglass" : "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(card.cachedFiles.isEmpty || isExporting)
            .help("导出已读取的卡面素材（ZIP）")
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
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var fileURL: URL?
                if let url = item as? URL {
                    fileURL = url
                } else if let data = item as? Data, let urlStr = String(data: data, encoding: .utf8), let url = URL(string: urlStr) {
                    fileURL = url
                }
                if let url = fileURL, let img = NSImage(contentsOf: url) {
                    Task { @MainActor in
                        card.customImageURL = url
                        card.customImage = img
                        card.isSelected = true
                    }
                }
            }
            return true
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                if let url = item as? URL, let img = NSImage(contentsOf: url) {
                    Task { @MainActor in
                        card.customImageURL = url
                        card.customImage = img
                        card.isSelected = true
                    }
                } else if let img = item as? NSImage {
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("aircard_drop_\(UUID().uuidString).png")
                    if let tiff = img.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff),
                       let pngData = rep.representation(using: .png, properties: [:]) {
                        try? pngData.write(to: tempURL)
                    }
                    Task { @MainActor in
                        card.customImageURL = tempURL
                        card.customImage = img
                        card.isSelected = true
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
    let url: URL
    let cardLabel: String
}

private struct CachedPDFView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}

private struct CachedArtworkViewer: View {
    let item: CachedArtworkPreview
    @State private var zoom = 1.0

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("缓存卡面大图").font(.headline)
                    Text("\(item.cardLabel) · \(item.url.lastPathComponent)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
            }
            if item.url.pathExtension.lowercased() == "pdf" {
                CachedPDFView(url: item.url)
            } else if let image = NSImage(contentsOf: item.url) {
                GeometryReader { geometry in
                    let imageWidth = max(image.size.width, 1)
                    let imageHeight = max(image.size.height, 1)
                    let fit = min(geometry.size.width / imageWidth,
                                  geometry.size.height / imageHeight, 1)
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: imageWidth * fit * zoom,
                                   height: imageHeight * fit * zoom)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                HStack {
                    Text("缩放")
                    Slider(value: $zoom, in: 0.5...4)
                    Text("\(Int(zoom * 100))%")
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
            } else {
                Text("无法显示缓存图片")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
        .frame(minWidth: 900, minHeight: 650)
    }
}

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @State private var showCredits = false
    @State private var artworkPreview: CachedArtworkPreview?
    
    private var readyToFlashCount: Int {
        vm.cards.filter { $0.isSelected && $0.customImageURL != nil }.count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. Top Header Bar
            headerView
                .padding(.leading, 78)
                .padding(.trailing, 20)
                .frame(height: 58)
                .background(.bar)

            Divider()

            // 2. Card controls
            toolbarView
                .frame(height: 50)
                .padding(.horizontal, 20)
                .background(.regularMaterial)
            
            Divider()
            
            // 3. Live Scanner Notice Banner (if active)
            if vm.isScanningCards {
                scanningNoticeBanner
                Divider()
            }
            
            // 4. Main Workspace
            ScrollView {
                if vm.cards.isEmpty {
                    emptyStateView
                        .padding(.top, 40)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 330, maximum: 380), spacing: 20)],
                        spacing: 20
                    ) {
                        ForEach(Array(vm.cards.indices), id: \.self) { idx in
                            WalletCardView(
                                card: $vm.cards[idx],
                                cardIndex: idx,
                                onPickImage: { openCardImagePicker(for: vm.cards[idx].id) },
                                onClearImage: { vm.clearCardImage(for: vm.cards[idx].id) },
                                onRead: { vm.readCardArtwork(vm.cards[idx].id) },
                                onExport: { exportCardArtwork(for: vm.cards[idx].id) },
                                onViewLarge: {
                                    let url = vm.cards[idx].customImageURL ?? vm.cards[idx].cachedArtworkURL
                                    if let url {
                                        artworkPreview = CachedArtworkPreview(
                                            url: url,
                                            cardLabel: "卡片 #\(idx + 1)")
                                    }
                                },
                                onDelete: { vm.deleteCard(id: vm.cards[idx].id) },
                                readDisabled: vm.device?.connected != true || vm.isExporting || vm.isReadingArtwork || vm.isFlashing,
                                isReading: vm.readingCardID == vm.cards[idx].id,
                                isExporting: vm.exportingCardID == vm.cards[idx].id
                            )
                        }
                    }
                    .padding(20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // 5. Collapsible Activity Console (if open or flashing)
            if vm.showLogs {
                Divider()
                activityLogView
            }
            
            Divider()
            
            // 6. Bottom Action & Status Bar
            bottomBarView
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
        }
        .frame(minWidth: 880, minHeight: 680)
        .alert("Success!", isPresented: $vm.showSuccessAlert) {
            Button("OK") {}
        } message: {
            Text("Skins successfully applied to all selected cards!\n\nPlease force-close the Wallet app on your iPhone (or reboot) to see your new designs.")
        }
        .alert("卡面操作", isPresented: Binding(
            get: { vm.exportMessage != nil },
            set: { if !$0 { vm.exportMessage = nil } }
        )) {
            Button("OK") { vm.exportMessage = nil }
        } message: {
            Text(vm.exportMessage ?? "")
        }
        .sheet(isPresented: $showCredits) {
            creditsSheet
        }
        .sheet(isPresented: $vm.showAddCardSheet) {
            addCardSheet
        }
        .sheet(item: $artworkPreview) { item in
            CachedArtworkViewer(item: item)
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
                    Text("AirCard")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("v1.2.4")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(Capsule())
                }
                Text("Apple Wallet Card Skins")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Device Status Capsule
            HStack(spacing: 8) {
                Circle()
                    .fill(vm.device?.connected == true ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                
                if let dev = vm.device, dev.connected {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(dev.name ?? "iPhone")
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Text("\(dev.product ?? "") · iOS \(dev.version ?? "")")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("No iPhone (USB)")
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
                .help("Refresh device connection")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(height: 32)
            .background(.quaternary, in: Capsule())
            
            Button(action: { showCredits = true }) {
                Label("Credits", systemImage: "heart.fill")
                    .foregroundColor(.pink)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .controlSize(.regular)
        .frame(height: 54)
    }
    
    private var toolbarView: some View {
        HStack(spacing: 12) {
            // Live Scanner Toggle
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
                    Text(vm.isScanningCards ? "Stop Scanning" : "Scan Cards")
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.isScanningCards ? .red : .blue)
            .controlSize(.regular)
            .disabled(vm.device?.connected != true)
            
            Button(action: { vm.showAddCardSheet = true }) {
                Label("Add Manually", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            
            if !vm.cards.isEmpty {
                Button(action: openBulkImagePicker) {
                    Label("Set Skin for All...", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Assign one skin to all selected cards")
            }
            
            Spacer()
            
            if !vm.cards.isEmpty {
                HStack(spacing: 8) {
                    Button("Select All") {
                        for idx in vm.cards.indices { vm.cards[idx].isSelected = true }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    
                    Text("·").foregroundColor(.secondary)
                    
                    Button("Deselect All") {
                        for idx in vm.cards.indices { vm.cards[idx].isSelected = false }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    
                    Text("·").foregroundColor(.secondary)
                    
                    Button("Clear All") {
                        vm.clearAllCards()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .foregroundColor(.red)
                }
            }
        }
        .controlSize(.regular)
        .frame(height: 48)
    }
    
    private var scanningNoticeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 20))
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Live Scanner Active")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
                Text("Double-click Side button (Apple Pay), pass Face ID, then tap your card.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Done") {
                vm.stopCardScanning()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.1))
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 18) {
            Image(systemName: "creditcard.viewfinder")
                .font(.system(size: 54))
                .foregroundColor(.accentColor.opacity(0.8))
            
            Text("No Cards Detected Yet")
                .font(.title3)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text("1.")
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Text("Click **Scan Cards** in the toolbar above.")
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("2.")
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Text("On your iPhone, **double-click the Side button** (Apple Pay), authenticate with **Face ID**, and **tap your card**.")
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("3.")
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Text("Your card will be detected immediately!")
                }
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            .frame(maxWidth: 460)
            .padding(20)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            
            HStack(spacing: 12) {
                Button(action: { vm.startCardScanning() }) {
                    Label("Start Scanning", systemImage: "wave.3.forward.circle.fill")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(vm.device?.connected != true)
                
                Button("Add Hashes Manually") {
                    vm.showAddCardSheet = true
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(40)
    }
    
    private var activityLogView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Activity Log")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear") {
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
            if vm.isFlashing || vm.progress > 0 {
                ProgressView(value: vm.progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .animation(.easeInOut(duration: 0.2), value: vm.progress)
            }
            
            HStack(spacing: 16) {
                // Left Status Text
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(vm.statusText)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        if vm.isFlashing || vm.progress > 0 {
                            Text("\(Int(min(max(vm.progress, 0.0), 1.0) * 100))%")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                    
                    if !vm.cards.isEmpty {
                        Text("\(vm.cards.filter { $0.isSelected }.count) of \(vm.cards.count) cards selected · \(readyToFlashCount) ready to flash")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Toggle Log Drawer
                Button(action: { withAnimation { vm.showLogs.toggle() } }) {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal")
                            .frame(width: 14, height: 14)
                        Text("Log")
                        Image(systemName: vm.showLogs ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                
                // Apply / Flash Button
                Button(action: { vm.applySkin() }) {
                    HStack(spacing: 6) {
                        if vm.isFlashing {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "sparkles")
                                .frame(width: 16, height: 16)
                        }
                        Text(vm.isFlashing ? "Flashing Cards..." : (readyToFlashCount > 0 ? "Flash Skins (\(readyToFlashCount) Cards)" : "Flash Skins"))
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.regular)
                .disabled(readyToFlashCount == 0 || vm.isFlashing || vm.isExporting || vm.isReadingArtwork || vm.device?.connected != true)
            }
            
            // Subtle Footer Credits
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Text("By")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Link("@mak5er", destination: URL(string: "https://github.com/mak5er")!)
                        .font(.system(size: 10))
                    Text("&")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Link("@Lumid-Off", destination: URL(string: "https://github.com/Lumid-Off")!)
                        .font(.system(size: 10))
                }
            }
        }
    }
    
    // MARK: - Sheets & Pickers
    
    private var creditsSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "creditcard.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
            
            Text("AirCard")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Apple Wallet Card Skins for iOS 18+")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundColor(.blue)
                    Text("Developer:")
                        .fontWeight(.medium)
                    Link("@mak5er", destination: URL(string: "https://github.com/mak5er")!)
                    Text("·")
                        .foregroundColor(.secondary)
                    Link("Twitter / X", destination: URL(string: "https://x.com/mak5er")!)
                }
                
                HStack {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundColor(.blue)
                    Text("Developer:")
                        .fontWeight(.medium)
                    Link("@Lumid-Off", destination: URL(string: "https://github.com/Lumid-Off")!)
                    Text("·")
                        .foregroundColor(.secondary)
                    Link("Twitter / X", destination: URL(string: "https://x.com/LumidOff")!)
                }
                
                HStack {
                    Image(systemName: "bolt.shield.fill")
                        .foregroundColor(.orange)
                    Text("Core Exploit:")
                        .fontWeight(.medium)
                    Text("airlift (AirTraffic sync escape)")
                        .foregroundColor(.secondary)
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            
            Divider()
            
            Button("Close") {
                showCredits = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(24)
        .frame(width: 420)
    }
    
    private var addCardSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Card Hashes Manually")
                .font(.headline)
            Text("Paste one or more card hashes (separated by spaces, commas, or newlines):")
                .font(.caption)
                .foregroundColor(.secondary)
            
            TextEditor(text: $vm.manualHashInput)
                .font(.system(.body, design: .monospaced))
                .frame(height: 120)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            
            HStack {
                Button("Cancel") {
                    vm.showAddCardSheet = false
                    vm.manualHashInput = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                
                Spacer()
                
                Button("Add to List") {
                    vm.addCardHash(vm.manualHashInput)
                    vm.showAddCardSheet = false
                    vm.manualHashInput = ""
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(vm.manualHashInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 440)
    }
    
    private func openCardImagePicker(for cardId: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a custom skin for card \(cardId.prefix(12))..."
        if panel.runModal() == .OK, let url = panel.url {
            vm.setCardImage(for: cardId, url: url)
        }
    }

    private func exportCardArtwork(for cardId: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "AirCard-\(cardId.prefix(12)).zip"
        panel.message = "导出已读取的全部卡面素材（PNG 与 PDF）为 ZIP。"
        if panel.runModal() == .OK, let url = panel.url {
            vm.exportCachedArtwork(cardId, to: url)
        }
    }
    
    private func openBulkImagePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a skin to assign to all selected cards..."
        if panel.runModal() == .OK, let url = panel.url {
            for card in vm.cards where card.isSelected {
                vm.setCardImage(for: card.id, url: url)
            }
        }
    }
    

}

// MARK: - App Entry Point

@main
struct AirCardApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
