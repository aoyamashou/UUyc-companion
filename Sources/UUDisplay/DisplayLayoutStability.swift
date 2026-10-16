import CoreGraphics
import Foundation

/// 删屏后的固定延时不能保证布局已稳定。连续观察同一份非空布局，再尝试一次还原；
/// 这只是可观测的稳定窗口，不代表 WindowServer 内部事务一定已经完成。
struct DisplayLayoutStability {
    enum Decision { case wait, ready, timedOut }

    var quietPeriod: TimeInterval = 3
    var waitLimit: TimeInterval = 15
    private var startedAt: TimeInterval?
    private var unchangedSince: TimeInterval?
    private var previous: [CGDirectDisplayID: CGRect]?

    mutating func reset() {
        startedAt = nil
        unchangedSince = nil
        previous = nil
    }

    mutating func observe(_ layout: [CGDirectDisplayID: CGRect]?, now: TimeInterval) -> Decision {
        if startedAt == nil { startedAt = now }
        if let layout, !layout.isEmpty {
            if previous != layout { unchangedSince = now }
            previous = layout
            if let since = unchangedSince, now - since >= quietPeriod { return .ready }
        } else {
            // 读取失败或暂时无屏幕不能算「稳定」。
            previous = nil
            unchangedSince = nil
        }
        return now - startedAt! >= waitLimit ? .timedOut : .wait
    }
}
