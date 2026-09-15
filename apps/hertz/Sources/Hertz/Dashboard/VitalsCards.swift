import HertzCore
import SwiftUI

// MARK: - CPU

struct CPUCard: View {
    let cpu: CPUSnapshot
    let history: [Double]
    let sensors: SensorSnapshot

    private var detail: String {
        var parts = ["load " + String(format: "%.2f · %.2f · %.2f", cpu.load1, cpu.load5, cpu.load15)]
        if sensors.cpuTemperature > 0 {
            parts.append(String(format: "%.0f°C", sensors.cpuTemperature))
        }
        if let fan = sensors.fanRPM.first, fan > 0 {
            parts.append("\(fan) rpm")
        }
        return parts.joined(separator: "   ")
    }

    private var thermal: (Level, String)? {
        switch cpu.thermalPressure {
        case .unknown, .nominal: return nil
        case .moderate: return (.warning, "THERMAL \(cpu.thermalPressure.label)")
        case .heavy, .critical: return (.critical, "THERMAL \(cpu.thermalPressure.label)")
        }
    }

    var body: some View {
        Card {
            CardHeader("CPU") {
                if let thermal {
                    StatePill(level: thermal.0, text: thermal.1)
                }
                Readout(value: Format.percent(cpu.total, decimals: 1), level: Level.load(cpu.total))
            }
            Sparkline(values: history, color: Level.load(cpu.total).color).frame(height: 30)
            CoreBars(perCore: cpu.perCore)
            DetailLine(detail)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("CPU \(Format.percent(cpu.total)), \(detail)")
    }
}

// MARK: - Memory

struct MemoryCard: View {
    let memory: MemorySnapshot
    let history: [Double]

    private var level: Level {
        switch memory.pressureLevel {
        case .normal: return .ok
        case .warning: return .warning
        case .critical: return .critical
        case .unknown: return Level.load(memory.pressurePercent)
        }
    }

    private var pressureText: String {
        switch memory.pressureLevel {
        case .unknown: return "pressure —"
        default: return "pressure \(Format.percent(memory.pressurePercent))"
        }
    }

    var body: some View {
        Card {
            CardHeader("Memory") {
                Readout(value: Format.percent(memory.usedPercent), level: level)
            }
            Sparkline(values: history, color: level.color, fixedCeiling: 100).frame(height: 30)
            HStack(spacing: Brand.Space.s16) {
                Stat(label: "used", value: Format.bytes(memory.used))
                Stat(label: "free", value: Format.bytes(memory.free))
                if memory.swapTotal > 0 {
                    Stat(label: "swap", value: Format.bytes(memory.swapUsed))
                }
                Spacer(minLength: 0)
            }
            DetailLine(pressureText + (memory.pressureLevel == .unknown ? "" : " · \(memory.pressureLevel.label)"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memory \(Format.percent(memory.usedPercent)) used, \(pressureText)")
    }
}

// MARK: - Disk

struct DiskCard: View {
    let disk: DiskSnapshot

    private var level: Level { Level.load(disk.usedPercent) }

    var body: some View {
        Card {
            CardHeader("Disk") {
                Ring(fraction: disk.usedPercent / 100, color: level.color)
                    .frame(width: 18, height: 18)
            }
            Text("\(Format.gigabytes(disk.free)) free")
                .font(Brand.mono(15, medium: true))
                .foregroundStyle(Brand.textPrimary)
            Bar(fraction: disk.usedPercent / 100, color: level.color)
            HStack(spacing: Brand.Space.s12) {
                Stat(label: "read, all disks", value: Format.rate(disk.readRate), icon: "arrow.down")
                Stat(label: "write, all disks", value: Format.rate(disk.writeRate), icon: "arrow.up")
            }
            DetailLine("\(Format.gigabytes(disk.used)) of \(Format.gigabytes(disk.total))\(disk.fsType.isEmpty ? "" : " · \(disk.fsType)")")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Disk \(Format.percent(disk.usedPercent)) used, \(Format.gigabytes(disk.free)) free")
    }
}

// MARK: - Network

struct NetworkCard: View {
    let network: NetSnapshot
    let history: [Double]

    private var detail: String {
        var parts: [String] = []
        if !network.interface.isEmpty { parts.append(network.interface) }
        if !network.ssid.isEmpty { parts.append(network.ssid) }
        if !network.localIP.isEmpty { parts.append(network.localIP) }
        return parts.isEmpty ? "offline" : parts.joined(separator: " · ")
    }

    var body: some View {
        Card {
            CardHeader("Network") {
                if network.vpnActive {
                    StatePill(level: .ok, text: "VPN")
                }
            }
            Sparkline(values: history).frame(height: 22)
            HStack(spacing: Brand.Space.s12) {
                Stat(label: "down", value: Format.rate(network.down), icon: "arrow.down")
                Stat(label: "up", value: Format.rate(network.up), icon: "arrow.up")
            }
            DetailLine(detail)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Network down \(Format.rate(network.down)), up \(Format.rate(network.up)), \(detail)")
    }
}

// MARK: - Battery

struct BatteryCard: View {
    let battery: BatterySnapshot
    let devices: [DeviceBattery]

    private var status: String {
        var base: String
        if battery.charging {
            base = battery.minutesRemaining >= 0 ? "\(Format.minutes(battery.minutesRemaining)) to full" : "charging"
        } else if battery.onAC {
            base = battery.percent >= 99 ? "charged" : "plugged in"
        } else {
            return battery.minutesRemaining >= 0 ? "\(Format.minutes(battery.minutesRemaining)) left" : "on battery"
        }
        if battery.acMinutes >= 0 {
            base += " · \(Format.minutes(battery.acMinutes)) on power"
        }
        return base
    }

    private var detail: String {
        var parts: [String] = []
        if abs(battery.powerWatts) >= 0.05 {
            parts.append(String(format: battery.powerWatts > 0 ? "%.1f W in" : "%.1f W draw", abs(battery.powerWatts)))
        }
        if battery.cycleCount > 0 { parts.append("\(battery.cycleCount) cycles") }
        if battery.healthPercent > 0 { parts.append("\(Format.percent(battery.healthPercent)) health") }
        if battery.temperature > 0 { parts.append(String(format: "%.1f°C", battery.temperature)) }
        if battery.onAC && battery.adapterWatts > 0 { parts.append("\(battery.adapterWatts) W adapter") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Card {
            CardHeader("Battery") {
                if battery.present {
                    if battery.charging || battery.onAC {
                        Image(systemName: battery.charging ? "bolt.fill" : "powerplug.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Brand.textSecondary)
                            .accessibilityLabel(battery.charging ? "charging" : "plugged in")
                    }
                    Readout(value: Format.percent(battery.percent), level: Level.charge(battery.percent))
                }
            }
            if battery.present {
                Bar(fraction: battery.percent / 100, color: Level.charge(battery.percent).color)
                Text(status)
                    .font(Brand.body(13))
                    .foregroundStyle(Brand.textPrimary)
                if !detail.isEmpty { DetailLine(detail) }
            }
            ForEach(devices) { device in
                AccessoryRow(device: device)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(battery.present ? "Battery \(Format.percent(battery.percent)), \(status)" : "Accessory batteries")
    }

    /// One connected accessory — Magic Mouse / Keyboard / Trackpad.
    private struct AccessoryRow: View {
        let device: DeviceBattery

        private var icon: String {
            let name = device.name.lowercased()
            if name.contains("mouse") { return "magicmouse" }
            if name.contains("keyboard") { return "keyboard" }
            if name.contains("trackpad") { return "trackpad" }
            return "dot.radiowaves.right"
        }

        var body: some View {
            HStack(spacing: Brand.Space.s8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.textSecondary)
                    .frame(width: 16)
                Text(device.name)
                    .font(Brand.body(13))
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
                if Level.charge(Double(device.percent)) != .ok {
                    StatePill(level: Level.charge(Double(device.percent)), text: "LOW")
                }
                Text(Format.percent(Double(device.percent)))
                    .font(Brand.mono(12, medium: true))
                    .foregroundStyle(Brand.textPrimary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
