import CoreGraphics
import Foundation

// 不写用户日志、不启用/禁用屏幕，也不连接 UU。
enum Log { static func info(_ message: String) {} }
enum PhysicalDisplays {
    static var pending: [CGDirectDisplayID]?
    static func restore(reason: String) -> Bool { preconditionFailure("unexpected physical display operation") }
    static func disable(_ ids: [CGDirectDisplayID]) -> CGError { preconditionFailure("unexpected physical display operation") }
}
func applyDisplayConfig(_ body: (CGDisplayConfigRef?) -> Void) -> CGError {
    preconditionFailure("unexpected real display configuration")
}

@main struct DisplayRecoveryTests {
    static let layout: [CGDirectDisplayID: CGRect] = [1: CGRect(x: 0, y: 0, width: 1920, height: 1080)]
    static let origins: [CGDirectDisplayID: CGPoint] = [1: CGPoint(x: 100, y: 200)]
    static let marker = Data("{\"1\":[100,200]}".utf8)

    static func pump(_ seconds: TimeInterval = 0.6) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func waitUntil(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { pump(0.05) }
        precondition(predicate(), "async operation did not complete")
    }

    static func main() throws {
        // 热插拔、位置变化及读失败均打断稳定窗口；一直不稳定时有上限。
        var gate = DisplayLayoutStability()
        precondition(gate.observe(layout, now: 0) == .wait)
        precondition(gate.observe(layout, now: 2.9) == .wait)
        let moved: [CGDirectDisplayID: CGRect] = [1: CGRect(x: 50, y: 0, width: 1920, height: 1080)]
        precondition(gate.observe(moved, now: 3) == .wait)
        precondition(gate.observe(moved, now: 5.9) == .wait)
        precondition(gate.observe(moved, now: 6) == .ready)
        gate.reset()
        let withExtra = layout.merging([2: CGRect(x: 1920, y: 0, width: 1280, height: 720)]) { _, new in new }
        precondition(gate.observe(withExtra, now: 0) == .wait)
        precondition(gate.observe(layout, now: 2.9) == .wait)
        precondition(gate.observe(layout, now: 5.8) == .wait)
        precondition(gate.observe(layout, now: 6) == .ready)
        gate.reset()
        precondition(gate.observe(layout, now: 0) == .wait)
        precondition(gate.observe(nil, now: 2) == .wait)
        precondition(gate.observe(layout, now: 3) == .wait)
        precondition(gate.observe([:], now: 5) == .wait)
        precondition(gate.observe([:], now: 15) == .timedOut)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.json")
        try marker.write(to: url)
        var now: TimeInterval = 0
        var attempts = 0
        var notifications = 0
        let manager = DisplayManager(markerURL: url, layoutSnapshot: { layout }, restoreLayout: { saved in
            precondition(!Thread.isMainThread, "CoreGraphics work must stay off main")
            precondition(saved == origins, "original layout was lost")
            attempts += 1
            return attempts == 1 ? CGError(rawValue: 1014)! : .success
        }, uptime: { now })
        manager.onChange = { notifications += 1 }
        manager.recoverIfNeeded()
        precondition(attempts == 0, "must observe stability before restoring")
        now = 3
        waitUntil { manager.canRetryLayout }
        precondition(manager.wedged && attempts == 1)
        precondition((try? Data(contentsOf: url)) == marker, "failed restore deleted journal")
        PhysicalDisplays.pending = [1]
        precondition(!manager.canRetryLayout && !manager.retryLayoutRestore(), "physical displays must be restored first")
        PhysicalDisplays.pending = nil
        pump()
        precondition(attempts == 1, "failure must not cause automatic retry")
        precondition(manager.retryLayoutRestore())
        precondition(!manager.retryLayoutRestore(), "double click must not queue retries")
        precondition(manager.wedged, "do not clear protection before successful restore")
        now = 6
        waitUntil { !manager.wedged }
        precondition(attempts == 2 && !FileManager.default.fileExists(atPath: url.path))
        precondition(notifications > 0, "status changes must refresh the menu")
        pump()

        // 非超时错误也不循环；重连取消等待中的手动重试，保护不能被普通连入绕过。
        try marker.write(to: url)
        var failures = 0
        now = 10
        let failed = DisplayManager(markerURL: url, layoutSnapshot: { layout }, restoreLayout: { _ in
            failures += 1
            return .illegalArgument
        }, uptime: { now })
        failed.recoverIfNeeded()
        now = 13
        waitUntil { failed.canRetryLayout }
        precondition(failures == 1 && (try? Data(contentsOf: url)) == marker)
        precondition(failed.retryLayoutRestore())
        now = 16
        waitUntil { failed.canRetryLayout }
        precondition(failures == 2 && failed.wedged && (try? Data(contentsOf: url)) == marker)
        precondition(failed.retryLayoutRestore())
        failed.cancelLayoutRetry()
        failed.create(DeviceConfig(name: "test", kind: .phone, width: 1920, height: 1080))
        now = 20
        pump()
        precondition(failures == 2 && failed.wedged && !failed.isActive)
        precondition(!failed.canRetryLayout)
        failed.remove()
        precondition(failed.canRetryLayout)
        precondition(failed.retryLayoutRestore())
        var shutDown = false
        failed.remove { shutDown = true }
        waitUntil { shutDown }
        precondition(failures == 2 && FileManager.default.fileExists(atPath: url.path))

        // 模拟重开：从保留的磁盘记录继续收尾，成功后才删除。
        now = 30
        let restarted = DisplayManager(markerURL: url, layoutSnapshot: { layout }, restoreLayout: { saved in
            precondition(saved == origins)
            return .success
        }, uptime: { now })
        restarted.recoverIfNeeded()
        now = 33
        waitUntil { !FileManager.default.fileExists(atPath: url.path) }
        precondition(!restarted.wedged)
        pump()

        // 始终读不到有效布局：不发起事务、不丢记录，仍能退出。
        try marker.write(to: url)
        now = 40
        let unstable = DisplayManager(markerURL: url, layoutSnapshot: { nil }, restoreLayout: { _ in
            preconditionFailure("must not restore an unstable layout")
        }, uptime: { now })
        unstable.recoverIfNeeded()
        now = 55
        waitUntil { unstable.canRetryLayout }
        precondition((try? Data(contentsOf: url)) == marker)
        var finished = false
        unstable.remove { finished = true }
        precondition(finished)
        print("PASS: stable-window gate; failed journal retained; bounded manual retry; protection until success; reconnect cancellation; shutdown; restart recovery; unstable-layout timeout")
    }
}
