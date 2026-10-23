// 通过辅助功能 API 读取 UU远程 主界面：设备列表、当前控制端设备名
import AppKit
import ApplicationServices

struct UUDevice: Hashable {
    let name: String
    let isComputerGroup: Bool
    let isSelf: Bool
    /// UU 图标里的系统类型：macos / ios / android / windows…
    var platform: String = ""
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

    /// 有环的 AX 树按对象去重；只持有本次读取的有限节点，不做跨轮次树缓存。
    @discardableResult
    private static func flatten(_ el: AXUIElement, depth: Int = 0, into out: inout [AXUIElement]) -> Bool {
        var seen = Set(out)
        func walk(_ node: AXUIElement, _ level: Int) -> Bool {
            guard !seen.contains(node) else { return true }
            guard level < 25, out.count < 2048 else { return false }
            seen.insert(node)
            out.append(node)
            for child in (attr(node, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                guard walk(child, level + 1) else { return false }
            }
            return true
        }
        return walk(el, depth)
    }

    private static func windows() -> [AXUIElement] {
        guard let ax = appElement() else { return [] }
        var result = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        // 其他 App 占用全屏 Space 时，UU 的 AXWindows 可能为空，主窗口引用仍有效。
        // 同时读取这两个根节点，不激活 UU、不切换 Space；按 AX 对象身份去重。
        for key in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            guard let raw = attr(ax, key), CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
            let window = raw as! AXUIElement
            guard role(window) == kAXWindowRole, !result.contains(where: { CFEqual($0, window) }) else { continue }
            result.append(window)
        }
        return result
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
        guard wins.allSatisfy({ flatten($0, into: &all) }) else { return nil }

        var group: Bool?  // true = 电脑组
        var pendingIcon = false
        var pendingPlatform = ""
        var pendingY: CGFloat = 0
        var ys: [String: CGFloat] = [:]  // AX 顺序与界面相反，按图标的纵坐标排回 UU 的显示顺序
        var result: [UUDevice] = []
        for el in all {
            switch role(el) {
            case kAXImageRole:
                let d = attr(el, kAXDescriptionAttribute) as? String ?? ""
                pendingIcon = d.hasPrefix("icon device") && d.contains(" 32")
                if pendingIcon {
                    pendingPlatform = d.split(separator: " ").dropFirst(2).first.map(String.init) ?? ""
                    var pt = CGPoint.zero
                    if let v = attr(el, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() {
                        AXValueGetValue(v as! AXValue, .cgPoint, &pt)
                    }
                    pendingY = pt.y
                }
            case kAXStaticTextRole:
                guard let v = value(el)?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { continue }
                if v == "电脑" { group = true; pendingIcon = false }
                else if v == "手机/平板" { group = false; pendingIcon = false }
                else if v == "本机", let last = result.popLast() {
                    result.append(UUDevice(name: last.name, isComputerGroup: last.isComputerGroup, isSelf: true, platform: last.platform))
                } else if pendingIcon, let g = group {
                    if !result.contains(where: { $0.name == v }) {
                        result.append(UUDevice(name: v, isComputerGroup: g, isSelf: false, platform: pendingPlatform))
                        ys[v] = pendingY
                    }
                    pendingIcon = false
                }
            default:
                break
            }
        }
        return result.enumerated().sorted { (ys[$0.element.name] ?? 0, $0.offset) < (ys[$1.element.name] ?? 0, $1.offset) }.map(\.element)
    }

    /// 读取「本机被控中」表格里的控制端设备名。主窗口不存在返回 nil，无人控制返回 []
    static func readControllers() -> [String]? {
        let wins = windows()
        guard !wins.isEmpty else { return nil }
        var all: [AXUIElement] = []
        guard wins.allSatisfy({ flatten($0, into: &all) }) else { return nil }
        var names: [String] = []
        for row in all where role(row) == kAXRowRole {
            var inner: [AXUIElement] = []
            guard flatten(row, into: &inner) else { return nil }
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
