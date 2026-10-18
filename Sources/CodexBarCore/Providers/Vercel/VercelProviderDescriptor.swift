import Foundation

public enum VercelProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor(fetchPlan: ProviderFetchPlan(
        sourceModes: [.auto, .api, .cli],
        pipeline: ProviderFetchPipeline(resolveStrategies: { context in
            switch context.sourceMode {
            case .cli:
                [VercelCLIFetchStrategy()]
            case .auto where SettingsValue.cleaned(context.env["VERCEL_TEAM_ID"]) != nil:
                [VercelCLIFetchStrategy()]
            case .auto:
                [VercelCLIFetchStrategy(), Self.spec.makeStrategy()]
            case .api:
                [Self.spec.makeStrategy()]
            case .web, .oauth:
                []
            }
        })))
    public static let spec = PluginProviderSpec(
        id: .vercel,
        displayName: "Vercel AI Gateway",
        sessionLabel: "Personal budget",
        weeklyLabel: "Balance",
        toggleTitle: "Show Vercel AI Gateway balance",
        balanceOnly: true,
        dashboardURL: "https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fai-gateway",
        color: .init(hex: 0xFFFFFF),
        confetti: [0xFFFFFF, 0xA3A3A3],
        progressColorStyle: .label,
        noDataMessage: "Vercel AI Gateway cost history is not available.",
        history: .unavailable,
        burnDownWidgetSelectable: false,
        environmentKey: "AI_GATEWAY_API_KEY",
        missingCredentialMessage: { _ in "Set a Vercel AI Gateway API key in Settings or AI_GATEWAY_API_KEY." },
        config: ProviderConfigCapabilities(workspaceIDValidationOrder: 9),
        presentation: ProviderUsagePresentation(menuBarBalanceDetailLabels: ["Available balance"]),
        apiKeyField: .init(
            id: "vercel-api-key",
            title: "Vercel AI Gateway API key",
            subtitle: "Saved in CodexBar's local config file. Or set AI_GATEWAY_API_KEY."),
        workspaceField: .init(
            environmentKey: "VERCEL_TEAM_ID",
            field: .init(
                id: "vercel-team-id",
                title: "Team ID",
                subtitle: "Uses the CLI's current team by default. Refresh to choose another team.",
                placeholder: nil)))
}
