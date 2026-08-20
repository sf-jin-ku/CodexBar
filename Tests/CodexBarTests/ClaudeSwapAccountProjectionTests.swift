import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeSwapAccountProjectionTests {
    @Test
    func `adapter failures mark retained account snapshots as stale`() {
        #expect(ClaudeSwapAccountProjection.displayError(
            accountError: nil,
            adapterError: "timed out") == "Showing the last successful update: timed out")
        #expect(ClaudeSwapAccountProjection.displayError(
            accountError: "Token expired.",
            adapterError: "timed out") == "Token expired.")
        #expect(ClaudeSwapAccountProjection.displayError(
            accountError: nil,
            adapterError: "timed out",
            switchError: "store locked") == "Account switch failed: store locked")
        #expect(ClaudeSwapAccountProjection.displayError(
            accountError: "API-key account",
            adapterError: nil,
            switchError: "store locked") == "Account switch failed: store locked")
    }

    private let now = Date(timeIntervalSince1970: 1_782_000_000)

    @Test
    func `projects rows into provider neutral snapshots with active account first`() throws {
        let reset = Date(timeIntervalSince1970: 1_782_170_999)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 2,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "work@example.com",
                    isActive: false,
                    usageStatus: .ok,
                    fiveHour: ClaudeSwapUsageWindow(usedPercent: 25, resetsAt: reset),
                    sevenDay: ClaudeSwapUsageWindow(usedPercent: 16.5, resetsAt: nil)),
                ClaudeSwapAccountRow(
                    number: 2,
                    email: "personal@example.com",
                    isActive: true,
                    usageStatus: .ok,
                    fiveHour: ClaudeSwapUsageWindow(usedPercent: 80, resetsAt: nil),
                    sevenDay: nil),
            ])

        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now)
        #expect(snapshots.count == 2)

        let active = try #require(snapshots.first)
        #expect(active.id == ProviderAccountIdentity(source: "claude-swap", opaqueID: "2"))
        #expect(active.provider == .claude)
        #expect(active.displayLabel == "personal@example.com")
        #expect(active.isActive == true)
        #expect(active.canActivate == false)
        #expect(active.error == nil)
        #expect(active.sourceLabel == "claude-swap")
        #expect(active.snapshot?.primary?.usedPercent == 80)
        #expect(active.snapshot?.primary?.windowMinutes == 300)
        #expect(active.snapshot?.secondary == nil)
        #expect(active.snapshot?.updatedAt == self.now)
        #expect(active.snapshot?.identity?.accountEmail == "personal@example.com")
        #expect(active.snapshot?.identity?.accountOrganization == nil)
        #expect(active.snapshot?.identity?.accountID == "claude-swap:2")
        #expect(active.snapshot?.identity?.loginMethod == "claude-swap")

        let inactive = try #require(snapshots.last)
        #expect(inactive.id.opaqueID == "1")
        #expect(inactive.isActive == false)
        #expect(inactive.canActivate == true)
        #expect(inactive.snapshot?.primary?.resetsAt == reset)
        #expect(inactive.snapshot?.secondary?.usedPercent == 16.5)
        #expect(inactive.snapshot?.secondary?.windowMinutes == 10080)
    }

    @Test
    func `maps sentinel statuses to per account errors without usage`() throws {
        let rows: [(ClaudeSwapUsageStatus, String)] = [
            (.tokenExpired, "Token expired"),
            (.reloginRequired, "Re-login required"),
            (.apiKey, "API-key account"),
            (.keychainUnavailable, "Keychain"),
            (.noCredentials, "No stored credentials"),
            (.unavailable, "Usage fetch failed"),
            (.unknown("mystery"), "mystery"),
        ]

        for (index, entry) in rows.enumerated() {
            let list = ClaudeSwapAccountList(
                activeAccountNumber: nil,
                accounts: [
                    ClaudeSwapAccountRow(
                        number: index + 1,
                        email: "a@b.c",
                        isActive: false,
                        usageStatus: entry.0,
                        fiveHour: nil,
                        sevenDay: nil),
                ])
            let snapshot = try #require(
                ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
            #expect(snapshot.snapshot == nil)
            let error = try #require(snapshot.error)
            #expect(error.contains(entry.1))
            let expectedCanActivate = entry.0 == .apiKey || entry.0 == .unavailable
            #expect(snapshot.canActivate == expectedCanActivate)
        }
    }

    @Test
    func `ok row without windows reports missing usage instead of an empty card`() throws {
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .ok,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let snapshot = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
        #expect(snapshot.snapshot == nil)
        #expect(snapshot.error == "No usage windows reported.")
    }

    @Test
    func `projects model scoped weekly windows through claude usage rows`() throws {
        let reset = Date(timeIntervalSince1970: 1_784_620_800)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .ok,
                    fiveHour: nil,
                    sevenDay: nil,
                    scoped: [
                        ClaudeSwapScopedUsageWindow(name: "Fable", usedPercent: 33, resetsAt: reset),
                        ClaudeSwapScopedUsageWindow(name: "All models", usedPercent: 42, resetsAt: reset),
                    ]),
            ])

        let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
        let snapshot = try #require(account.snapshot)
        #expect(account.error == nil)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        let scoped = try #require(snapshot.extraRateWindows)
        #expect(scoped.count == 1)
        #expect(scoped.first?.id == "claude-weekly-scoped-fable")
        #expect(scoped.first?.title == "Fable only")
        #expect(scoped.first?.window.usedPercent == 33)
        #expect(scoped.first?.window.windowMinutes == 10080)
        #expect(scoped.first?.window.resetsAt == reset)
    }

    @Test
    func `filtered generic scope does not hide missing usage error`() throws {
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .ok,
                    fiveHour: nil,
                    sevenDay: nil,
                    scoped: [
                        ClaudeSwapScopedUsageWindow(name: "All models", usedPercent: 42, resetsAt: nil),
                    ]),
            ])

        let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
        #expect(account.snapshot == nil)
        #expect(account.error == "No usage windows reported.")
    }

    @Test
    func `falls back to ordinal label when email is empty`() throws {
        let list = ClaudeSwapAccountList(
            activeAccountNumber: nil,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 3,
                    email: "",
                    isActive: false,
                    usageStatus: .noCredentials,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let snapshot = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
        #expect(snapshot.displayLabel == "Account 3")
    }

    @Test
    func `keeps unique emails as email only even when organization names are present`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "work@example.com", organizationName: "Sendbird"),
                self.row(number: 2, email: "personal@example.com", organizationName: "Acme", active: true)),
            now: self.now)

        #expect(snapshots.map(\.displayLabel) == ["personal@example.com", "work@example.com"])
        #expect(snapshots.map { $0.snapshot?.identity?.accountOrganization } == [nil, nil])
        #expect(snapshots.map { $0.snapshot?.identity?.accountEmail } == [
            "personal@example.com",
            "work@example.com",
        ])
        #expect(snapshots.map(\.id.opaqueID) == ["2", "1"])
    }

    @Test
    func `disambiguates shared emails with organization name or slot ordinal`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "shared@example.com", organizationName: "Sendbird"),
                self.row(number: 4, email: "shared@example.com", organizationName: "", active: true)),
            now: self.now)

        #expect(snapshots.map(\.displayLabel) == [
            "shared@example.com · Account 4",
            "shared@example.com · Sendbird",
        ])
        #expect(snapshots.first?.id == ProviderAccountIdentity(source: "claude-swap", opaqueID: "4"))
        #expect(snapshots.last?.id == ProviderAccountIdentity(source: "claude-swap", opaqueID: "1"))
        #expect(snapshots.first?.snapshot?.identity?.accountOrganization == nil)
        #expect(snapshots.last?.snapshot?.identity?.accountOrganization == nil)
        #expect(snapshots.first?.snapshot?.identity?.accountEmail == "shared@example.com")
    }

    @Test
    func `prefers user alias over email and empty email ordinal`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "shared@example.com", organizationName: "Sendbird", alias: "Work"),
                self.row(number: 2, email: "shared@example.com", organizationName: "Acme"),
                self.row(number: 3, email: "", alias: "Empty slot")),
            now: self.now)

        #expect(snapshots.map(\.displayLabel) == ["Work", "shared@example.com · Acme", "Empty slot"])
        #expect(snapshots.map(\.id.opaqueID) == ["1", "2", "3"])
        #expect(snapshots.map { $0.snapshot?.identity?.accountOrganization } == [nil, nil, nil])
        #expect(snapshots.map { $0.snapshot?.identity?.accountEmail } == [
            "shared@example.com",
            "shared@example.com",
            nil,
        ])
    }

    @Test
    func `cloud sync payload omits display only organization names`() throws {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "shared@example.com", organizationName: "Sendbird"),
                self.row(
                    number: 2,
                    email: "shared@example.com",
                    organizationName: "Acme",
                    alias: "Work",
                    active: true)),
            now: self.now)
        let account = try #require(snapshots.first)
        let usage = try #require(account.snapshot)
        let payload = AccountSnapshotSyncPayload(
            provider: account.provider.instanceID,
            deviceID: "test-device",
            accountIdentity: account.accountEmail,
            displayLabel: account.accountEmail ?? "Account \(account.id.opaqueID)",
            usage: usage)
        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedUsage = try #require(json["usage"] as? [String: Any])

        #expect(account.displayLabel == "Work")
        #expect(payload.displayLabel == "shared@example.com")
        #expect(payload.usage.identity?.accountOrganization == nil)
        #expect(encodedUsage["accountOrganization"] == nil || encodedUsage["accountOrganization"] is NSNull)
        #expect(encodedUsage["accountEmail"] as? String == "shared@example.com")
        #expect(usage.identity?.accountID == "claude-swap:2")
    }

    @Test
    func `cloud sync keys duplicate swap slots by source identity`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "shared@example.com", organizationName: "Sendbird"),
                self.row(
                    number: 2,
                    email: "shared@example.com",
                    organizationName: "Acme",
                    active: true)),
            now: self.now)
        let names = snapshots.compactMap { account -> String? in
            guard let usage = account.snapshot else { return nil }
            let identity = usage.identity?.accountID
                ?? usage.identity?.accountEmail
                ?? "\(account.id.source):\(account.id.opaqueID)"
            return AccountSnapshotSyncPayload(
                provider: account.provider.instanceID,
                deviceID: "test-device",
                accountIdentity: identity,
                displayLabel: account.accountEmail ?? "Account \(account.id.opaqueID)",
                usage: usage).recordName
        }

        #expect(snapshots.map { $0.snapshot?.identity?.accountID } == [
            "claude-swap:2",
            "claude-swap:1",
        ])
        #expect(Set(names).count == 2)
    }

    @Test
    func `cloud sync payload omits aliases when swap email is missing`() throws {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(self.row(number: 3, email: "", alias: "Empty slot")),
            now: self.now)
        let account = try #require(snapshots.first)
        let usage = try #require(account.snapshot)
        let payload = AccountSnapshotSyncPayload(
            provider: account.provider.instanceID,
            deviceID: "test-device",
            accountIdentity: "\(account.id.source):\(account.id.opaqueID)",
            displayLabel: account.accountEmail ?? "Account \(account.id.opaqueID)",
            usage: usage)
        #expect(account.displayLabel == "Empty slot")
        #expect(account.accountEmail == nil)
        #expect(payload.displayLabel == "Account 3")
    }

    private func list(_ rows: ClaudeSwapAccountRow...) -> ClaudeSwapAccountList {
        ClaudeSwapAccountList(
            activeAccountNumber: rows.first { $0.isActive }?.number,
            accounts: rows)
    }

    private func row(
        number: Int,
        email: String,
        organizationName: String = "",
        alias: String? = nil,
        active: Bool = false) -> ClaudeSwapAccountRow
    {
        ClaudeSwapAccountRow(
            number: number,
            email: email,
            organizationName: organizationName,
            alias: alias,
            isActive: active,
            usageStatus: .ok,
            fiveHour: ClaudeSwapUsageWindow(usedPercent: 10, resetsAt: nil),
            sevenDay: nil)
    }
}
