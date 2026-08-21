import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexMonthlyCreditPreservationTests {
    @Test
    func `enrichment failure keeps prior monthly limit on incoming credits`() {
        let now = Date()
        let incoming = CreditsSnapshot(remaining: 4, events: [], updatedAt: now)
        let prior = Self.credits(limitUsed: 27, limit: 1000, remaining: 0, at: now.addingTimeInterval(-60))

        let merged = CodexMonthlyCreditPreservation.merging(
            incoming: incoming,
            prior: prior,
            enrichmentFailed: true)

        #expect(merged?.remaining == 4)
        #expect(merged?.codexCreditLimit?.used == 27)
        #expect(merged?.codexCreditLimit?.limit == 1000)
    }

    @Test
    func `enrichment failure preserves only the monthly limit when incoming has none`() {
        let now = Date()
        let prior = Self.credits(limitUsed: 27, limit: 1000, remaining: 0, at: now)

        let merged = CodexMonthlyCreditPreservation.merging(
            incoming: nil,
            prior: prior,
            enrichmentFailed: true)

        #expect(merged?.remaining == 0)
        #expect(merged?.events.isEmpty == true)
        #expect(merged?.codexCreditLimit?.used == 27)
        #expect(merged?.codexCreditLimit?.limit == 1000)
        #expect(merged?.updatedAt == prior.codexCreditLimit?.updatedAt)
    }

    @Test
    func `successful absence clears the prior monthly limit`() {
        let now = Date()
        let incoming = CreditsSnapshot(remaining: 0, events: [], updatedAt: now)
        let prior = Self.credits(limitUsed: 27, limit: 1000, remaining: 0, at: now)

        let merged = CodexMonthlyCreditPreservation.merging(
            incoming: incoming,
            prior: prior,
            enrichmentFailed: false)

        #expect(merged?.remaining == 0)
        #expect(merged?.codexCreditLimit == nil)
    }

    @Test
    func `successful absence with no credits snapshot is nil`() {
        let now = Date()
        let prior = Self.credits(limitUsed: 27, limit: 1000, remaining: 0, at: now)

        let merged = CodexMonthlyCreditPreservation.merging(
            incoming: nil,
            prior: prior,
            enrichmentFailed: false)

        #expect(merged == nil)
    }

    @Test
    func `enrichment failure without a monthly cap clears generic credits`() {
        let now = Date()
        let prior = CreditsSnapshot(remaining: 12, events: [], updatedAt: now)

        #expect(
            CodexMonthlyCreditPreservation.standaloneRefreshOutcome(
                incoming: nil,
                prior: prior,
                enrichmentFailed: true) == .published(nil))
        #expect(
            CodexMonthlyCreditPreservation.standaloneRefreshOutcome(
                incoming: nil,
                prior: prior,
                enrichmentFailed: false) == .notFound)
    }

    @Test
    func `standalone credits refresh keeps the monthly cap after enrichment failure`() {
        let now = Date()
        let incoming = CreditsSnapshot(remaining: 9, events: [], updatedAt: now)
        let prior = Self.credits(limitUsed: 27, limit: 1000, remaining: 0, at: now)
        let result = ProviderFetchResult(
            usage: UsageSnapshot(primary: nil, secondary: nil, updatedAt: now),
            credits: incoming,
            dashboard: nil,
            sourceLabel: "api",
            strategyID: "credits-refresh",
            strategyKind: .apiToken,
            codexMonthlyLimitEnrichmentFailed: true)

        let published = CodexMonthlyCreditPreservation.merging(
            incoming: result.credits,
            prior: prior,
            enrichmentFailed: result.codexMonthlyLimitEnrichmentFailed)

        #expect(published?.remaining == 9)
        #expect(published?.codexCreditLimit?.used == 27)
        #expect(published?.codexCreditLimit?.limit == 1000)
    }

    @Test
    func `enrichment failure without a cap publishes nil instead of keeping generic credits`() {
        let generic = CreditsSnapshot(remaining: 12, events: [], updatedAt: Date())
        #expect(
            CodexMonthlyCreditPreservation.shouldPublishSelectedCredits(
                enrichmentFailed: true,
                publishedCredits: nil,
                currentCredits: generic,
                cachedCredits: generic))
        #expect(
            !CodexMonthlyCreditPreservation.shouldPublishSelectedCredits(
                enrichmentFailed: true,
                publishedCredits: nil,
                currentCredits: Self.credits(limitUsed: 27, limit: 1000, remaining: 0, at: Date()),
                cachedCredits: nil))
        #expect(
            CodexMonthlyCreditPreservation.hydrationCredits(
                existingCredits: nil,
                persistedCredits: generic) == generic)
        #expect(
            CodexMonthlyCreditPreservation.hydrationCredits(
                existingCredits: generic,
                persistedCredits: Self.credits(limitUsed: 1, limit: 2, remaining: 0, at: Date())) == nil)
    }

    @Test
    func `incoming monthly limit wins even after enrichment failure`() {
        let now = Date()
        let incoming = Self.credits(limitUsed: 40, limit: 2000, remaining: 1, at: now)
        let prior = Self.credits(limitUsed: 27, limit: 1000, remaining: 0, at: now)

        let merged = CodexMonthlyCreditPreservation.merging(
            incoming: incoming,
            prior: prior,
            enrichmentFailed: true)

        #expect(merged == incoming)
    }

    private static func credits(
        limitUsed: Double,
        limit: Double,
        remaining: Double,
        at date: Date) -> CreditsSnapshot
    {
        CreditsSnapshot(
            remaining: remaining,
            events: [],
            updatedAt: date,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: limitUsed,
                limit: limit,
                remainingPercent: max(0, 100 - (limitUsed / limit * 100)),
                resetsAt: nil,
                updatedAt: date))
    }
}

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `confirmed monthly cap absence publishes nil credits`() async {
        let suite = "CodexMonthlyCreditPreservationTests-publish-nil"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "biz@example.com")
        defer { settings._test_liveSystemCodexAccount = nil }

        let store = self.makeUsageStore(settings: settings)
        let account = CodexVisibleAccount(
            id: "live:biz@example.com",
            email: "biz@example.com",
            workspaceAccountID: nil,
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: false,
            canRemove: false)
        let usage = self.codexSnapshot(email: "biz@example.com", usedPercent: 12)
        let prior = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: Date(),
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 27,
                limit: 1000,
                remainingPercent: 97.3,
                resetsAt: nil,
                updatedAt: Date()))
        store.credits = prior
        store.lastCreditsSnapshot = prior
        store.lastCreditsSnapshotAccountKey = "biz@example.com"
        store.lastCreditsSource = .api
        store.codexAccountSnapshots = [
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: usage,
                error: nil,
                sourceLabel: "api",
                credits: nil),
        ]

        let result = ProviderFetchResult(
            usage: usage,
            credits: nil,
            dashboard: nil,
            sourceLabel: "api",
            strategyID: "stacked-test",
            strategyKind: .apiToken,
            codexMonthlyLimitEnrichmentFailed: false)
        let outcome = ProviderFetchOutcome(
            result: .success(result),
            attempts: [ProviderFetchAttempt(
                strategyID: "stacked-test",
                kind: .apiToken,
                wasAvailable: true,
                errorDescription: nil)])

        await store.applySelectedCodexVisibleAccountOutcome(
            outcome,
            account: account,
            snapshot: usage,
            sourceLabel: "api",
            limitResetOwnerKey: nil)

        #expect(store.credits == nil)
        #expect(store.lastCreditsSnapshot == nil)
        #expect(store.lastCreditsSource == .none)
        #expect(store.lastCreditsSnapshotAccountKey == "biz@example.com")
    }

    @Test
    func `enrichment failure without a cap publishes nil from the selected account path`() async {
        let suite = "CodexMonthlyCreditPreservationTests-publish-nil-generic"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "biz@example.com")
        defer { settings._test_liveSystemCodexAccount = nil }

        let store = self.makeUsageStore(settings: settings)
        let account = CodexVisibleAccount(
            id: "live:biz@example.com",
            email: "biz@example.com",
            workspaceAccountID: nil,
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: false,
            canRemove: false)
        let usage = self.codexSnapshot(email: "biz@example.com", usedPercent: 12)
        let prior = CreditsSnapshot(remaining: 12, events: [], updatedAt: Date())
        store.credits = prior
        store.lastCreditsSnapshot = prior
        store.lastCreditsSnapshotAccountKey = "biz@example.com"
        store.lastCreditsSource = .api
        store.codexAccountSnapshots = [
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: usage,
                error: nil,
                sourceLabel: "api",
                credits: nil),
        ]

        let result = ProviderFetchResult(
            usage: usage,
            credits: nil,
            dashboard: nil,
            sourceLabel: "api",
            strategyID: "stacked-test",
            strategyKind: .apiToken,
            codexMonthlyLimitEnrichmentFailed: true)
        let outcome = ProviderFetchOutcome(
            result: .success(result),
            attempts: [ProviderFetchAttempt(
                strategyID: "stacked-test",
                kind: .apiToken,
                wasAvailable: true,
                errorDescription: nil)])

        await store.applySelectedCodexVisibleAccountOutcome(
            outcome,
            account: account,
            snapshot: usage,
            sourceLabel: "api",
            limitResetOwnerKey: nil)

        #expect(store.credits == nil)
        #expect(store.lastCreditsSnapshot == nil)
        #expect(store.lastCreditsSource == .none)
    }

    @Test
    func `hydration copies persisted monthly credits when selected credits are empty`() {
        let suite = "CodexMonthlyCreditPreservationTests-hydrate-credits"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        let store = self.makeUsageStore(settings: settings)
        let persisted = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: Date(),
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 27,
                limit: 1000,
                remainingPercent: 97.3,
                resetsAt: nil,
                updatedAt: Date()))

        store.publishHydratedCodexCreditsIfNeeded(from: persisted, accountKey: "biz@example.com")
        #expect(store.credits?.codexCreditLimit?.limit == 1000)
        #expect(store.lastCreditsSnapshot?.codexCreditLimit?.used == 27)
        #expect(store.lastCreditsSnapshotAccountKey == "biz@example.com")
        #expect(store.lastCreditsSource == .api)

        let other = CreditsSnapshot(remaining: 4, events: [], updatedAt: Date())
        store.publishHydratedCodexCreditsIfNeeded(from: other, accountKey: "other@example.com")
        #expect(store.credits?.codexCreditLimit?.limit == 1000)
        #expect(store.lastCreditsSnapshotAccountKey == "biz@example.com")
    }
}
