import Foundation

struct TemperatureSummary {
    let title: String
    let value: Double
    let sensorName: String
}

enum TemperatureModel {
    static func hottest(from readings: [TemperatureReading]) -> TemperatureSummary? {
        guard let reading = readings.max(by: { $0.value < $1.value }) else { return nil }
        return TemperatureSummary(title: reading.name, value: reading.value, sensorName: reading.name)
    }

    static func average(from readings: [TemperatureReading]) -> Double? {
        guard !readings.isEmpty else { return nil }
        let total = readings.reduce(0.0) { $0 + $1.value }
        return total / Double(readings.count)
    }

    static func menuBarText(snapshot: TemperatureSnapshot) -> String {
        if let cpu = hottest(from: snapshot.cpuReadings) {
            return String(format: "%.0f°", cpu.value)
        }
        if let hottest = hottest(from: snapshot.allReadings) {
            return String(format: "%.0f°", hottest.value)
        }
        return "--°"
    }

    static func timestampText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func chargingPowerText(snapshot: TemperatureSnapshot) -> String {
        if let watts = snapshot.chargingPowerWatts?.doubleValue {
            return String(format: "%.1f W", watts)
        }
        if !snapshot.hasBattery {
            return "不适用"
        }
        if snapshot.isExternalPowerConnected {
            return snapshot.isCharging ? "计算中" : "未充电"
        }
        return "未接入电源"
    }
}
