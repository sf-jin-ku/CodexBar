import Foundation

public struct CodexSpendControlsMonthlyUsageResponse: Decodable, Sendable {
    private static let inactiveEnforcementModes: Set<String> = ["none", "off", "disabled", "no_limit"]

    public let currentMonthUsage: Double?
    public let effectiveMonthlyLimit: EffectiveMonthlyLimit?
    private let currentMonthUsageWasUnmappable: Bool

    enum CodingKeys: String, CodingKey {
        case currentMonthUsage = "current_month_usage"
        case effectiveMonthlyLimit = "effective_monthly_limit"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedUsage = Self.decodeFlexibleDoubleResult(container, forKey: .currentMonthUsage)
        self.currentMonthUsage = decodedUsage.value
        self.currentMonthUsageWasUnmappable = decodedUsage.unmappable
        self.effectiveMonthlyLimit = try container.decodeIfPresent(
            EffectiveMonthlyLimit.self,
            forKey: .effectiveMonthlyLimit)
    }

    public var monthlyLimitMappingFailed: Bool {
        if self.hasInactiveEnforcement { return false }
        if self.effectiveMonthlyLimit?.limitWasUnmappable == true { return true }
        guard self.effectiveMonthlyLimit?.limit ?? 0 > 0 else { return false }
        return self.currentMonthUsageWasUnmappable
    }

    private var hasInactiveEnforcement: Bool {
        guard let mode = self.effectiveMonthlyLimit?.enforcementMode?.lowercased() else { return false }
        return Self.inactiveEnforcementModes.contains(mode)
    }

    public func codexCreditLimitSnapshot(updatedAt: Date) -> CodexCreditLimitSnapshot? {
        guard let limit = self.effectiveMonthlyLimit?.limit, limit > 0 else { return nil }
        if self.hasInactiveEnforcement {
            return nil
        }

        let used = max(0, self.currentMonthUsage ?? 0)
        let remainingPercent = max(0, min(100, 100 - (used / limit * 100)))
        return CodexCreditLimitSnapshot(
            used: used,
            limit: limit,
            remainingPercent: remainingPercent,
            resetsAt: nil,
            updatedAt: updatedAt)
    }

    public struct EffectiveMonthlyLimit: Decodable, Sendable {
        public let limit: Double?
        public let limitWasUnmappable: Bool
        public let enforcementMode: String?
        public let limitMode: String?

        enum CodingKeys: String, CodingKey {
            case limit
            case enforcementMode = "enforcement_mode"
            case limitMode = "limit_mode"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedLimit = CodexSpendControlsMonthlyUsageResponse.decodeFlexibleDoubleResult(
                container,
                forKey: .limit)
            self.limit = decodedLimit.value
            self.limitWasUnmappable = decodedLimit.unmappable
            self.enforcementMode = try? container.decodeIfPresent(String.self, forKey: .enforcementMode)
            self.limitMode = try? container.decodeIfPresent(String.self, forKey: .limitMode)
        }
    }

    private static func decodeFlexibleDouble<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key) -> Double?
    {
        self.decodeFlexibleDoubleResult(container, forKey: key).value
    }

    fileprivate static func decodeFlexibleDoubleResult<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key) -> (value: Double?, unmappable: Bool)
    {
        guard container.contains(key) else { return (nil, false) }
        if (try? container.decodeNil(forKey: key)) == true {
            return (nil, false)
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return (value, false)
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return (Double(value), false)
        }
        if let value = try? container.decode(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = Double(trimmed) {
                return (parsed, false)
            }
            return (nil, true)
        }
        return (nil, true)
    }
}

enum CodexSpendControlsMonthlyUsageGate {
    static func shouldFetch(response: CodexUsageResponse) -> Bool {
        guard response.resolvedIndividualLimit?.codexCreditLimitSnapshot(updatedAt: Date()) == nil,
              response.spendControlPresent
        else { return false }

        return switch response.planType {
        case .team, .business, .education, .quorum, .k12, .enterprise, .edu, .freeWorkspace:
            true
        case .guest, .free, .go, .plus, .pro, .unknown, nil:
            false
        }
    }
}
