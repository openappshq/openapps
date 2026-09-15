/// What Hertz prints next to its symbol in the menu bar.
nonisolated public enum MenuBarReadout: String, CaseIterable, Sendable {
    case cpu
    case memory
    case none

    public var title: String {
        switch self {
        case .cpu: return "CPU usage"
        case .memory: return "Memory usage"
        case .none: return "Symbol only"
        }
    }

    /// The readout text for the current snapshot; empty for `.none`. Whole
    /// percentages, so the width only changes at 10% and 100%.
    public func text(cpu: CPUSnapshot, memory: MemorySnapshot) -> String {
        switch self {
        case .cpu: return Format.percent(cpu.total)
        case .memory: return Format.percent(memory.usedPercent)
        case .none: return ""
        }
    }
}
