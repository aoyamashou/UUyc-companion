// 连入/断开 → 选设备配置 → 建屏/还原
// 只处理 UU 设备列表里、且填了分辨率的设备；读不到名字或认不出就不调整，交给 UU远程 自己处理
import AppKit

final class Coordinator {
    let monitor = UUMonitor()
    let display = DisplayManager()
    private let store = ConfigStore.shared

    /// 状态变化时通知菜单栏刷新
    var onChange: (() -> Void)?

    private(set) var controllerName: String?

    /// 调试：模拟连入的控制端名称（不读 UU）
    var simulatedName: String?

    var connected: Bool { monitor.connected || simulatedName != nil }

    func start() {
        display.shouldDisablePhysical = { [weak self] in self?.physicalDisableAllowed ?? false }
        display.onChange = { [weak self] in self?.onChange?() }
        display.recoverIfNeeded()
        monitor.onConnect = { [weak self] in self?.handleConnect() }
        monitor.onDisconnect = { [weak self] in self?.handleDisconnect() }
        monitor.onControllersRead = { [weak self] in self?.updateControllerFromSnapshot() }
        monitor.start()
    }

    /// 开关打开且私有 API 可用时关闭物理屏；看门狗是可选兜底（快捷键 ⌃⌥⌘9 始终可用）
    var physicalDisableAllowed: Bool {
        store.config.shouldDisablePhysical && PhysicalDisplays.available
    }

    var statusText: String {
        if display.waitingForDisplayWake { return "屏幕休眠中，唤醒后继续还原布局" }
        if display.wedged {
            if display.retryingLayout { return "正在重试还原显示器布局…" }
            return canRetryLayout ? "⚠️ 屏幕设置已暂停，可重试布局还原"
                : "⚠️ 屏幕设置已暂停，请断开远程后重试或重开伴侣"
        }
        if store.config.paused { return "虚拟屏已暂停：连接时不做调整" }
        guard connected else { return "等待其它设备连接中" }
        let who = controllerName ?? "未知设备"
        if let c = display.current, display.isActive {
            return "\(who) 已连接 · 虚拟屏已匹配 \(c.sizeLabel)\(display.physicalOff ? " · 物理屏幕已软关闭" : "")"
        }
        return "\(who) 已连接 · 虚拟屏没有调整"
    }

    // MARK: - 事件

    func handleConnect() {
        display.setRemoteConnected(true)
        display.cancelLayoutRetry()
        controllerName = nil
        onChange?()
        updateControllerFromSnapshot()
    }

    func handleDisconnect() {
        display.setRemoteConnected(false)
        display.remove()
        controllerName = nil
        onChange?()
    }

    private func updateControllerFromSnapshot() {
        guard connected, !store.config.paused else { return }
        if let name = simulatedName ?? monitor.controllerName {
            if name != controllerName { resolve(name) }
        } else {
            monitor.requestMainWindowIfNeeded()
        }
    }

    private func resolve(_ name: String) {
        controllerName = name
        Log.info("控制端：\(name)")
        let cfg: DeviceConfig?
        if let known = store.device(named: name) {
            cfg = known
        } else if simulatedName != nil {
            // 调试模拟：未配置的名称用固定测试尺寸
            cfg = DeviceConfig(name: name, kind: .tablet, width: 2360, height: 1640)
        } else {
            cfg = nil
            Log.info("「\(name)」不在设备列表里，不调整")
        }
        apply(cfg)
    }

    private func apply(_ cfg: DeviceConfig?) {
        defer { onChange?() }
        guard let cfg, cfg.kind != .computer, cfg.hasSize else {
            if display.isActive { display.remove() }
            Log.info(cfg == nil ? "无可用配置，不切换" : "「\(cfg!.name)」不指定分辨率或还没填写，不切换")
            return
        }
        if display.matches(cfg) { return }
        display.create(cfg)
    }

    // MARK: - 菜单操作

    var canRetryLayout: Bool { !connected && display.canRetryLayout }

    func retryLayoutRestore() {
        guard !connected else { return }
        display.retryLayoutRestore()
        onChange?()
    }

    func setPaused(_ paused: Bool) {
        store.config.paused = paused
        if paused {
            display.remove()
        } else if connected {
            handleConnect()
        }
        onChange?()
    }

    /// 配置变更后，若正在被控则按新配置重新应用
    func configChanged() {
        if connected, !store.config.paused {
            if let name = controllerName { resolve(name) } else { handleConnect() }
        }
        onChange?()
    }

    /// 快捷键 ⌃⌥⌘9 / 菜单：立即恢复物理屏
    func restorePhysical() {
        Log.info("手动恢复物理屏")
        display.restorePhysicalNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func setDisablePhysical(_ on: Bool) {
        store.config.disablePhysical = on
        if on { display.disablePhysicalIfNeeded() } else { display.restorePhysicalNow(override: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func shutdown(completion: @escaping () -> Void) {
        monitor.stop()
        display.setRemoteConnected(false)
        display.remove(completion: completion)
    }
}
