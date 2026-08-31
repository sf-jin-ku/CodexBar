import Foundation
import Testing
@testable import CodexBarCore

struct CodexExtraUsageCostTests {
    @Test
    func `monthly credit maps to extra usage used versus limit`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let credits = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 36.8,
                limit: 1000,
                remainingPercent: 96.32,
                resetsAt: Date(timeIntervalSince1970: 1_788_220_800),
                updatedAt: now))

        let cost = try #require(CodexExtraUsageCost.providerCost(from: credits))
        #expect(cost.used == 36.8)
        #expect(cost.limit == 1000)
        #expect(cost.currencyCode == CodexExtraUsageCost.currencyCode)
        #expect(cost.period == "Monthly credit limit")
        #expect(cost.balance == nil)
        #expect(cost.resetsAt == Date(timeIntervalSince1970: 1_788_220_800))
    }

    @Test
    func `purchased extra credits are a remaining balance`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let credits = CreditsSnapshot(remaining: 14.5, events: [], updatedAt: now)

        let cost = try #require(CodexExtraUsageCost.providerCost(from: credits))
        #expect(cost.used == 0)
        #expect(cost.limit == 0)
        #expect(cost.balance == 14.5)
        #expect(cost.period == "Extra usage")
    }

    @Test
    func `purchased extra credits sit beside a monthly cap`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let credits = CreditsSnapshot(
            remaining: 50,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 120,
                limit: 400,
                remainingPercent: 70,
                resetsAt: nil,
                updatedAt: now))

        let cost = try #require(CodexExtraUsageCost.providerCost(from: credits))
        #expect(cost.used == 120)
        #expect(cost.limit == 400)
        #expect(cost.balance == 50)
    }

    @Test
    func `monthly remaining is not treated as purchased extra credits`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let credits = CreditsSnapshot(
            remaining: 280,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 120,
                limit: 400,
                remainingPercent: 70,
                resetsAt: nil,
                updatedAt: now))

        let cost = try #require(CodexExtraUsageCost.providerCost(from: credits))
        #expect(cost.balance == nil)
    }

    @Test
    func `zero remaining without a monthly cap is absent`() {
        let credits = CreditsSnapshot(remaining: 0, events: [], updatedAt: Date())
        #expect(CodexExtraUsageCost.providerCost(from: credits) == nil)
        #expect(CodexExtraUsageCost.providerCost(from: nil) == nil)
    }

    @Test
    func `attached monthly cap wins over balance-only live credits`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let live = try #require(CodexExtraUsageCost.providerCost(
            from: CreditsSnapshot(remaining: 14.5, events: [], updatedAt: now)))
        let attached = ProviderCostSnapshot(
            used: 120,
            limit: 400,
            currencyCode: CodexExtraUsageCost.currencyCode,
            period: "Monthly credit limit",
            resetsAt: Date(timeIntervalSince1970: 1_788_220_800),
            updatedAt: now)

        let resolved = try #require(CodexExtraUsageCost.resolving(live: live, attached: attached))
        #expect(resolved.used == 120)
        #expect(resolved.limit == 400)
        #expect(resolved.resetsAt == Date(timeIntervalSince1970: 1_788_220_800))
        #expect(resolved.balance == 14.5)
    }

    @Test
    func `the fresher cap wins when both sides carry one`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let liveCredits = CreditsSnapshot(
            remaining: 50,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 300,
                limit: 400,
                remainingPercent: 25,
                resetsAt: nil,
                updatedAt: now))
        let live = try #require(CodexExtraUsageCost.providerCost(from: liveCredits))
        let attached = ProviderCostSnapshot(
            used: 120,
            limit: 400,
            currencyCode: CodexExtraUsageCost.currencyCode,
            updatedAt: now.addingTimeInterval(-3600))

        let olderAttached = try #require(CodexExtraUsageCost.resolving(live: live, attached: attached))
        #expect(olderAttached.used == 300)

        // A dashboard that refreshed after the retained credits is the authoritative cap.
        let newerAttached = try #require(CodexExtraUsageCost.resolving(
            live: live,
            attached: ProviderCostSnapshot(
                used: 380,
                limit: 400,
                currencyCode: CodexExtraUsageCost.currencyCode,
                updatedAt: now.addingTimeInterval(3600))))
        #expect(newerAttached.used == 380)
        #expect(newerAttached.balance == 50)
    }

    @Test
    func `resolving keeps each side when the other is missing or foreign`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let live = try #require(CodexExtraUsageCost.providerCost(
            from: CreditsSnapshot(remaining: 14.5, events: [], updatedAt: now)))
        let foreign = ProviderCostSnapshot(used: 4, limit: 50, currencyCode: "USD", updatedAt: now)

        #expect(CodexExtraUsageCost.resolving(live: nil, attached: foreign) == foreign)
        #expect(CodexExtraUsageCost.resolving(live: nil, attached: nil) == nil)
        #expect(CodexExtraUsageCost.resolving(live: live, attached: nil) == live)
        // Provider-specific by design: a non-credits cost never supplies the Codex monthly cap.
        #expect(CodexExtraUsageCost.resolving(live: live, attached: foreign) == live)
    }

    @Test
    func `oauth credits-only result attaches extra usage`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": null,
            "secondary_window": null
          },
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": "14.5"
          }
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let result = try CodexOAuthFetchStrategy._mapResultForTesting(Data(json.utf8), credentials: creds)
        #expect(result.credits?.remaining == 14.5)
        #expect(result.usage.providerCost?.balance == 14.5)
        #expect(result.usage.providerCost?.currencyCode == CodexExtraUsageCost.currencyCode)
    }
}
