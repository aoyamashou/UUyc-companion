// 通过辅助功能 API 读取 UU远程 主界面：设备列表、当前控制端设备名
import AppKit
import ApplicationServices

struct UUDevice: Hashable {
    let name: String
    let isComputerGroup: Bool
    let isSelf: Bool
}

enum UUReader {
    static let bundleID = "com.netease.uuremote"

    static var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static func appElement() -> AXUIElement? {
        guard let app else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 1.0)  // UU 卡顿时不阻塞主线程太久
        return ax
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func role(_ el: AXUIElement) -> String? { attr(el, kAXRoleAttribute) as? String }
    private static func value(_ el: AXUIElement) -> String? { attr(el, kAXValueAttribute) as? String }

    /// 先序遍历；UU 的 AX 树存在环，必须限制深度
    private static func flatten(_ el: AXUIElement, depth: Int = 0, into out: inout [AXUIElement]) {
        guard depth < 25 else { return }
        out.append(el)
        for k in (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            flatten(k, depth: depth + 1, into: &out)
        }
    }

    private static func windows() -> [AXUIElement] {
        guard let ax = appElement() else { return [] }
        return (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    static var hasMainWindow: Bool { !windows().isEmpty }

    /// 点 UU 菜单栏图标里的「显示主界面」
    @discardableResult
    static func showMainWindow() -> Bool {
        guard let ax = appElement(), let bar = attr(ax, kAXExtrasMenuBarAttribute),
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        var all: [AXUIElement] = []
        flatten(bar as! AXUIElement, into: &all)
        guard let item = all.first(where: { (attr($0, kAXIdentifierAttribute) as? String) == "showWindow" }) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// 读取「全部设备」列表。主窗口不存在返回 nil。
    /// 结构：分组标题（电脑 / 手机/平板）→ 32 号设备图标 + 设备名 [+ 「本机」]
    static func readDevices() -> [UUDevice]? {
        let wins = windows()
        guard !wins.isEmpty else { return nil }
        var all: [AXUIElement] = []
        wins.forEach { flatten($0, into: &all) }

        var group: Bool?  // true = 电脑组
        var pendingIcon = false
        var result: [UUDevice] = []
        for el in all {
            switch role(el) {
            case kAXImageRole:
                let d = attr(el, kAXDescriptionAttribute) as? String ?? ""
                pendingIcon = d.hasPrefix("icon device") && d.contains(" 32")
            case kAXStaticTextRole:
                guard let v = value(el)?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { continue }
                if v == "电脑" { group = true; pendingIcon = false }
                else if v == "手机/平板" { group = false; pendingIcon = false }
                else if v == "本机", let last = result.popLast() {
                    result.append(UUDevice(name: last.name, isComputerGroup: last.isComputerGroup, isSelf: true))
                } else if pendingIcon, let g = group {
                    if !result.contains(where: { $0.name == v }) {
                        result.append(UUDevice(name: v, isComputerGroup: g, isSelf: false))
                    }
                    pendingIcon = false
                }
            default:
                break
            }
        }
        return result
    }

    /// 读取「本机被控中」表格里的控制端设备名。主窗口不存在返回 nil，无人控制返回 []
    static func readControllers() -> [String]? {
        let wins = windows()
        guard !wins.isEmpty else { return nil }
        var all: [AXUIElement] = []
        wins.forEach { flatten($0, into: &all) }
        var names: [String] = []
        for row in all where role(row) == kAXRowRole {
            var inner: [AXUIElement] = []
            flatten(row, into: &inner)
            let texts = inner.filter { role($0) == kAXStaticTextRole }.compactMap { value($0) }
            // 只接受带「远程控制」标记的行，避免其他表格误触发连入。
            guard texts.contains("远程控制") else { continue }
            if let n = texts.first(where: { $0 != "远程控制" && !$0.hasPrefix("连接时长") && !$0.isEmpty }),
               !names.contains(n) {
                names.append(n)
            }
        }
        return names
    }
}
