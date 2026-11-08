import AppKit

final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let reader = TemperatureReader()
    private var timer: Timer?
    private var lastTitle: String?

    func start() {
        if let button = statusItem.button {
            button.title = "--°"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
        // LED helper: the daemon (also auto-started at login) gets a moment to
        // come up; if it never does, request admin authorization right away —
        // the install is built into app startup, not a menu step.
        scheduleAutoSetup()
    }

    private func refresh() {
        let snapshot = reader.readSnapshot()
        let title = TemperatureModel.menuBarText(snapshot: snapshot)
        if title != lastTitle {
            statusItem.button?.title = title
            lastTitle = title
        }
        rebuildMenu(snapshot: snapshot)
    }

    /// Create a menu item with black text
    private func blackItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: NSColor.black]
        )
        return item
    }

    private func rebuildMenu(snapshot: TemperatureSnapshot) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if let cpu = TemperatureModel.hottest(from: snapshot.cpuReadings) {
            menu.addItem(blackItem(String(format: "CPU 最高温度: %.1f°", cpu.value)))
            menu.addItem(blackItem("  传感器: \(cpu.sensorName)"))
        } else {
            menu.addItem(blackItem("CPU 最高温度: 不可用"))
        }

        if let cpuAverage = TemperatureModel.average(from: snapshot.cpuReadings) {
            menu.addItem(blackItem(String(format: "CPU 平均温度: %.1f°", cpuAverage)))
        }

        menu.addItem(.separator())

        if let gpu = TemperatureModel.hottest(from: snapshot.gpuReadings) {
            menu.addItem(blackItem(String(format: "GPU 最高温度: %.1f°", gpu.value)))
            menu.addItem(blackItem("  传感器: \(gpu.sensorName)"))
        } else {
            menu.addItem(blackItem("GPU 最高温度: 不可用"))
        }

        if let gpuAverage = TemperatureModel.average(from: snapshot.gpuReadings) {
            menu.addItem(blackItem(String(format: "GPU 平均温度: %.1f°", gpuAverage)))
        }

        menu.addItem(.separator())
        menu.addItem(blackItem("热压力: \(snapshot.thermalPressure)"))
        menu.addItem(blackItem("充电功率: \(TemperatureModel.chargingPowerText(snapshot: snapshot))"))
        menu.addItem(blackItem("更新时间: \(TemperatureModel.timestampText(snapshot.timestamp))"))
        menu.addItem(.separator())

        addLEDSection(to: menu)

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.attributedTitle = NSAttributedString(
            string: "退出",
            attributes: [.foregroundColor: NSColor.black]
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - MagSafe LED

    private func checkItem(_ title: String, active: Bool, represented: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        item.target = self
        item.action = action
        item.representedObject = represented
        let text = active ? "✓ \(title)" : "    \(title)"
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.black]
        )
        return item
    }

    private func actionItem(_ title: String, represented: String?, action: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        item.target = self
        item.action = action
        if let represented { item.representedObject = represented }
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: NSColor.black]
        )
        return item
    }

    private func addLEDSection(to menu: NSMenu) {
        menu.addItem(blackItem("MagSafe 灯:"))

        guard let status = MagSafeLEDClient.shared.status(),
              (status["ok"] as? Bool) == true else {
            menu.addItem(actionItem("启用 MagSafe 灯控制…(需一次管理员授权)", represented: nil, action: #selector(ledInstallClicked)))
            return
        }

        let mode = status["mode"] as? String ?? "system"
        menu.addItem(checkItem("开(系统默认)", active: mode != "off", represented: "system", action: #selector(ledSetMode(_:))))
        menu.addItem(checkItem("关", active: mode == "off", represented: "off", action: #selector(ledSetMode(_:))))
        menu.addItem(.separator())
        menu.addItem(actionItem("卸载辅助工具…", represented: nil, action: #selector(ledUninstallClicked)))
    }

    private func applyLEDConfig() {
        MagSafeLEDPrefs.syncToDaemon()
        refresh()
    }

    // MARK: MagSafe LED helper lifecycle

    private var installCancelledThisSession = false
    private var installInFlight = false
    private var autoRepairAttempts = 0

    /// Waits for the auto-started daemon, then auto-installs it (admin dialog)
    /// unless the user explicitly uninstalled it or cancelled earlier.
    private func scheduleAutoSetup() {
        DispatchQueue.global().async { [weak self] in
            // launchd throttled respawn can take 10 s+; wait up to 15 s
            for _ in 0..<15 where MagSafeLEDClient.shared.status() == nil {
                usleep(1_000_000)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if MagSafeLEDClient.shared.status() != nil {
                    // daemon config is the source of truth on startup; the app
                    // only writes when the user actively picks something
                    self.refresh()
                    return
                }
                // Auto-prompt ONLY for the true first run (helper never
                // installed, user never removed it). A daemon that later
                // disappears is surfaced as a manual menu item instead —
                // never an unrequested admin dialog.
                if MagSafeLEDInstaller.isPlistInstalled() {
                    self.refresh()
                    return
                }
                if MagSafeLEDPrefs.helperRemovedByUser || self.installCancelledThisSession {
                    self.refresh()
                    return
                }
                self.installHelper(auto: true)
            }
        }
    }

    /// Runs the privileged installer (admin authorization dialog), then waits
    /// up to 30 s for the daemon socket. Success/failure is judged on the
    /// socket being live, not on the script exit code.
    private func installHelper(auto: Bool) {
        guard !installInFlight else { return }
        if auto && autoRepairAttempts >= 2 { return } // dialog-loop breaker
        installInFlight = true
        DispatchQueue.global().async { [weak self] in
            let ok = MagSafeLEDInstaller.install() && MagSafeLEDClient.shared.waitUpTo(seconds: 30)
            DispatchQueue.main.async {
                guard let self else { return }
                self.installInFlight = false
                if ok {
                    MagSafeLEDPrefs.helperRemovedByUser = false
                    self.installCancelledThisSession = false
                } else {
                    // cancelled or failed: don't auto-prompt again this session
                    self.installCancelledThisSession = true
                }
                if auto { self.autoRepairAttempts += 1 }
                self.refresh()
            }
        }
    }

    @objc private func ledSetMode(_ sender: NSMenuItem) {
        MagSafeLEDPrefs.mode = sender.representedObject as? String ?? "system"
        applyLEDConfig()
    }

    @objc private func ledInstallClicked() {
        installHelper(auto: false)
    }

    @objc private func ledUninstallClicked() {
        let alert = NSAlert()
        alert.messageText = "卸载 MagSafe 灯辅助工具?"
        alert.informativeText = "LED 将恢复系统默认,后台守护进程和配置会被移除(需要管理员授权)。卸载后再次启用需重新授权。"
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            MagSafeLEDInstaller.uninstall()
            MagSafeLEDPrefs.mode = "system"
            MagSafeLEDPrefs.helperRemovedByUser = true
            installCancelledThisSession = false
            refresh()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
