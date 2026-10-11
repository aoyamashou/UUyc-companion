// 合并覆盖窗口与 UU 被控设备表格，兼容没有覆盖窗口的远控会话。
import CoreGraphics
import Foundation

final class UUMonitor {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    private(set) var connected = false

    private var timer: Timer?
    private var session = UUConnectionState()
    private let readerQueue = DispatchQueue(label: "uudisplay.controller-reader", qos: .utility)
    private var readInFlight = false
    private var controllers: [String]?
    private var controllersReadAt = Date.distantPast

    private let trusted: () -> Bool
    private let readControllers: () -> [String]?
    private let hasOverlay: () -> Bool

    init(trusted: @escaping () -> Bool = { UUReader.isTrusted },
         readControllers: @escaping () -> [String]? = { UUReader.readControllers() },
         hasOverlay: @escaping () -> Bool = { UUMonitor.overlayPresent() }) {
        self.trusted = trusted
        self.readControllers = readControllers
        self.hasOverlay = hasOverlay
    }

    static func overlayPresent() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowOwnerName as String] as? String) == "UURemoteServer" }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    private func tick() {
        guard trusted() else {
            controllers = nil
            controllersReadAt = .distantPast
            apply(controllers: nil)
            return
        }
        // 每次 tick 仍检测覆盖窗口；AX 卡顿不能阻塞原来的检测路径。
        let fresh = Date().timeIntervalSince(controllersReadAt) <= 1
        apply(controllers: fresh ? controllers : nil)
        // AX 调用可能阻塞；后台串行读取且不堆积任务。
        guard !readInFlight else { return }
        readInFlight = true
        let started = Date()
        let read = readControllers
        readerQueue.async { [weak self] in
            let controllers = read()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readInFlight = false
                // 不使用延迟过久的界面快照确认连接。
                self.controllers = Date().timeIntervalSince(started) <= 2 ? controllers : nil
                self.controllersReadAt = Date()
                self.apply(controllers: self.controllers)
            }
        }
    }

    private func apply(controllers: [String]?) {
        switch session.update(overlay: hasOverlay(), controllers: controllers, now: Date()) {
        case .connected:
            connected = true
            Log.info("检测到 UU 连入（覆盖窗口或被控设备表格）")
            onConnect?()
        case .controllerChanged:
            Log.info("检测到 UU 控制端变化")
            onConnect?()
        case .disconnected:
            connected = false
            Log.info("检测到 UU 断开")
            onDisconnect?()
        case nil:
            break
        }
    }
}
