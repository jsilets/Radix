import Foundation

/// Lists Docker volumes, unused images, and build cache from `docker system df -v`.
/// Sizes come from Docker. They are space inside Docker's disk image, which returns
/// to macOS after Docker trims the image, usually within minutes.
nonisolated enum DockerCleanupProvider {
    /// Parses Docker's decimal sizes, such as "17.09GB", "1.374kB", or "60B".
    static func parseSize(_ text: String) -> Int64? {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for (suffix, multiplier) in units where trimmed.hasSuffix(suffix) {
            guard let value = Double(trimmed.dropLast(suffix.count)) else { return nil }
            return Int64(value * multiplier)
        }
        return nil
    }

    /// Splits Docker's "key=value,key=value" label string.
    static func parseLabels(_ text: String) -> [String: String] {
        var labels: [String: String] = [:]
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if let key = parts.first { labels[key] = parts.count > 1 ? parts[1] : "" }
        }
        return labels
    }

    static func parse(_ json: String) -> [CleanupItem] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let containers = root["Containers"] as? [[String: Any]] ?? []
        var items: [CleanupItem] = []

        for volume in root["Volumes"] as? [[String: Any]] ?? [] {
            guard let name = volume["Name"] as? String else { continue }
            let size = (volume["Size"] as? String).flatMap(parseSize)
            let labels = parseLabels(volume["Labels"] as? String ?? "")
            let users = containers.filter { (($0["Mounts"] as? String) ?? "").split(separator: ",").contains { $0 == name } }
            let running = users.filter { ($0["State"] as? String) == "running" }.compactMap { $0["Names"] as? String }
            let stopped = users.filter { ($0["State"] as? String) != "running" }.compactMap { $0["Names"] as? String }
            let anonymous = labels["com.docker.volume.anonymous"] != nil
            let project = labels["com.docker.compose.project"]
            // Compose already names its volumes "<project>_<volume>".
            let title = anonymous ? "Anonymous volume " + String(name.prefix(12)) : name
            let subtitle = project.map { "Compose project \($0)" } ?? (anonymous ? "Not named; made by a container" : "Named volume")
            let status = stopped.isEmpty ? "No container uses it" : "Used by stopped " + stopped.joined(separator: ", ")
            items.append(CleanupItem(
                id: "docker-volume:" + name,
                category: .docker,
                title: title,
                subtitle: subtitle,
                status: running.isEmpty ? status : "In use by " + running.joined(separator: ", "),
                safety: anonymous && (size ?? 0) < 1_000_000 ? .review : .holdsData,
                frees: size, holds: size, lastUsed: nil, measurePaths: [],
                action: .deleteDockerVolume(name: name, stoppedContainers: stopped),
                blockedReason: running.isEmpty ? nil : "A running container uses it"
            ))
        }

        let unusedImages = (root["Images"] as? [[String: Any]] ?? []).filter { ($0["Containers"] as? String) == "0" }
        if !unusedImages.isEmpty {
            let size = unusedImages.compactMap { ($0["UniqueSize"] as? String).flatMap(parseSize) }.reduce(0, +)
            items.append(CleanupItem(
                id: "docker-images", category: .docker,
                title: "\(unusedImages.count) unused image\(unusedImages.count == 1 ? "" : "s")",
                subtitle: unusedImages.prefix(3).compactMap { $0["Repository"] as? String }.joined(separator: ", "),
                status: "No container uses them · Docker pulls them again when needed",
                safety: .safe, frees: size, holds: size, lastUsed: nil, measurePaths: [],
                action: .pruneDockerImages, blockedReason: nil
            ))
        }

        let cache = (root["BuildCache"] as? [[String: Any]] ?? []).filter { ($0["InUse"] as? Bool) != true && ($0["InUse"] as? String) != "true" }
        if !cache.isEmpty {
            let size = cache.compactMap { ($0["Size"] as? String).flatMap(parseSize) }.reduce(0, +)
            items.append(CleanupItem(
                id: "docker-buildcache", category: .docker,
                title: "Build cache", subtitle: "\(cache.count) cached build step\(cache.count == 1 ? "" : "s")",
                status: "Rebuilt on the next docker build",
                safety: .safe, frees: size, holds: size, lastUsed: nil, measurePaths: [],
                action: .pruneDockerBuildCache, blockedReason: nil
            ))
        }
        return items
    }

    static func scan() async -> (items: [CleanupItem], notice: String?) {
        guard CommandRunner.isAvailable("docker") else { return ([], "Docker is not installed.") }
        guard let info = try? await CommandRunner.run("docker", ["info", "--format", "{{.ServerVersion}}"], timeout: 10),
              info.succeeded else { return ([], "Docker is not running. Start Docker Desktop to list volumes and images.") }
        guard let df = try? await CommandRunner.run("docker", ["system", "df", "-v", "--format", "{{json .}}"], timeout: 60),
              df.succeeded else { return ([], "Docker did not report its disk use.") }
        return (parse(df.stdout), nil)
    }
}
