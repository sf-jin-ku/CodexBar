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
                updatedAt: credits.updatedAt)
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
    /// already-known credits, so the live credits can carry only a purchased balance. Keep the cap from
    /// whichever side has one, and the purchased balance from the live side.
    public static func resolving(
        live: ProviderCostSnapshot?,
        attached: ProviderCostSnapshot?) -> ProviderCostSnapshot?
    {
        guard let live else { return attached }
        guard live.limit <= 0,
              let attached,
              attached.currencyCode == Self.currencyCode,
              attached.limit > 0
        else {
            return live
        }
        return attached.replacing(balance: live.balance ?? attached.balance)
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
