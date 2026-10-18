import CodexBarCore
import Foundation
import SwiftUI

struct VercelProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .vercel
    var loadTeams: @Sendable ([String: String]) async throws -> [VercelCLITeam] = {
        try await VercelCLIUsageFetcher().teams(environment: $0)
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        PluginAPIKeyProviderImplementation(spec: VercelProviderDescriptor.spec).observeSettings(settings)
        _ = settings.providerConfig(for: .vercel)?.source
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        context.settings.providerConfig(for: .vercel)?.source ?? .auto
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        PluginAPIKeyProviderImplementation(spec: VercelProviderDescriptor.spec).settingsFields(context: context)
            .filter { $0.id != "vercel-team-id" }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let refresh: (String) async -> Void = { _ in
            await context.store.refreshProvider(.vercel, allowDisabled: true)
        }
        let source = Binding(
            get: { (context.settings.providerConfig(for: .vercel)?.source ?? .auto).rawValue },
            set: { value in
                guard let mode = ProviderSourceMode(rawValue: value), [.auto, .api, .cli].contains(mode) else { return }
                guard (context.settings.providerConfig(for: .vercel)?.source ?? .auto) != mode else { return }
                context.settings.updateProviderConfig(provider: .vercel) { $0.source = mode == .auto ? nil : mode }
                context.store.clearProviderState(.vercel)
            })
        let team = Binding(
            get: { context.settings[providerConfig: .vercel, field: .workspace] },
            set: { value in
                guard context.settings[providerConfig: .vercel, field: .workspace] != value else { return }
                context.settings[providerConfig: .vercel, field: .workspace] = value
                context.store.clearProviderState(.vercel)
            })
        var options = [ProviderSettingsPickerOption(id: "", title: "Auto")]
            + context.store.vercelTeams.map {
                ProviderSettingsPickerOption(id: $0.id, title: "\($0.name) (\($0.slug))")
            }
        if !team.wrappedValue.isEmpty, !options.contains(where: { $0.id == team.wrappedValue }) {
            options.append(ProviderSettingsPickerOption(id: team.wrappedValue, title: team.wrappedValue))
        }
        return [
            ProviderSettingsPickerDescriptor(
                id: "vercel-source",
                title: "Usage source",
                subtitle: "",
                binding: source,
                options: [
                    .init(id: "auto", title: "Auto"),
                    .init(id: "cli", title: "Vercel CLI"),
                    .init(id: "api", title: "API key"),
                ],
                isVisible: nil,
                onChange: refresh),
            ProviderSettingsPickerDescriptor(
                id: "vercel-team",
                title: "Team",
                subtitle: "Uses the CLI's current team by default. Refresh to choose another team.",
                binding: team,
                options: options,
                isVisible: { source.wrappedValue != "api" },
                isEnabled: { !context.store.vercelTeamsRefreshing },
                onChange: refresh,
                trailingText: { context.statusText("vercel-teams") },
                trailingActions: [.init(
                    id: "vercel-refresh-teams",
                    title: "Refresh",
                    style: .bordered,
                    isVisible: nil,
                    perform: { await self.refreshTeams(context: context) })]),
        ]
    }

    @MainActor
    private func refreshTeams(context: ProviderSettingsContext) async {
        guard !context.store.vercelTeamsRefreshing else { return }
        context.store.vercelTeamsRefreshing = true
        defer { context.store.vercelTeamsRefreshing = false }
        context.setStatusText("vercel-teams", L("Refreshing"))
        let revision = context.settings.providerConfigRevision(for: .vercel)
        do {
            let teams = try await self.loadTeams(context.store.environmentBase)
            guard !Task.isCancelled, context.settings.providerConfigRevision(for: .vercel) == revision else {
                context.setStatusText("vercel-teams", nil)
                return
            }
            context.store.vercelTeams = teams
            context.setStatusText("vercel-teams", nil)
        } catch {
            context.setStatusText(
                "vercel-teams",
                Task.isCancelled ||
                    context.settings.providerConfigRevision(for: .vercel) != revision ? nil : error
                    .localizedDescription)
        }
    }
}
