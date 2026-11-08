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
            deadStatusCount += 1
            // self-heal: daemon vanished but the helper is still installed —
            // re-run the installer automatically (one admin dialog)
            if deadStatusCount == 3, MagSafeLEDInstaller.isPlistInstalled(),
               !MagSafeLEDPrefs.helperRemovedByUser, !installCancelledThisSession {
                deadStatusCount = 0
                installHelper()
            } else {
                menu.addItem(actionItem("启用 MagSafe 灯控制…(需一次管理员授权)", represented: nil, action: #selector(ledInstallClicked)))
            }
            return
        }
        deadStatusCount = 0

        let mode = status["mode"] as? String ?? "system"
        menu.addItem(checkItem("系统默认", active: mode == "system", represented: "system", action: #selector(ledSetMode(_:))))
        menu.addItem(checkItem("关闭", active: mode == "off", represented: "off", action: #selector(ledSetMode(_:))))
        menu.addItem(checkItem("呼吸模式", active: mode == "breathing", represented: "breathing", action: #selector(ledSetMode(_:))))
        menu.addItem(breathingSettingsItem(status))
        menu.addItem(.separator())
        menu.addItem(actionItem("卸载辅助工具…", represented: nil, action: #selector(ledUninstallClicked)))
    }

    private func breathingSettingsItem(_ status: [String: Any]) -> NSMenuItem {
        let color = status["color"] as? String ?? "auto"
        let period = (status["period"] as? Double) ?? MagSafeLEDPrefs.period
        let wave = status["wave"] as? String ?? "sine"

        let sub = NSMenu()
        sub.autoenablesItems = false

        sub.addItem(blackItem("呼吸颜色:"))
        sub.addItem(checkItem("自动(充电橙 / 充满绿)", active: color == "auto", represented: "auto", action: #selector(ledSetColor(_:))))
        sub.addItem(checkItem("绿色", active: color == "green", represented: "green", action: #selector(ledSetColor(_:))))
        sub.addItem(checkItem("橙色", active: color == "amber", represented: "amber", action: #selector(ledSetColor(_:))))

        sub.addItem(.separator())
        sub.addItem(blackItem("呼吸速度:"))
        sub.addItem(checkItem("慢(6 秒)", active: abs(period - 6.0) < 0.05, represented: "6", action: #selector(ledSetSpeed(_:))))
        sub.addItem(checkItem("中(4 秒)", active: abs(period - 4.0) < 0.05, represented: "4", action: #selector(ledSetSpeed(_:))))
        sub.addItem(checkItem("快(2.5 秒)", active: abs(period - 2.5) < 0.05, represented: "2.5", action: #selector(ledSetSpeed(_:))))
        sub.addItem(checkItem("自定义…", active: ![6.0, 4.0, 2.5].contains { abs(period - $0) < 0.05 },
                               represented: "", action: #selector(ledCustomSpeedClicked)))

        sub.addItem(.separator())
        sub.addItem(blackItem("波形:"))
        sub.addItem(checkItem("正弦", active: wave == "sine", represented: "sine", action: #selector(ledSetWave(_:))))
        sub.addItem(checkItem("线性", active: wave == "linear", represented: "linear", action: #selector(ledSetWave(_:))))

        let parent = NSMenuItem()
        parent.attributedTitle = NSAttributedString(
            string: "呼吸设置…",
            attributes: [.foregroundColor: NSColor.black]
        )
        parent.submenu = sub
        return parent
    }

    private func applyLEDConfig() {
        MagSafeLEDPrefs.syncToDaemon()
        refresh()
    }

    // MARK: MagSafe LED helper lifecycle

    private var installCancelledThisSession = false
    private var installInFlight = false
    private var deadStatusCount = 0

    /// Waits for the auto-started daemon, then auto-installs it (admin dialog)
    /// unless the user explicitly uninstalled it or cancelled earlier.
    private func scheduleAutoSetup() {
        DispatchQueue.global().async { [weak self] in
            for _ in 0..<8 where MagSafeLEDClient.shared.status() == nil {
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
                if MagSafeLEDPrefs.helperRemovedByUser || self.installCancelledThisSession {
                    self.refresh()
                    return
                }
                self.installHelper()
            }
        }
    }

    /// Runs the privileged installer (admin authorization dialog); on success
    /// waits for the daemon socket and pushes the stored settings.
    private func installHelper() {
        guard !installInFlight else { return }
        installInFlight = true
        DispatchQueue.global().async { [weak self] in
            let ok = MagSafeLEDInstaller.install()
            DispatchQueue.main.async {
                guard let self else { return }
                self.installInFlight = false
                if ok {
                    MagSafeLEDPrefs.helperRemovedByUser = false
                    // no config push here: the daemon persists its own settings
                } else {
                    // cancelled or failed: don't auto-prompt again this session
                    self.installCancelledThisSession = true
                }
                self.refresh()
            }
        }
    }

    @objc private func ledSetMode(_ sender: NSMenuItem) {
        MagSafeLEDPrefs.mode = sender.representedObject as? String ?? "system"
        applyLEDConfig()
    }

    @objc private func ledSetColor(_ sender: NSMenuItem) {
        MagSafeLEDPrefs.color = sender.representedObject as? String ?? "auto"
        applyLEDConfig()
    }

    @objc private func ledSetSpeed(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String, let period = Double(text) {
            MagSafeLEDPrefs.period = period
            applyLEDConfig()
        }
    }

    @objc private func ledCustomSpeedClicked() {
        let alert = NSAlert()
        alert.messageText = "自定义呼吸周期"
        alert.informativeText = "输入一个完整呼吸周期(亮→灭→亮)的时长,范围 1–6 秒。"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.doubleValue = MagSafeLEDPrefs.period
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            let value = input.doubleValue
            guard value >= 1.0, value <= 6.0 else { return }
            MagSafeLEDPrefs.period = value
            applyLEDConfig()
        }
    }

    @objc private func ledSetWave(_ sender: NSMenuItem) {
        MagSafeLEDPrefs.wave = sender.representedObject as? String ?? "sine"
        applyLEDConfig()
    }

    @objc private func ledInstallClicked() {
        installHelper()
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
