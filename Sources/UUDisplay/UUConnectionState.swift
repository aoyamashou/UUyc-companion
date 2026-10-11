import Foundation

/// 合并覆盖窗口与 UU 被控设备表格，保留切屏期间的断开防抖。
struct UUConnectionState {
    enum Event: Equatable { case connected, controllerChanged, disconnected }
    private(set) var connected = false
    private var lastSeen = Date.distantPast
    private var controller: String?
    private let debounce: TimeInterval = 1.5

    mutating func update(overlay: Bool, controllers: [String]?, now: Date) -> Event? {
        let name = controllers?.first
        if overlay || name != nil {
            lastSeen = now
            if !connected {
                connected = true
                controller = name
                return .connected
            }
            if let name, name != controller {
                controller = name
                return .controllerChanged
            }
        } else if connected, now.timeIntervalSince(lastSeen) > debounce {
            connected = false
            controller = nil
            return .disconnected
        }
        return nil
    }
}
