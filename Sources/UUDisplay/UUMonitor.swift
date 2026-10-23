// 单一后台读取器合并覆盖窗口和 UU 被控设备表格；控制逻辑复用同一份名称快照。
import CoreGraphics
import Foundation

final class UUMonitor {
    static let defaultPollInterval: TimeInterval = 2
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onControllersRead: (() -> Void)?
    private(set) var connected = false
    private(set) var controllers: [String]?
    private(set) var hasControllerSnapshot = false

    private var timer: Timer?
    private var session = UUConnectionState()
    private let readerQueue = DispatchQueue(label: "uudisplay.controller-reader", qos: .utility)
    private var readInFlight = false
    private var controllersReadAt = Date.distantPast
    private var overlay = false
    private var windowOpenRequested = false
    private var generation = 0
    private let pollInterval: TimeInterval
    private let trusted: () -> Bool
    private let readControllers: () -> [String]?
    private let hasOverlay: () -> Bool
    private let showMainWindow: () -> Bool

    init(pollInterval: TimeInterval = UUMonitor.defaultPollInterval,
         trusted: @escaping () -> Bool = { UUReader.isTrusted },
         readControllers: @escaping () -> [String]? = { UUReader.readControllers() },
         hasOverlay: @escaping () -> Bool = { UUMonitor.overlayPresent() },
         showMainWindow: @escaping () -> Bool = { UUReader.showMainWindow() }) {
        self.pollInterval = pollInterval
        self.trusted = trusted
        self.readControllers = readControllers
        self.hasOverlay = hasOverlay
        self.showMainWindow = showMainWindow
    }

    var controllerName: String? {
        Date().timeIntervalSince(controllersReadAt) <= pollInterval + 1 ? controllers?.first : nil
    }

    static func overlayPresent() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowOwnerName as String] as? String) == "UURemoteServer" }
    }

    func start() {
        guard timer == nil else { return }
        generation += 1
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = min(0.25, pollInterval * 0.1)
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        readInFlight = false
        controllers = nil
        hasControllerSnapshot = false
        controllersReadAt = .distantPast
        connected = false
        session = UUConnectionState()
        windowOpenRequested = false
    }

    /// 仅在已确认连入、第一次读取确实没有窗口时尝试一次；不另起轮询。
    func requestMainWindowIfNeeded() {
        guard connected, hasControllerSnapshot, controllers == nil, !windowOpenRequested else { return }
        windowOpenRequested = true
        Log.info("UU 未提供可读主窗口，后台尝试打开一次以识别控制端")
        let show = showMainWindow
        readerQueue.async { autoreleasepool { _ = show() } }
    }

    private func tick() {
        // 每个周期只枚举一次覆盖窗口，AX 回调复用该快照。
        overlay = hasOverlay()
        guard trusted() else {
            controllers = nil
            hasControllerSnapshot = false
            controllersReadAt = .distantPast
            apply(controllers: nil)
            return
        }
        let fresh = Date().timeIntervalSince(controllersReadAt) <= pollInterval + 1
        apply(controllers: fresh ? controllers : nil)
        guard !readInFlight else { return }
        readInFlight = true
        let started = Date()
        let read = readControllers
        let currentGeneration = generation
        readerQueue.async { [weak self] in
            // AX 树和桥接对象每次读完释放；只保留少量设备名称字符串。
            let result = autoreleasepool { read() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration, self.timer != nil else { return }
                self.readInFlight = false
                let valid = Date().timeIntervalSince(started) <= 2 && self.trusted()
                self.controllers = valid ? result : nil
                self.hasControllerSnapshot = valid
                self.controllersReadAt = valid ? Date() : .distantPast
                self.apply(controllers: self.controllers)
                self.onControllersRead?()
            }
        }
    }

    private func apply(controllers: [String]?) {
        switch session.update(overlay: overlay, controllers: controllers, now: Date()) {
        case .connected:
            connected = true
            Log.info("检测到 UU 连入（覆盖窗口或被控设备表格）")
            onConnect?()
        case .controllerChanged:
            Log.info("检测到 UU 控制端变化")
            onConnect?()
        case .disconnected:
            connected = false
            windowOpenRequested = false
            Log.info("检测到 UU 断开")
            onDisconnect?()
        case nil:
            break
        }
    }

    deinit { timer?.invalidate() }
}
