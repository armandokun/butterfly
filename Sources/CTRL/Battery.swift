import Foundation
import IOKit.ps

/// Plug in / unplug, low battery, fully charged; and "how much battery do I have".
@MainActor
final class Battery {
    static let shared = Battery()

    struct State: Equatable {
        let percent: Int
        let onAC: Bool
        let charging: Bool
        let charged: Bool
        let minutesLeft: Int?   // to empty on battery, to full when charging
    }

    /// Called on plug/unplug, crossing 20% and 10%, and full charge.
    var onEvent: ((State, Event) -> Void)?
    enum Event { case plugged, unplugged, low, critical, full }

    private var last: State?
    private var source: CFRunLoopSource?

    static var now: State? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let ac = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int
            return State(percent: Int((Double(cur) / Double(max) * 100).rounded()), onAC: ac, charging: charging,
                         charged: d[kIOPSIsChargedKey] as? Bool ?? (ac && cur >= max),
                         minutesLeft: (minutes ?? -1) > 0 ? minutes : nil)
        }
        return nil   // desktop Mac
    }

    func start() {
        last = Self.now
        guard last != nil else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<Battery>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in me.changed() }
        }, ctx)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    private func changed() {
        guard let s = Self.now, let before = last else { return }
        last = s
        if s.onAC != before.onAC { return onEvent?(s, s.onAC ? .plugged : .unplugged) ?? () }
        if !s.onAC, before.percent > 10, s.percent <= 10 { return onEvent?(s, .critical) ?? () }
        if !s.onAC, before.percent > 20, s.percent <= 20 { return onEvent?(s, .low) ?? () }
        if s.onAC, s.percent >= 100, before.percent < 100 { onEvent?(s, .full) }
    }

    static func symbol(_ s: State) -> String {
        if s.onAC && !s.charged && s.charging { return "battery.100percent.bolt" }
        if s.onAC && s.percent >= 100 { return "powerplug.fill" }
        switch s.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// "2 h 10 min left" / "Full in 40 min" / "Charged".
    static func detail(_ s: State) -> String? {
        if s.onAC {
            if s.percent >= 100 || s.charged { return "Charged" }
            if !s.charging { return "Plugged in, not charging" }
            return s.minutesLeft.map { "Full in \(spoken($0))" } ?? "Charging"
        }
        return s.minutesLeft.map { "\(spoken($0)) left" }
    }

    private static func spoken(_ m: Int) -> String {
        m >= 60 ? "\(m / 60) h" + (m % 60 > 0 ? " \(m % 60) min" : "") : "\(m) min"
    }
}
