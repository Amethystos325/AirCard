import Foundation

/// A persistent connection to the same transaction engine used by the two-platform app.
/// All callbacks and continuations are completed on the main actor.
@MainActor
final class SwiftDesktopBridge {
    enum BridgeError: LocalizedError {
        case unavailable
        case backend(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "BACKEND_OFFLINE"
            case .backend(let code): return code
            }
        }
    }

    var onEvent: (([String: Any]) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var readHandle: FileHandle?
    private var output = Data()
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]

    func start() throws {
        if process?.isRunning == true { return }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("backend/\(architecture)/aircard-backend"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("frontend/cross-platform/src-tauri/binaries/backend/aircard-backend"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/desktop-backend/aircard-backend/aircard-backend")
        ].compactMap { $0 }
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw BridgeError.unavailable
        }
        let child = Process()
        child.executableURL = binary
        child.currentDirectoryURL = binary.deletingLastPathComponent()
        let stdin = Pipe(), stdout = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        let logRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirCardDesktop/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logRoot, withIntermediateDirectories: true)
        let logURL = logRoot.appendingPathComponent("swift-backend.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let diagnostic = try FileHandle(forWritingTo: logURL)
        try diagnostic.seekToEnd()
        child.standardError = diagnostic
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        readHandle = stdout.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { @MainActor in self?.received(bytes) }
        }
    }

    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard process?.isRunning == true, let input else { throw BridgeError.unavailable }
        let id = UUID().uuidString
        let message: [String: Any] = ["v": 1, "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: message) + Data([0x0a])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try input.write(contentsOf: data) }
            catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: BridgeError.unavailable)
            }
        }
    }

    func shutdown() async {
        guard process?.isRunning == true else { return }
        _ = try? await request("shutdown")
        input = nil
    }

    private func received(_ bytes: Data) {
        if bytes.isEmpty { failed(); return }
        var start = bytes.startIndex
        while let newline = bytes[start...].firstIndex(of: 0x0a) {
            output.append(contentsOf: bytes[start..<newline])
            let line = output
            output = Data()
            start = bytes.index(after: newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = object["id"] as? String, let continuation = pending.removeValue(forKey: id) {
                if object["ok"] as? Bool == true {
                    continuation.resume(returning: object["result"] as? [String: Any] ?? [:])
                } else {
                    let error = object["error"] as? [String: Any]
                    continuation.resume(throwing: BridgeError.backend(error?["code"] as? String ?? "OPERATION_FAILED"))
                }
            } else if object["event"] != nil {
                onEvent?(object)
            }
        }
        output.append(contentsOf: bytes[start...])
    }

    private func failed() {
        guard process != nil else { return }
        readHandle?.readabilityHandler = nil
        readHandle = nil
        process = nil
        input = nil
        for continuation in pending.values { continuation.resume(throwing: BridgeError.unavailable) }
        pending.removeAll()
        onEvent?(["event": "fatal", "code": "BACKEND_OFFLINE"])
    }
}
