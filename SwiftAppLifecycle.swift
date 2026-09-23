import AppKit

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    static weak var bridge: SwiftDesktopBridge?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let bridge = Self.bridge else { return .terminateNow }
        Task {
            await bridge.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
