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
