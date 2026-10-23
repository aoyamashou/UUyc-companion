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
        let manager = DisplayManager(powerPhase: { _ in }, canWriteLayout: { true }, markerURL: url, layoutSnapshot: { layout }, restoreLayout: { saved in
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
        let failed = DisplayManager(powerPhase: { _ in }, canWriteLayout: { true }, markerURL: url, layoutSnapshot: { layout }, restoreLayout: { _ in
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
        let restarted = DisplayManager(powerPhase: { _ in }, canWriteLayout: { true }, markerURL: url, layoutSnapshot: { layout }, restoreLayout: { saved in
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
        let unstable = DisplayManager(powerPhase: { _ in }, canWriteLayout: { true }, markerURL: url, layoutSnapshot: { nil }, restoreLayout: { _ in
            preconditionFailure("must not restore an unstable layout")
        }, uptime: { now })
        unstable.recoverIfNeeded()
        now = 55
        waitUntil { unstable.canRetryLayout }
        precondition((try? Data(contentsOf: url)) == marker)
        var finished = false
        unstable.remove { finished = true }
        precondition(finished)
        // 已经匹配的布局：即使睡眠中也只读确认，禁止提交无效重配置。
        try marker.write(to: url)
        now = 100
        let matching: [CGDirectDisplayID: CGRect] = [1: CGRect(x: 100, y: 200, width: 1920, height: 1080)]
        let noOp = DisplayManager(powerPhase: { _ in }, canWriteLayout: { false },
            markerURL: url, layoutSnapshot: { matching }, restoreLayout: { _ in
                preconditionFailure("matching layout must not submit a transaction")
            }, uptime: { now })
        noOp.recoverIfNeeded()
        now = 103
        waitUntil { !FileManager.default.fileExists(atPath: url.path) }
        precondition(!noOp.wedged && !noOp.waitingForDisplayWake)
        pump()

        // 睡眠时间不计入稳定等待超时；唤醒后重新计时，只执行一次还原。
        try marker.write(to: url)
        now = 200
        var awake = false
        var sleepAttempts = 0
        var phases: [DisplayRecoveryPowerGuard.Phase] = []
        let sleeping = DisplayManager(powerPhase: { phases.append($0) }, canWriteLayout: { awake },
            markerURL: url, layoutSnapshot: { layout }, restoreLayout: { saved in
                precondition(saved == origins)
                sleepAttempts += 1
                return .success
            }, uptime: { now })
        sleeping.recoverIfNeeded()
        precondition(sleeping.waitingForDisplayWake && !sleeping.wedged)
        precondition(phases.last == .inactive, "sleep deferral must release the wake hold")
        now = 800
        pump(1.1)
        precondition(sleepAttempts == 0 && !sleeping.wedged && FileManager.default.fileExists(atPath: url.path))
        awake = true
        waitUntil { !sleeping.waitingForDisplayWake }
        precondition(sleepAttempts == 0, "wake must start a new stable window")
        now = 803
        waitUntil { !FileManager.default.fileExists(atPath: url.path) }
        precondition(sleepAttempts == 1 && !sleeping.wedged && phases.last == .inactive)
        pump()

        // 屏幕休眠时退出不等待用户唤醒，不提交事务，仍保留恢复记录。
        try marker.write(to: url)
        now = 850
        let exitSleeping = DisplayManager(powerPhase: { _ in }, canWriteLayout: { false },
            markerURL: url, layoutSnapshot: { layout }, restoreLayout: { _ in
                preconditionFailure("shutdown during sleep must not configure displays")
            }, uptime: { now })
        exitSleeping.recoverIfNeeded()
        var sleepShutdownFinished = false
        exitSleeping.remove { sleepShutdownFinished = true }
        waitUntil { sleepShutdownFinished }
        precondition(FileManager.default.fileExists(atPath: url.path) && !exitSleeping.wedged)

        // 后台提交前再次发现睡眠：仍不提交、不中断记录、不进入保护。
        try marker.write(to: url)
        now = 900
        let beforeSubmit = DisplayManager(powerPhase: { _ in },
            canWriteLayout: { Thread.isMainThread }, markerURL: url,
            layoutSnapshot: { layout }, restoreLayout: { _ in
                preconditionFailure("sleep between readiness and submission must defer")
            }, uptime: { now })
        beforeSubmit.recoverIfNeeded()
        now = 903
        waitUntil { beforeSubmit.waitingForDisplayWake }
        precondition(!beforeSubmit.wedged && FileManager.default.fileExists(atPath: url.path))

        // 防休眠请求先取得再释放旧请求，收尾不重复续租，结束及时释放。
        var powerEvents: [String] = []
        var nextID: UInt32 = 0
        var failLease = false
        var power: DisplayRecoveryPowerGuard? = DisplayRecoveryPowerGuard(
            lease: 45, renewalInterval: 0.05, create: { timeout in
                precondition(timeout == 45)
                if failLease { powerEvents.append("failed"); return nil }
                nextID += 1
                powerEvents.append("create \(nextID)")
                return nextID
            }, release: { powerEvents.append("release \($0)") })
        power!.setPhase(.connected)
        precondition(powerEvents == ["create 1"])
        power!.setPhase(.connected)
        precondition(nextID == 1)
        pump(0.12)
        precondition(nextID >= 2, "connected session must renew the bounded lease")
        power!.setPhase(.restoring)
        let handoffID = nextID
        let countAtHandoff = powerEvents.count
        precondition(powerEvents.suffix(2) == ["create \(handoffID)", "release \(handoffID - 1)"])
        pump(0.12)
        precondition(powerEvents.count == countAtHandoff, "teardown must not renew indefinitely")
        power!.setPhase(.inactive)
        precondition(powerEvents.last == "release \(handoffID)")
        power!.setPhase(.connected)
        let heldID = nextID
        failLease = true
        pump(0.07)
        precondition(powerEvents.last == "failed")
        precondition(!powerEvents.contains("release \(heldID)"), "failed renewal must keep the previous lease")
        power = nil
        precondition(powerEvents.last == "release \(heldID)", "deinit must release the live lease")

        print("PASS: sleep deferral and wake recovery; matching-layout no-op; worker sleep recheck; bounded power handoff and release")
        print("PASS: stable-window gate; failed journal retained; bounded manual retry; protection until success; reconnect cancellation; shutdown; restart recovery; unstable-layout timeout")
    }
}
