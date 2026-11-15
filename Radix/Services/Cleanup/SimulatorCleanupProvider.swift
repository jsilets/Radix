import Foundation

/// Lists iOS simulator devices and runtimes from `xcrun simctl`.
nonisolated enum SimulatorCleanupProvider {
    /// A device unused for this long is preselected for removal.
    static let staleAfterDays = 30

    private static func date(_ text: String) -> Date? { try? Date(text, strategy: .iso8601) }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" becomes "iOS 26.5".
    static func runtimeName(_ identifier: String) -> String {
        let tail = identifier.components(separatedBy: ".").last ?? identifier
        var parts = tail.components(separatedBy: "-")
        guard parts.count > 1 else { return tail }
        let platform = parts.removeFirst()
        return platform + " " + parts.joined(separator: ".")
    }

    static func daysSince(_ date: Date?, now: Date) -> Int? {
        guard let date else { return nil }
        return Int(now.timeIntervalSince(date) / 86_400)
    }

    static func usageText(_ days: Int?) -> String {
        guard let days else { return "Never used" }
        switch days {
        case 0: return "Used today"
        case 1: return "Used yesterday"
        default: return "Unused for \(days) days"
        }
    }

    static func parseDevices(_ json: String, now: Date = Date()) -> [CleanupItem] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = root["devices"] as? [String: [[String: Any]]] else { return [] }
        var items: [CleanupItem] = []
        for (runtime, devices) in devicesByRuntime {
            for device in devices {
                guard let udid = device["udid"] as? String, let name = device["name"] as? String else { continue }
                let lastUsed = (device["lastUsedAt"] as? String).flatMap(date)
                let days = daysSince(lastUsed, now: now)
                let available = device["isAvailable"] as? Bool ?? true
                let booted = (device["state"] as? String) == "Booted"
                let dataPath = (device["dataPath"] as? String).map(URL.init(fileURLWithPath:))
                let status: String
                let safety: CleanupSafety
                if !available {
                    status = "Its runtime is not installed"
                    safety = .safe
                } else {
                    status = usageText(days)
                    safety = (days ?? Int.max) >= staleAfterDays ? .safe : .review
                }
                items.append(CleanupItem(
                    id: "simulator:" + udid,
                    category: .simulators,
                    title: name,
                    subtitle: runtimeName(runtime),
                    status: status,
                    safety: safety,
                    frees: nil, holds: nil,
                    lastUsed: lastUsed,
                    measurePaths: dataPath.map { [$0.deletingLastPathComponent()] } ?? [],
                    action: .deleteSimulator(udid: udid),
                    blockedReason: booted ? "Running now" : nil
                ))
            }
        }
        return items
    }

    static func parseRuntimes(_ json: String, deviceCounts: [String: Int], now: Date = Date()) -> [CleanupItem] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        return root.values.compactMap { runtime in
            guard let identifier = runtime["identifier"] as? String,
                  let runtimeIdentifier = runtime["runtimeIdentifier"] as? String else { return nil }
            let size = (runtime["sizeBytes"] as? NSNumber)?.int64Value
            let lastUsed = (runtime["lastUsedAt"] as? String).flatMap(date)
            let devices = deviceCounts[runtimeIdentifier] ?? 0
            let deletable = runtime["deletable"] as? Bool ?? false
            return CleanupItem(
                id: "simruntime:" + identifier,
                category: .simulators,
                title: runtimeName(runtimeIdentifier) + " runtime",
                subtitle: "\(devices) device\(devices == 1 ? "" : "s") use it · needed to run any \(runtimeName(runtimeIdentifier).components(separatedBy: " ").first ?? "") simulator",
                status: usageText(daysSince(lastUsed, now: now)),
                safety: .review,
                frees: size, holds: size,
                lastUsed: lastUsed,
                measurePaths: [],
                action: .deleteSimulatorRuntime(identifier: identifier),
                blockedReason: deletable ? nil : "macOS does not allow deleting it"
            )
        }
    }

    static func scan() async -> (items: [CleanupItem], notice: String?) {
        guard let devices = try? await CommandRunner.run("xcrun", ["simctl", "list", "devices", "--json"]),
              devices.succeeded else {
            return ([], "Xcode command-line tools are not available, so simulators cannot be listed.")
        }
        let deviceItems = parseDevices(devices.stdout)
        var counts: [String: Int] = [:]
        if let data = devices.stdout.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let byRuntime = root["devices"] as? [String: [Any]] {
            for (runtime, list) in byRuntime { counts[runtime] = list.count }
        }
        var runtimeItems: [CleanupItem] = []
        if let runtimes = try? await CommandRunner.run("xcrun", ["simctl", "runtime", "list", "--json"]), runtimes.succeeded {
            runtimeItems = parseRuntimes(runtimes.stdout, deviceCounts: counts)
        }
        return (deviceItems + runtimeItems, nil)
    }
}
