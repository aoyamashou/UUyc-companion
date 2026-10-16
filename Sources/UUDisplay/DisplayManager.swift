// 虚拟屏与物理屏的显示拓扑管理：目标状态 + 逐步收敛
// 调用方只声明「应该是什么样」（desired），执行器一次只做一步拓扑变化，每步之后等待系统稳定再做下一步。
// 原因（实测）：重新启用物理屏的热插拔事件尚未处理完时又新建虚拟屏，applySettings 失败，
//              随后 WindowServer 在 GenerateModeListForDisplay 中 abort，系统注销重启。
//      另：虚拟屏创建后约 1 秒、尚未完全上线时就释放，会让 WindowServer 显示配置卡死（所有事务 10 秒超时）；
//      因此释放前必须已上线且存活 ≥ 2.5 秒；一旦检测到超时即进入保护状态，不再做拓扑变化。
// 其他要点：虚拟屏只给一个模式且不改；GUI 主线程不能调 CGCompleteDisplayConfiguration（放 cgQueue）；
//          物理屏是否被禁用以磁盘记录为准（看门狗可能在别的进程里已恢复）。
import CGVirtualDisplayBridge
import CoreGraphics
import Foundation

final class DisplayManager {
    static let vendorID: UInt32 = 0x5555

    // 目标状态
    private var desired: DeviceConfig?
    private var shutdownCompletion: (() -> Void)?
    /// 是否应禁用物理屏（由 Coordinator 按设置与看门狗状态决定）
    var shouldDisablePhysical: () -> Bool = { false }
    var onChange: (() -> Void)?
    /// 用户手动恢复后，本次连接内不再禁用
    private var physicalOverride = false

    // 实际状态
    private var vd: CGVirtualDisplay?
    private(set) var current: DeviceConfig?
    private var mainSet = false
    /// 换设备时的旧屏，等新屏成为主屏后释放
    private var retiring: [CGVirtualDisplay] = []
    /// 配置失败的虚拟屏，稳定后再释放（立即释放曾触发 WindowServer 崩溃）
    private var broken: [CGVirtualDisplay] = []
    /// 同一配置创建失败后不再重试，直到目标变化
    private var failedCfg: DeviceConfig?
    /// 建屏前各物理屏的原点，用于还原
    private var savedOrigins: [CGDirectDisplayID: CGPoint] = [:]

    // 执行器
    private var busy = false
    /// 启动时先把残留状态恢复干净，期间忽略目标设备
    private var recovering = false
    private var waitOnlineTries = 0
    private var bornAt: [CGDirectDisplayID: Date] = [:]
    private var releaseWaitStart: Date?
    /// 显示配置失败后的保护状态：停止自动建屏/删屏/改布局。
    private(set) var wedged = false
    static let minLifetime: TimeInterval = 2.5
    private let cgQueue = DispatchQueue(label: "uudisplay.display-config")

    private let markerURL: URL
    private let layoutSnapshot: () -> [CGDirectDisplayID: CGRect]?
    private let restoreLayout: ([CGDirectDisplayID: CGPoint]) -> CGError
    private let uptime: () -> TimeInterval
    private var layoutStability = DisplayLayoutStability()
    private(set) var retryingLayout = false

    // 只替换布局恢复的 I/O，测试无需连接 UU、建虚拟屏或修改真实显示器。
    init(markerURL: URL = ConfigStore.dir.appendingPathComponent("session.json"),
         layoutSnapshot: @escaping () -> [CGDirectDisplayID: CGRect]? = { DisplayManager.readLayout() },
         restoreLayout: @escaping ([CGDirectDisplayID: CGPoint]) -> CGError = { DisplayManager.restoreOrigins($0) },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.markerURL = markerURL
        self.layoutSnapshot = layoutSnapshot
        self.restoreLayout = restoreLayout
        self.uptime = uptime
    }

    var isActive: Bool { vd != nil }
    var physicalOff: Bool { PhysicalDisplays.pending != nil }

    /// 只重试断开后失败的布局还原，不解除持有虚拟屏或物理屏仍关闭时的保护。
    var canRetryLayout: Bool {
        wedged && !busy && desired == nil && vd == nil && retiring.isEmpty && broken.isEmpty
            && !physicalOff && !savedOrigins.isEmpty && shutdownCompletion == nil
    }

    @discardableResult
    func retryLayoutRestore() -> Bool {
        guard canRetryLayout else { return false }
        Log.info("手动重试显示器布局还原；先等待布局稳定")
        retryingLayout = true
        layoutStability.reset()
        kick()
        return true
    }

    /// 连入（包括设备名尚未读到）时取消等待中的重试；已提交的事务会完成。
    func cancelLayoutRetry() { retryingLayout = false }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func isVirtual(_ id: CGDirectDisplayID) -> Bool { CGDisplayVendorNumber(id) == vendorID }

    private static func same(_ a: DeviceConfig?, _ b: DeviceConfig?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.width == b.width && a.height == b.height && a.hiDPI == b.hiDPI
    }

    /// 已是同规格虚拟屏则不动
    func matches(_ cfg: DeviceConfig) -> Bool { DisplayManager.same(desired, cfg) && vd != nil }

    // MARK: - 对外接口：只改目标状态

    func create(_ cfg: DeviceConfig) {
        if !DisplayManager.same(desired, cfg) { failedCfg = nil }
        desired = cfg
        kick()
    }

    func remove(completion: (() -> Void)? = nil) {
        desired = nil
        failedCfg = nil
        physicalOverride = false
        if let completion {
            retryingLayout = false
            shutdownCompletion = completion
        }
        kick()
    }

    func disablePhysicalIfNeeded() { kick() }

    /// 快捷键 / 菜单 / 关闭开关：立即恢复物理屏，虚拟屏保留
    func restorePhysicalNow(override: Bool = true) {
        if override { physicalOverride = true }
        kick()
    }

    /// 启动时：读回上次未收尾的布局记录；残留的物理屏禁用记录由执行器按「目标=无」自动恢复
    func recoverIfNeeded() {
        if let data = try? Data(contentsOf: markerURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]] {
            for (k, v) in dict where v.count == 2 {
                if let id = UInt32(k) { savedOrigins[id] = CGPoint(x: v[0], y: v[1]) }
            }
        }
        if !savedOrigins.isEmpty || physicalOff {
            Log.info("发现上次异常退出的残留状态，先恢复物理屏与显示器布局")
            recovering = true
        }
        kick()
    }

    // MARK: - 执行器

    private func kick() {
        guard !busy else { return }
        step()
    }

    /// 完成一步后等待 settle 秒再评估下一步
    private func finish(settle: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self else { return }
            self.busy = false
            self.step()
            self.onChange?()
        }
    }

    /// 在 cgQueue 执行配置事务，回到主线程后进入稳定等待；事务超时则进入保护状态
    private func runCG(settle: TimeInterval, completion: ((CGError) -> Void)? = nil,
                       _ work: @escaping () -> CGError) {
        busy = true
        cgQueue.async {
            let err = work()
            DispatchQueue.main.async {
                if let completion { completion(err) }
                else if err == .cannotComplete || err.rawValue == 1014 { self.enterWedged(err) }
                self.finish(settle: settle)
            }
        }
    }

    private func enterWedged(_ err: CGError? = nil) {
        guard !wedged else { return }
        wedged = true
        let reason = err.map { "显示配置失败（CGError=\($0.rawValue)）" } ?? "显示器布局尚未稳定"
        Log.info("⛔️ \(reason)，已暂停自动调整；断开远程后可重试布局还原，或完全退出并重开伴侣；仍失败再考虑注销或重启 Mac")
        onChange?()
    }

    private func restorePendingLayout() {
        switch layoutStability.observe(layoutSnapshot(), now: uptime()) {
        case .wait:
            busy = true
            return finish(settle: 0.5)
        case .timedOut:
            retryingLayout = false
            Log.info("⚠️ 等待显示器布局稳定超时，保留布局记录并暂停自动调整")
            enterWedged()
            // 让退出收尾能完成；不自动重试失败的恢复。
            busy = true
            return finish(settle: 0)
        case .ready:
            let origins = savedOrigins
            let restore = restoreLayout
            runCG(settle: 0.5, completion: { [self] err in
                layoutStability.reset()
                if err == .success {
                    savedOrigins = [:]
                    try? FileManager.default.removeItem(at: markerURL)
                    // 只有用户请求的布局还原成功才解除保护；重连取消后仍保持保护。
                    if retryingLayout {
                        wedged = false
                        Log.info("✅ 布局还原成功，已恢复自动屏幕调整")
                    }
                } else {
                    // 所有失败均保留内存与磁盘记录，避免非超时错误无限循环。
                    Log.info("⚠️ 布局还原失败 CGError=\(err.rawValue)，保留恢复记录；不自动重试")
                    enterWedged(err)
                }
                retryingLayout = false
                onChange?()
            }) { restore(origins) }
        }
    }

    /// 释放前确认每块屏已上线且存活足够久；最多等 8 秒
    private func readyToRelease(_ displays: [CGVirtualDisplay]) -> Bool {
        let online = Set(DisplayManager.onlineDisplays())
        let young = displays.contains { d in
            !online.contains(d.displayID) || Date().timeIntervalSince(bornAt[d.displayID] ?? .distantPast) < DisplayManager.minLifetime
        }
        guard young else { releaseWaitStart = nil; return true }
        let start = releaseWaitStart ?? Date()
        releaseWaitStart = start
        if Date().timeIntervalSince(start) > 8 { releaseWaitStart = nil; return true }
        return false
    }

    private func step() {
        guard !busy else { return }
        if wedged {
            // 保护状态：保留物理屏兜底；仅允许用户发起的布局还原，不再增删虚拟屏。
            if physicalOff { return runCG(settle: 3) { PhysicalDisplays.restore(reason: "保护状态") ? .success : .failure } }
            if retryingLayout, desired == nil, vd == nil, retiring.isEmpty, broken.isEmpty {
                return restorePendingLayout()
            }
            retryingLayout = false
            if let done = shutdownCompletion { shutdownCompletion = nil; done() }
            return
        }

        // 1. 配置失败的屏：稳定后释放
        if !broken.isEmpty {
            guard readyToRelease(broken) else { busy = true; return finish(settle: 0.5) }
            busy = true
            release(&broken)
            return finish(settle: 1.5)
        }

        guard let want = recovering ? nil : desired else {
            // 目标=无：恢复物理屏 → 释放虚拟屏 → 还原布局
            if physicalOff {
                return runCG(settle: 1.5) { PhysicalDisplays.restore(reason: "远程结束") ? .success : .failure }
            }
            if vd != nil || !retiring.isEmpty {
                guard readyToRelease(retiring + [vd].compactMap { $0 }) else { busy = true; return finish(settle: 0.5) }
                busy = true
                var all = retiring + [vd].compactMap { $0 }
                retiring = []
                vd = nil
                current = nil
                mainSet = false
                release(&all)
                return finish(settle: 1.5)
            }
            if !savedOrigins.isEmpty {
                return restorePendingLayout()
            }
            if recovering {
                recovering = false
                Log.info("残留状态已恢复")
                if desired != nil { return step() }
            }
            if let done = shutdownCompletion {
                shutdownCompletion = nil
                done()
            }
            return
        }

        // 目标=某设备的虚拟屏
        if vd == nil || !DisplayManager.same(current, want) {
            guard !DisplayManager.same(failedCfg, want) else { return }
            busy = true
            if let old = vd { retiring.append(old) }
            vd = nil
            current = nil
            mainSet = false
            waitOnlineTries = 0
            if !createDisplay(want) { failedCfg = want }
            return finish(settle: 1.0)
        }

        if !mainSet, let id = vd?.displayID {
            let online = DisplayManager.onlineDisplays()
            guard online.contains(id) else {
                waitOnlineTries += 1
                if waitOnlineTries > 20 { Log.info("⚠️ 虚拟屏 5 秒内未上线"); mainSet = true }
                busy = true
                return finish(settle: 0.25)
            }
            if savedOrigins.isEmpty {
                savedOrigins = Dictionary(uniqueKeysWithValues: online.filter { !DisplayManager.isVirtual($0) }
                    .map { ($0, CGDisplayBounds($0).origin) })
            }
            writeMarker()
            mainSet = true
            return runCG(settle: 0.5) {
                let err = applyDisplayConfig { cfg in
                    let t = CGDisplayBounds(id).origin
                    for d in online {
                        let o = CGDisplayBounds(d).origin
                        CGConfigureDisplayOrigin(cfg, d, Int32(o.x - t.x), Int32(o.y - t.y))
                    }
                }
                Log.info(err == .success ? "✅ 虚拟屏已设为主屏" : "⚠️ 设主屏失败 CGError=\(err.rawValue)")
                return err
            }
        }

        if !retiring.isEmpty {
            guard readyToRelease(retiring) else { busy = true; return finish(settle: 0.5) }
            busy = true
            release(&retiring)
            return finish(settle: 1.5)
        }

        let wantOff = shouldDisablePhysical() && !physicalOverride
        if wantOff, !physicalOff, let id = vd?.displayID {
            let physical = DisplayManager.onlineDisplays().filter { !DisplayManager.isVirtual($0) }
            if !physical.isEmpty {
                return runCG(settle: 1.5) {
                    let err = PhysicalDisplays.disable(physical)
                    Log.info(err == .success ? "✅ 已关闭物理屏 \(physical)，只保留虚拟屏 #\(id)" : "⚠️ 关闭物理屏失败 CGError=\(err.rawValue)")
                    return err
                }
            }
        }
        if !wantOff, physicalOff {
            return runCG(settle: 1.5) { PhysicalDisplays.restore(reason: "手动恢复") ? .success : .failure }
        }
    }

    // MARK: - 单步操作

    private func createDisplay(_ cfg: DeviceConfig) -> Bool {
        let w = cfg.width, h = cfg.height
        let desc = CGVirtualDisplayDescriptor()
        desc.name = "UUyc companion · \(cfg.name)"  // 显示在 UU 的多显示屏列表、系统显示器设置中
        desc.maxPixelsWide = UInt32(w)
        desc.maxPixelsHigh = UInt32(h)
        desc.sizeInMillimeters = CGSize(width: Double(w) / 220 * 25.4, height: Double(h) / 220 * 25.4)
        desc.vendorID = DisplayManager.vendorID
        desc.productID = 0x0001
        // 每次随机序列号：与残留虚拟屏同序列号时 CGVirtualDisplay 会返回 nil
        desc.serialNum = UInt32.random(in: 1...0xFFFF_FFF0)

        let created: CGVirtualDisplay? = autoreleasepool { CGVirtualDisplay(descriptor: desc) }
        guard let display = created else {
            Log.info("❌ 创建虚拟屏失败（CGVirtualDisplay 返回 nil）")
            return false
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = cfg.hiDPI
        let mw = cfg.hiDPI ? w / 2 : w, mh = cfg.hiDPI ? h / 2 : h
        settings.modes = [CGVirtualDisplayMode(width: UInt(mw), height: UInt(mh), refreshRate: 60)]
        guard autoreleasepool(invoking: { display.apply(settings) }) else {
            Log.info("❌ 虚拟屏 applySettings 失败，稳定后释放")
            bornAt[display.displayID] = Date()
            broken.append(display)
            return false
        }
        vd = display
        current = cfg
        bornAt[display.displayID] = Date()
        Log.info("✅ 已创建虚拟屏 #\(display.displayID) \(cfg.name) \(cfg.sizeLabel)")
        return true
    }

    private func release(_ displays: inout [CGVirtualDisplay]) {
        guard !displays.isEmpty else { return }
        let ids = displays.map { "#\($0.displayID)" }.joined(separator: " ")
        autoreleasepool { displays.removeAll() }
        layoutStability.reset()
        Log.info("✅ 已移除虚拟屏 \(ids)")
    }

    private static func restoreOrigins(_ origins: [CGDirectDisplayID: CGPoint]) -> CGError {
        guard let layout = readLayout() else { return .cannotComplete }
        let targets = origins.filter { layout[$0.key] != nil }
        guard !targets.isEmpty else { return .success }
        var cfg: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&cfg)
        guard begin == .success else { return begin }
        for (id, o) in targets {
            let err = CGConfigureDisplayOrigin(cfg, id, Int32(o.x), Int32(o.y))
            if err != .success {
                CGCancelDisplayConfiguration(cfg)
                return err
            }
        }
        let err = CGCompleteDisplayConfiguration(cfg, .forSession)
        if err != .success { CGCancelDisplayConfiguration(cfg) }
        Log.info(err == .success ? "✅ 已还原显示器布局" : "⚠️ 还原布局 CGError=\(err.rawValue)")
        return err
    }

    private static func readLayout() -> [CGDirectDisplayID: CGRect]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        // 对象已释放不代表系统已移除显示器；自己的虚拟屏仍在线时继续等待。
        guard !ids.prefix(Int(count)).contains(where: isVirtual) else { return nil }
        return Dictionary(uniqueKeysWithValues: ids.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) })
    }

    private func writeMarker() {
        let dict = Dictionary(uniqueKeysWithValues: savedOrigins.map { ("\($0.key)", [$0.value.x, $0.value.y]) })
        try? JSONSerialization.data(withJSONObject: dict).write(to: markerURL, options: .atomic)
    }
}
