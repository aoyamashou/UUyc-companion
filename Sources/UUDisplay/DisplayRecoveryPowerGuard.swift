// 先于 UU 的防休眠请求释放接棒；断开后的租约有硬超时，退出/失败即释放。
import Foundation
import IOKit.pwr_mgt

final class DisplayRecoveryPowerGuard {
    enum Phase { case inactive, connected, restoring }
    static let shared = DisplayRecoveryPowerGuard()
    private(set) var phase: Phase = .inactive
    private var assertion: IOPMAssertionID?
    private var timer: Timer?
    private let create: (TimeInterval) -> IOPMAssertionID?
    private let release: (IOPMAssertionID) -> Void
    private let lease: TimeInterval
    private let renewalInterval: TimeInterval

    init(lease: TimeInterval = 45, renewalInterval: TimeInterval = 20,
         create: @escaping (TimeInterval) -> IOPMAssertionID? = DisplayRecoveryPowerGuard.createAssertion,
         release: @escaping (IOPMAssertionID) -> Void = { _ = IOPMAssertionRelease($0) }) {
        self.lease = lease
        self.renewalInterval = renewalInterval
        self.create = create
        self.release = release
    }

    func setPhase(_ next: Phase) {
        guard next != phase else { return }
        phase = next
        timer?.invalidate()
        timer = nil
        if next == .inactive {
            if let assertion { release(assertion) }
            assertion = nil
            return
        }
        renew()
        if next == .connected {
            timer = Timer.scheduledTimer(withTimeInterval: renewalInterval, repeats: true) { [weak self] _ in
                self?.renew()
            }
        }
        // restoring 不续租：收尾卡住时也会在 45 秒后自动放行屏幕休眠。
    }

    private func renew() {
        guard let next = create(lease) else {
            Log.info("⚠️ 无法取得显示恢复防休眠租约；仍会检查屏幕是否休眠")
            return
        }
        // 新请求取得后再释放旧请求，连接转收尾或续租时没有空档。
        let previous = assertion
        assertion = next
        if let previous { release(previous) }
    }

    private static func createAssertion(timeout: TimeInterval) -> IOPMAssertionID? {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            "UUDisplay display recovery handoff" as CFString,
            "Hold through remote disconnect and display layout restoration" as CFString,
            nil, nil, timeout, kIOPMAssertionTimeoutActionRelease as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    deinit {
        timer?.invalidate()
        if let assertion { release(assertion) }
    }
}
