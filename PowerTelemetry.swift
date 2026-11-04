import Foundation

/// One IORegistry snapshot. Signed NSNumber decoding preserves negative currents
/// that some firmware encodes as an unsigned 64-bit two's-complement value.
enum PowerTelemetry {
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber else { return nil }
        let value = n.doubleValue
        return value.isFinite ? value : nil
    }
    static func current(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber else { return nil }
        let ma = n.doubleValue > Double(Int64.max) ? Double(n.int64Value) : n.doubleValue
        return ma.isFinite && abs(ma) <= 30_000 ? ma / 1000 : nil
    }
    static func positive(_ value: Any?, scale: Double = 1, max: Double = 500) -> Double? {
        guard let n = number(value).map({ $0 / scale }), n > 0, n <= max else { return nil }
        return n
    }
    static func apply(_ properties: [String: Any], adapter: [String: Any]?, to s: inout Snapshot, now: Date = Date()) {
        s.batteryVoltageV = positive(properties["Voltage"], scale: 1000, max: 30)
        s.batteryCurrentA = current(properties["InstantAmperage"]) ?? current(properties["Amperage"])
        s.batteryFullyCharged = (properties["FullyCharged"] as? NSNumber)?.boolValue ?? false
        s.batteryAdapterWatts = nil
        s.batteryInputWatts = nil
        s.batteryInputSource = ""
        s.batteryPowerUpdated = now
        guard s.onAC else { return } // never retain AC telemetry after unplugging
        let details = properties["AdapterDetails"] as? [String: Any]
        s.batteryAdapterWatts = positive(adapter?["Watts"]) ?? positive(details?["Watts"])
        if let telemetry = properties["PowerTelemetryData"] as? [String: Any],
           let input = positive(telemetry["SystemPowerIn"], scale: 1000) {
            s.batteryInputWatts = input
            s.batteryInputSource = "电源遥测 · DC 输入"
        }
    }
}

/// Explicit CLI diagnostics: queries capabilities without setting any hardware value.
enum HardwareCapabilities {
    static func printSnapshot() {
        var s = Snapshot(); Readers.battery(into: &s)
        let flow = PowerFlowCalc.fromSnapshot(s)
        let displays = RealDisplaySystem().displays(), services = AVServiceDDC.externals()
        let profiles = ColorSyncProfiles()
        let monitors: [[String: Any]] = displays.map { display in
            let channel = display.builtin ? nil : DDCIdentity.match(display, in: services, displays: displays)
            let caps = channel.map { DDCCaps.parse($0.capabilities()) }
            let profile = profiles.read(display.id)
            return ["name": display.name, "builtin": display.builtin, "ddcMatched": channel != nil,
                    "colorPresets": caps?.values[0x14] ?? [], "displayModes": caps?.values[0xdc] ?? [],
                    "profiles": profile.choices.map(\.name), "currentProfile": profile.current?.lastPathComponent ?? "unknown",
                    "hasCustomProfile": profile.overrideURL != nil]
        }
        let source = RealBTSource(), classic = source.classic()
        let devices = BTParse.merge(paired: source.paired(), ioreg: source.ioreg(), gatt: [:], gattIssue: nil, classic: classic)
        let keyboards: [[String: Any]] = devices.filter { $0.name.lowercased().contains("keychron") }.map {
            ["name": $0.name, "connected": $0.connected, "percent": $0.percent.map { $0 as Any } ?? NSNull(), "source": $0.source, "reason": $0.reason]
        }
        let battery: [String: Any] = ["inputWatts": flow.inputWatts.map { $0 as Any } ?? NSNull(), "adapterReportedWatts": flow.adapterRatedWatts.map { $0 as Any } ?? NSNull(), "systemEstimateWatts": flow.systemWatts.map { $0 as Any } ?? NSNull(), "state": flow.supplyText, "inputSource": flow.inputNote]
        let result: [String: Any] = ["readOnly": true, "battery": battery, "displays": monitors, "keychron": keyboards]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { FileHandle.standardOutput.write(data) }
    }
}
