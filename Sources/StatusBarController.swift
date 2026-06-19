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

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.attributedTitle = NSAttributedString(
            string: "退出",
            attributes: [.foregroundColor: NSColor.black]
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
