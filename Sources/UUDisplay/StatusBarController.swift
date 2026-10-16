// 菜单栏：状态 / 远程时只保留虚拟屏 / 设置 / 完全退出
import AboutKit
import AppKit

final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let coordinator: Coordinator
    private let openSettings: (SettingsPane?) -> Void
    private let store = ConfigStore.shared

    init(coordinator: Coordinator, openSettings: @escaping (SettingsPane?) -> Void) {
        self.coordinator = coordinator
        self.openSettings = openSettings
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
    }

    /// 菜单栏图标：Assets/AppIcon/MenuBarIconTemplate（模板图，深色菜单栏自动反白）；
    /// 非 .app 运行（调试）找不到资源时退回系统图标
    private static let menuBarIcon: NSImage = {
        if let image = NSImage(named: "MenuBarIconTemplate") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)!
    }()

    func refresh() {
        let icon = StatusBarController.menuBarIcon
        icon.accessibilityDescription = "UU远程伴侣"
        item.button?.image = icon
        item.button?.appearsDisabled = store.config.paused  // 暂停自动切换时图标变灰
        item.button?.toolTip = "UU远程伴侣：\(coordinator.statusText)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: coordinator.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if coordinator.display.wedged {
            let retry = action("重试还原显示器布局", #selector(retryLayout))
            retry.isEnabled = coordinator.canRetryLayout
            menu.addItem(retry)
        }
        menu.addItem(.separator())

        let physical = action("远程时只保留虚拟屏", #selector(toggleDisablePhysical))
        physical.state = store.config.shouldDisablePhysical ? .on : .off
        menu.addItem(physical)
        menu.addItem(action("设置…", #selector(reconfigure), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("完全退出", #selector(quit), key: "q"))
        DebugLabels.decorate(menu)
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func reconfigure() { openSettings(nil) }

    @objc private func retryLayout() { coordinator.retryLayoutRestore() }

    @objc private func toggleDisablePhysical() { coordinator.setDisablePhysical(!store.config.shouldDisablePhysical) }

    /// 与设置窗口的「完全退出」一致：停掉本次登录中的守护助手，再退出主程序
    @objc private func quit() {
        WatchdogAgent.stopForSession()
        NSApp.terminate(nil)
    }
}
