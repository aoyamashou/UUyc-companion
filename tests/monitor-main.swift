import Foundation

// 不访问真实 UU 或显示器，只替代 monitor 默认依赖。
enum UUReader {
    static var isTrusted: Bool { false }
    static func readControllers() -> [String]? { nil }
    static func showMainWindow() -> Bool { false }
}
enum Log { static func info(_ message: String) {} }

@main struct MonitorTests {
    static func main() {
        let lock = NSLock()
        var reads = 0
        var overlay = true
        var connects = 0
        var disconnects = 0
        var pulses = 0
        let monitor = UUMonitor(pollInterval: 0.1, trusted: { true }, readControllers: {
            lock.lock(); reads += 1; lock.unlock()
            Thread.sleep(forTimeInterval: 3)
            return ["stale controller"]
        }, hasOverlay: { overlay })
        monitor.onConnect = { connects += 1 }
        monitor.onDisconnect = { disconnects += 1 }
        monitor.start()
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in pulses += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        precondition(connects == 1, "覆盖窗口检测不能等待 AX 返回")
        overlay = false
        RunLoop.main.run(until: Date().addingTimeInterval(1.9))
        precondition(disconnects == 1, "AX 阻塞时仍应按覆盖窗口缺席触发断开")
        lock.lock(); let count = reads; lock.unlock()
        precondition(count == 1, "AX 读取不能堆积或并发")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        precondition(connects == 1, "过期的 AX 结果不能重新触发连接")
        precondition(pulses >= 30, "AX 读取不能阻塞主线程")
        heartbeat.invalidate()
        monitor.stop()
        // 默认低频轮询：控制逻辑读取名称缓存不会触发额外 AX 请求；两秒周期中不误断开。
        precondition(UUMonitor.defaultPollInterval == 2)
        var slowReads = 0
        var slowConnects = 0
        var slowDisconnects = 0
        var overlayReads = 0
        let slow = UUMonitor(trusted: { true }, readControllers: {
            lock.lock(); slowReads += 1; lock.unlock()
            return ["fullscreen controller"]
        }, hasOverlay: { overlayReads += 1; return false })
        slow.onConnect = { slowConnects += 1 }
        slow.onDisconnect = { slowDisconnects += 1 }
        slow.onControllersRead = {
            for _ in 0..<100 { precondition(slow.controllerName == "fullscreen controller") }
        }
        slow.start()
        slow.start() // 重复 start 不能产生额外计时器。
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))
        lock.lock(); let firstReads = slowReads; lock.unlock()
        precondition(firstReads == 1 && overlayReads == 1, "must not poll faster than the default interval")
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        lock.lock(); let secondReads = slowReads; lock.unlock()
        precondition(secondReads == 2 && overlayReads == 2, "one AX read and one window enumeration per cycle")
        precondition(slowConnects == 1 && slowDisconnects == 0, "cache must cover the slower polling interval")
        slow.stop()
        precondition(slow.controllerName == nil && !slow.connected)

        // 真正没有主窗口时才后台打开一次；不是每次读取失败都重复打开。
        var opens = 0
        let missing = UUMonitor(pollInterval: 0.1, trusted: { true },
            readControllers: { nil }, hasOverlay: { true }, showMainWindow: {
                lock.lock(); opens += 1; lock.unlock()
                return true
            })
        missing.onControllersRead = { missing.requestMainWindowIfNeeded() }
        missing.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        lock.lock(); let openCount = opens; lock.unlock()
        precondition(openCount == 1, "main-window fallback must be bounded to one request per session")
        missing.stop()
        slow.onControllersRead = nil
        missing.onControllersRead = nil
        print("PASS: default two-second polling; one AX read and window enumeration per cycle; shared name cache; idempotent start; bounded background window opening")
        print("PASS: blocked AX keeps main thread responsive; no overlapping reads; overlay disconnect; stale result rejected")
    }
}
