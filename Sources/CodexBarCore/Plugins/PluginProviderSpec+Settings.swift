import Foundation

extension PluginProviderSpec {
    public struct Endpoint: Sendable {
        public enum RequiredValue: Sendable {
            /// Invalid but configured URLs reach fetch validation and report the provider's error.
            case configured
            case validated
        }

        public enum Requirement: Sendable {
            case required(RequiredValue)
            case optional(defaultURL: URL)
        }

        public let environmentKey: String
        public let requirement: Requirement
        public let resolve: @Sendable ([String: String]) -> URL?
        public let field: TextField
        public var action: (id: String, title: String)?

        public func url(environment: [String: String]) -> URL? {
            if case let .optional(defaultURL) = self.requirement,
               SettingsValue.cleaned(environment[self.environmentKey]) == nil
            {
                return defaultURL
            }
            return self.resolve(environment)
        }

        public func isAvailable(environment: [String: String]) -> Bool {
            switch self.requirement {
            case .optional: true
            case .required(.configured): SettingsValue.cleaned(environment[self.environmentKey]) != nil
            case .required(.validated): self.url(environment: environment) != nil
            }
        }
    }

    public struct Toggle: Sendable {
        public let id: String
        public let title: String
        public let subtitle: String
        public let environmentKey: String
        public let value: @Sendable (ProviderConfig) -> Bool?
        public let setValue: @Sendable (inout ProviderConfig, Bool) -> Void
        public var enabledTimeout: TimeInterval?
    }

    private var credentialProjections: [ProviderCredentialEnvironmentProjection] {
        [.apiKey(self.environmentKey)] + self.additionalProjections +
            (self.workspaceField.map { [.workspaceID($0.environmentKey)] } ?? []) +
            (self.endpoint.map { [.enterpriseHost($0.environmentKey)] } ?? []) +
            self.toggles.map { toggle in
                ProviderCredentialEnvironmentProjection(key: toggle.environmentKey, value: {
                    toggle.value($0).map(String.init)
                })
            }
    }

    func makeCredentials() -> ProviderCredentialAdapter? {
        guard !self.environmentKey.isEmpty else { return nil }
        return ProviderCredentialAdapter(
            supportsAPIKeyOverride: true,
            requiresAPIKeyForAPISource: self.alternateCredentialKey == nil,
            apiKeyDebugLabel: self.apiKeyDebugLabel,
            environmentProjections: self.credentialProjections,
            tokenResolver: { kind, environment, _ in
                let value: String? = switch kind {
                case .primary: self.apiKey(environment: environment)
                case .projectID:
                    self.workspaceField.flatMap { field in
                        field.resolvesProjectID ? SettingsValue.cleaned(environment[field.environmentKey]) : nil
                    }
                case .secondary: nil
                }
                return value.map { ProviderTokenResolution(token: $0, source: .environment) }
            },
            tokenAccountSupport: self.tokenAccountSupport,
            authDetector: { environment, _ in
                let alternate = self.alternateCredentialKey.flatMap { SettingsValue.cleaned(environment[$0]) }
                return self.apiKey(environment: environment) == nil && alternate == nil ? [] : ["api"]
            },
            configValidator: { config in
                var issues = self.configValidator(config)
                if let key = self.alternateCredentialKey, config.source == .api, config.sanitizedAPIKey == nil,
                   SettingsValue.cleaned(config.pluginSecrets?[key]) == nil
                {
                    issues.append(CodexBarConfigIssue(
                        severity: .warning,
                        provider: self.id,
                        field: "apiKey",
                        code: "api_key_missing",
                        message: "Source api is selected but apiKey is missing for \(self.id.rawValue)."))
                }
                return issues
            },
            missingCredentialMessage: self.missingCredentialMessage)
    }

    func fetchTimeout(environment: [String: String]) -> TimeInterval {
        self.toggles.first { environment[$0.environmentKey] == "true" && $0.enabledTimeout != nil }?
            .enabledTimeout ?? self.timeout
    }
}
