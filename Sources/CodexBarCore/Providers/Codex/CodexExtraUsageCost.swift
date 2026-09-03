import Foundation

/// Maps Codex extra credits onto the shared Extra usage cost snapshot.
///
/// Team/Business monthly caps expose used vs limit. Purchased extra credits that sit
/// beside that cap are the remaining balance, matching Claude extra usage + prepaid
/// balance and Cursor on-demand used vs limit.
public enum CodexExtraUsageCost {
    public static let currencyCode = "Credits"

    public static func providerCost(from credits: CreditsSnapshot?) -> ProviderCostSnapshot? {
        guard let credits else { return nil }
        let extraBalance = self.purchasedExtraCreditsBalance(from: credits)
        if let limit = credits.codexCreditLimit, limit.limit > 0 {
            return ProviderCostSnapshot(
                used: limit.used,
                limit: limit.limit,
                currencyCode: Self.currencyCode,
                period: limit.title,
                resetsAt: limit.resetsAt,
                balance: extraBalance,
                // The cap ages on its own: a preserved limit rides along with a newer balance fetch,
                // so stamping it with `credits.updatedAt` would overstate how fresh the cap is.
                updatedAt: limit.updatedAt)
        }
        guard let extraBalance else { return nil }
        return ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: Self.currencyCode,
            period: "Extra usage",
            balance: extraBalance,
            updatedAt: credits.updatedAt)
    }

    public static func attaching(to snapshot: UsageSnapshot, credits: CreditsSnapshot?) -> UsageSnapshot {
        guard let cost = self.providerCost(from: credits) else { return snapshot }
        return snapshot.with(providerCost: cost)
    }

    /// An authorized dashboard attaches its monthly cap to the paired usage snapshot without overwriting
    /// already-known credits, so either side can hold the cap and either side can be the stale one.
    /// Take the fresher cap and the fresher purchased balance. Live credits are the whole snapshot rather
    /// than its cost because the two age apart there: a preserved cap is older than the fetch carrying it.
    public static func resolving(
        liveCredits: CreditsSnapshot?,
        attached: ProviderCostSnapshot?) -> ProviderCostSnapshot?
    {
        let live = liveCredits.flatMap { self.providerCost(from: $0) }
        guard let liveCredits else { return attached }
        // Provider-specific by design: only a Codex credits cost may supply the Codex monthly cap.
        guard let attached,
              attached.currencyCode == Self.currencyCode,
              attached.limit > 0
        else {
            return live
        }
        // A successful live balance reading, including remaining == 0, is a confirmed value and must
        // not keep an older attached purchased-credit balance. A failed credits fetch is encoded as
        // `balanceReadSucceeded == false` so the other side can still supply it.
        let liveBalance = self.purchasedExtraCreditsBalance(from: liveCredits)
        let balance: Double?
        if liveCredits.updatedAt >= attached.updatedAt {
            if liveCredits.balanceReadSucceeded {
                balance = liveBalance
            } else {
                balance = liveBalance ?? attached.balance
            }
        } else {
            balance = attached.balance ?? liveBalance
        }
        if let live, live.limit > 0, live.updatedAt >= attached.updatedAt {
            return live.replacing(balance: balance)
        }
        return attached.replacing(balance: balance)
    }

    /// Purchased extra credits that are distinct from the monthly included/assigned cap.
    public static func purchasedExtraCreditsBalance(from credits: CreditsSnapshot) -> Double? {
        if let monthly = credits.codexCreditLimit {
            guard abs(credits.remaining - monthly.remaining) > 0.000_1, credits.remaining > 0 else {
                return nil
            }
            return credits.remaining
        }
        return credits.remaining > 0 ? credits.remaining : nil
    }
}
