import Foundation

/// 合并覆盖窗口与 UU 被控设备表格，保留切屏期间的断开防抖。
struct UUConnectionState {
    enum Event: Equatable { case connected, controllerChanged, disconnected }
    private(set) var connected = false
    private var lastSeen = Date.distantPast
    private var controller: String?
    private let debounce: TimeInterval = 1.5
    /// 连入也要确认：UU 覆盖窗口在本工具改显示拓扑（新建/设主屏）时会短暂重建，
    /// 只看到一次就判连入，会和「断开防抖」一起形成自激振荡：
    /// 建屏 → 改拓扑 → 窗口消失 → 误判断开 → 拆屏 → 窗口回来 → 再建屏……
    /// 要求「已连入」信号持续 connectConfirm 秒才真正连入。
    private let connectConfirm: TimeInterval = 1.5
    private var firstSeenAt: Date?

    mutating func update(overlay: Bool, controllers: [String]?, now: Date) -> Event? {
        let name = controllers?.first
        if overlay || name != nil {
            lastSeen = now
            if !connected {
                let first = firstSeenAt ?? now
                firstSeenAt = first
                guard now.timeIntervalSince(first) >= connectConfirm else { return nil }
                connected = true
                controller = name
                firstSeenAt = nil
                return .connected
            }
            if let name, name != controller {
                controller = name
                return .controllerChanged
            }
        } else {
            firstSeenAt = nil
            guard connected, now.timeIntervalSince(lastSeen) > debounce else { return nil }
            connected = false
            controller = nil
            return .disconnected
        }
        return nil
    }
}
