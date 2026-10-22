// 虚拟屏与物理屏的显示拓扑管理：目标状态 + 逐步收敛
// 调用方只声明「应该是什么样」（desired），执行器一次只做一步拓扑变化，每步之后等待系统稳定再做下一步。
// 原因（实测）：重新启用物理屏的热插拔事件尚未处理完时又新建虚拟屏，applySettings 失败，
//              随后 WindowServer 在 GenerateModeListForDisplay 中 abort，系统注销重启。
//      另：虚拟屏创建后约 1 秒、尚未完全上线时就释放，会让 WindowServer 显示配置卡死（所有事务 10 秒超时，
//      需重启恢复），因此释放前必须已上线且存活 ≥ 2.5 秒；一旦检测到超时即进入保护状态，不再做拓扑变化。
// 其他要点：虚拟屏只给一个模式且不改；GUI 主线程不能调 CGCompleteDisplayConfiguration（放 cgQueue）；
//          物理屏是否被禁用以磁盘记录为准（看门狗可能在别的进程里已恢复）。
import CGVirtualDisplayBridge
import CoreGraphics
import Foundation

/// 建屏前记录的物理屏状态：位置 + 显示模式（分辨率）。
/// 只记位置不够：会话期间 UU 远程或系统可能改掉物理屏分辨率，
/// 断开后必须按原样恢复，否则会掉到系统默认的 1920×1080。
struct SavedDisplayState: Codable {
    var x: Double
    var y: Double
    var width: Int
    var height: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var refreshRate: Double

    init(origin: CGPoint, mode: CGDisplayMode) {
        x = origin.x
        y = origin.y
        width = mode.width
        height = mode.height
        pixelWidth = mode.pixelWidth
        pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate
    }

    /// 兼容旧版 session.json 的 [x, y] 格式（只有位置）
    init?(legacy: [Double]) {
        guard legacy.count == 2 else { return nil }
        x = legacy[0]
        y = legacy[1]
        width = 0
        height = 0
        pixelWidth = 0
        pixelHeight = 0
        refreshRate = 0
    }

    var hasMode: Bool { width > 0 && height > 0 }
}

final class DisplayManager {
    static let vendorID: UInt32 = 0x5555

    // 目标状态
    private var desired: DeviceConfig?
    private var shutdownCompletion: (() -> Void)?
    /// 是否应禁用物理屏（由 Coordinator 按设置与看门狗状态决定）
    var shouldDisablePhysical: () -> Bool = { false }
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
    /// 建屏前各物理屏的位置与分辨率，用于还原
    private var savedStates: [CGDirectDisplayID: SavedDisplayState] = [:]

    // 执行器
    private var busy = false
    /// 启动时先把残留状态恢复干净，期间忽略目标设备
    private var recovering = false
    private var waitOnlineTries = 0
    private var bornAt: [CGDirectDisplayID: Date] = [:]
    private var releaseWaitStart: Date?
    /// WindowServer 显示配置无响应（事务超时）：停止建屏/删屏/改布局
    private(set) var wedged = false
    static let minLifetime: TimeInterval = 2.5
    /// 两次建屏的最小间隔：打断「建屏→改拓扑→误判断开→拆屏→再建屏」的自激振荡。
    /// 每次建屏都会让 WindowServer/ColorSync 重新枚举显示设备，高频循环会把 CPU 打满。
    static let minCreateInterval: TimeInterval = 8
    private var lastCreatedAt = Date.distantPast
    private let cgQueue = DispatchQueue(label: "uudisplay.display-config")

    private static let markerURL = ConfigStore.dir.appendingPathComponent("session.json")

    var isActive: Bool { vd != nil }
    var physicalOff: Bool { PhysicalDisplays.pending != nil }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func isVirtual(_ id: CGDirectDisplayID) -> Bool { CGDisplayVendorNumber(id) == vendorID }

    /// 记录当前所有物理屏的原点与显示模式（须在创建虚拟屏之前调用）
    static func capturePhysicalStates() -> [CGDirectDisplayID: SavedDisplayState] {
        var states: [CGDirectDisplayID: SavedDisplayState] = [:]
        for id in onlineDisplays() where !isVirtual(id) {
            guard let mode = CGDisplayCopyDisplayMode(id) else { continue }
            states[id] = SavedDisplayState(origin: CGDisplayBounds(id).origin, mode: mode)
        }
        return states
    }

    /// 由设备配置派生的稳定序列号（FNV-1a 32 位）。
    /// 不能用 Swift 的 Hasher：它每次进程启动都会随机加盐，跨进程不稳定。
    static func stableSerial(for cfg: DeviceConfig) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        let key = "\(cfg.name)|\(cfg.width)x\(cfg.height)|\(cfg.hiDPI ? 1 : 0)"
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let serial = hash % 0xFFFF_FFF0
        return serial == 0 ? 1 : serial
    }

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
        if let completion { shutdownCompletion = completion }
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
        if let data = try? Data(contentsOf: DisplayManager.markerURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in dict {
                guard let id = UInt32(k) else { continue }
                if let legacy = v as? [Double], let state = SavedDisplayState(legacy: legacy) {
                    savedStates[id] = state
                } else if let obj = v as? [String: Any],
                          let d = try? JSONSerialization.data(withJSONObject: obj),
                          let state = try? JSONDecoder().decode(SavedDisplayState.self, from: d) {
                    savedStates[id] = state
                }
            }
        }
        if !savedStates.isEmpty || physicalOff {
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
        }
    }

    /// 在 cgQueue 执行配置事务，回到主线程后进入稳定等待；事务超时则进入保护状态
    private func runCG(settle: TimeInterval, _ work: @escaping () -> CGError) {
        busy = true
        cgQueue.async {
            let err = work()
            DispatchQueue.main.async {
                if err == .cannotComplete || err.rawValue == 1014 { self.enterWedged(err) }
                self.finish(settle: settle)
            }
        }
    }

    private func enterWedged(_ err: CGError) {
        guard !wedged else { return }
        wedged = true
        Log.info("⛔️ WindowServer 显示配置无响应（CGError=\(err.rawValue)），停止一切显示操作；请注销或重启 Mac 恢复")
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
            // 保护状态：只尝试恢复物理屏，其余全部停止
            if physicalOff { return runCG(settle: 3) { PhysicalDisplays.restore(reason: "保护状态") ? .success : .failure } }
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
            if !savedStates.isEmpty {
                let states = savedStates
                savedStates = [:]
                try? FileManager.default.removeItem(at: DisplayManager.markerURL)
                return runCG(settle: 0.5) { DisplayManager.restoreStates(states) }
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
            // 建屏冷却：UU 覆盖窗口在改显示拓扑时会短暂重建，若「断开→连入」来回抖动，
            // 会形成 建屏→改拓扑→误判断开→拆屏→再建屏 的自激振荡。
            // 每次建屏都会新增一次显示设备枚举（旧版本还会多落一个 ICC profile），必须限速。
            let sinceLast = Date().timeIntervalSince(lastCreatedAt)
            if sinceLast < DisplayManager.minCreateInterval {
                busy = true
                return finish(settle: DisplayManager.minCreateInterval - sinceLast)
            }
            busy = true
            // 必须在建屏前记录：虚拟屏一出现，macOS 会把物理屏模式也切到虚拟屏的分辨率，
            // 之后再记录就会把「虚拟屏尺寸」当成用户原来的分辨率，导致断开后恢复错。
            if savedStates.isEmpty {
                savedStates = DisplayManager.capturePhysicalStates()
                let summary = savedStates.map { "#\($0.key) \($0.value.width)×\($0.value.height)@\(Int($0.value.refreshRate))" }
                    .joined(separator: ", ")
                Log.info("已记录物理屏原始分辨率：\(summary.isEmpty ? "(无物理屏)" : summary)")
                writeMarker()
            }
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
        lastCreatedAt = Date()
        let w = cfg.width, h = cfg.height
        let desc = CGVirtualDisplayDescriptor()
        desc.name = "UUyc companion · \(cfg.name)"  // 显示在 UU 的多显示屏列表、系统显示器设置中
        desc.maxPixelsWide = UInt32(w)
        desc.maxPixelsHigh = UInt32(h)
        desc.sizeInMillimeters = CGSize(width: Double(w) / 220 * 25.4, height: Double(h) / 220 * 25.4)
        desc.vendorID = DisplayManager.vendorID
        desc.productID = 0x0001
        // 稳定序列号：同一台控制设备永远对应同一个显示器身份。
        // 旧实现每次建屏都随机 serialNum，macOS 会当成一台全新显示器，在
        // /Library/ColorSync/Profiles/Displays 生成新的 ICC profile 且从不回收；
        // 反复建屏后目录膨胀到上百个文件，colorsyncd / colorsync.useragent 枚举时 CPU 打满。
        desc.serialNum = DisplayManager.stableSerial(for: cfg)

        var created: CGVirtualDisplay? = autoreleasepool { CGVirtualDisplay(descriptor: desc) }
        if created == nil {
            // 同序列号仍与系统中残留的同身份虚拟屏冲突时（极少数），退回随机序列号保证功能可用；
            // 只有这一种情况会多出一个 ICC profile。
            Log.info("⚠️ 稳定序列号 \(desc.serialNum) 创建失败，退回随机序列号重试")
            desc.serialNum = UInt32.random(in: 1...0xFFFF_FFF0)
            created = autoreleasepool { CGVirtualDisplay(descriptor: desc) }
        }
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
        Log.info("✅ 已移除虚拟屏 \(ids)")
    }

    /// 还原物理屏：先把分辨率恢复成建屏前记下的模式，再恢复位置。
    /// 只还原位置会让分辨率停在系统默认值（例如 1920×1080）。
    private static func restoreStates(_ states: [CGDirectDisplayID: SavedDisplayState]) -> CGError {
        let online = Set(onlineDisplays())
        let targets = states.filter { online.contains($0.key) }
        guard !targets.isEmpty else { return .success }

        // 把「保存时的分辨率」解析成当前仍可用的 CGDisplayMode
        var resolved: [CGDirectDisplayID: CGDisplayMode] = [:]
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        for (id, state) in targets where state.hasMode {
            let all = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
            resolved[id] = all.first { mode in
                mode.width == state.width
                    && mode.height == state.height
                    && mode.pixelWidth == state.pixelWidth
                    && mode.pixelHeight == state.pixelHeight
                    && abs(mode.refreshRate - state.refreshRate) < 0.5
            }
            if resolved[id] == nil {
                Log.info("⚠️ 未找到 #\(id) 的原始分辨率 \(state.width)×\(state.height)，仅还原位置")
            }
        }

        let err = applyDisplayConfig { cfg in
            for (id, state) in targets {
                if let mode = resolved[id] {
                    CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil)
                }
                CGConfigureDisplayOrigin(cfg, id, Int32(state.x), Int32(state.y))
            }
        }
        if err == .success {
            let restored = targets.map { "#\($0.key) \($0.value.width)×\($0.value.height)" }.joined(separator: ", ")
            Log.info("✅ 已还原显示器分辨率与布局：\(restored)")
        } else {
            Log.info("⚠️ 还原布局 CGError=\(err.rawValue)")
        }
        return err
    }

    private func writeMarker() {
        let dict = Dictionary(uniqueKeysWithValues: savedStates.map { ("\($0.key)", $0.value) })
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: DisplayManager.markerURL, options: .atomic)
        }
    }
}
