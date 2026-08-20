import Foundation

/// Slot-keyed usage windows from the last successful Claude Swap projection.
/// Display labels and emails stay out of the cache so one-shot CLI/dashboard
/// calls can retain at-limit bars without persisting identity.
public enum ClaudeSwapRetainedUsageStore {
    public static func load() -> [ProviderAccountUsageSnapshot] {
        guard let url = self.resolvedFileURL(),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([Record].self, from: data)
        else { return [] }
        return records.map(\.account)
    }

    public static func save(_ accounts: [ProviderAccountUsageSnapshot]) {
        guard let url = self.resolvedFileURL() else { return }
        let records = accounts.compactMap(Record.init(account:))
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func resolvedFileURL() -> URL? {
        if self.isRunningTests { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("claude-swap-retained-usage.json")
    }

    private static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return true
        }
        if ProcessInfo.processInfo.processName.lowercased().contains("xctest") {
            return true
        }
        return CommandLine.arguments.contains { $0.lowercased().contains(".xctest") }
    }

    private struct Record: Codable {
        var opaqueID: String
        var primary: RateWindow?
        var secondary: RateWindow?
        var extraRateWindows: [NamedRateWindow]?
        var updatedAt: Date

        init?(account: ProviderAccountUsageSnapshot) {
            guard account.id.source == ClaudeSwapAccountProjection.sourceName,
                  let snapshot = account.snapshot
            else { return nil }
            self.opaqueID = account.id.opaqueID
            self.primary = snapshot.primary
            self.secondary = snapshot.secondary
            self.extraRateWindows = snapshot.extraRateWindows
            self.updatedAt = snapshot.updatedAt
        }

        var account: ProviderAccountUsageSnapshot {
            ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(
                    source: ClaudeSwapAccountProjection.sourceName,
                    opaqueID: self.opaqueID),
                provider: .claude,
                displayLabel: "",
                isActive: false,
                snapshot: UsageSnapshot(
                    primary: self.primary,
                    secondary: self.secondary,
                    extraRateWindows: self.extraRateWindows,
                    updatedAt: self.updatedAt,
                    identity: nil),
                error: nil,
                sourceLabel: ClaudeSwapAccountProjection.sourceLabel)
        }
    }
}
