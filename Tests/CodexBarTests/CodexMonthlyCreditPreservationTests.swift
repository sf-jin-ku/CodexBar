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
    func `enrichment failure keeps prior credits when incoming has none`() {
        let now = Date()
        let prior = Self.credits(limitUsed: 27, limit: 1000, remaining: 0, at: now)

        let merged = CodexMonthlyCreditPreservation.merging(
            incoming: nil,
            prior: prior,
            enrichmentFailed: true)

        #expect(merged == prior)
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
