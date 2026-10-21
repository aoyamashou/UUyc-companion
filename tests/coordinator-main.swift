import Foundation
struct DeviceConfig {
    enum Kind { case tablet, computer }
    var name: String; var kind: Kind; var width: Int; var height: Int
    var hasSize: Bool { width > 0 && height > 0 }
    var sizeLabel: String { "test" }
}
final class ConfigStore {
    static let shared = ConfigStore()
    struct Config { var paused = false; var disablePhysical = false; var shouldDisablePhysical: Bool { disablePhysical } }
    var config = Config()
    func device(named name: String) -> DeviceConfig? { DeviceConfig(name: name, kind: .tablet, width: 100, height: 100) }
}
final class UUMonitor {
    var onConnect: (() -> Void)?; var onDisconnect: (() -> Void)?
    var connected = true
    func start() {}
}
final class DisplayManager {
    var shouldDisablePhysical: () -> Bool = { false }
    var wedged = false; var isActive = false; var physicalOff = false
    var current: DeviceConfig?
    var creates = 0
    func recoverIfNeeded() {}
    func remove(completion: (() -> Void)? = nil) { isActive = false; completion?() }
    func matches(_ cfg: DeviceConfig) -> Bool { isActive }
    func create(_ cfg: DeviceConfig) { creates += 1; current = cfg; isActive = true }
    func restorePhysicalNow(override: Bool = true) {}
    func disablePhysicalIfNeeded() {}
}
enum PhysicalDisplays { static let available = true }
enum Log { static func info(_ message: String) {} }
enum UUReader {
    static var isTrusted = true
    static var names: [String]? = nil
    static var attempts = 0
    static func readControllers() -> [String]? { names }
    static func showMainWindow() -> Bool { attempts += 1; return attempts > 1 }
}
@main struct CoordinatorTests {
    static func main() {
        let coordinator = Coordinator()
        coordinator.handleConnect()
        RunLoop.main.run(until: Date().addingTimeInterval(31))
        precondition(UUReader.attempts == 2, "A failed window-open attempt must be retried")
        UUReader.names = ["late device"]
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        precondition(coordinator.display.creates == 1, "A name arriving after 30 seconds must still create a display")
        coordinator.handleDisconnect()
        precondition(!coordinator.display.isActive)
        print("PASS: failed window-open retry and name arriving after 30 seconds")
    }
}
