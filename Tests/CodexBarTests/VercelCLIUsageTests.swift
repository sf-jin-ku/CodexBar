import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct VercelCLIUsageTests {
    static let now = Date(timeIntervalSince1970: 1_792_339_200)
    static let user = #"{"user":{"id":"user_fixture","email":"fixture@example.com"}}"#
    static let teamsJSON = #"""
    [{"id":"team_other","slug":"other","name":"Other","current":false},
    {"id":"team_fixture","slug":"fixture","name":"Fixture","current":true}]
    """#

    static func budget(
        user: String = "user_fixture",
        spend: String = "12.4",
        limit: String = "100",
        period: String = "monthly",
        source: String? = nil) -> String
    {
        """
        {"scopeType":"user","scopeId":"\(user)","currentSpend":\(spend),"limitAmount":\(limit),
        "refreshPeriod":"\(period)","active":true,"archived":false\(source.map { ",\"source\":\"\($0)\"" } ?? "")}
        """
    }

    static func fetch(
        _ budgets: [String],
        user: String = Self.user,
        now: Date = Self.now,
        teamID: String? = "team_fixture") async throws -> UsageSnapshot
    {
        let expectedTeam = teamID ?? "team_fixture"
        let fetcher = VercelCLIUsageFetcher(run: { arguments, environment in
            #expect(environment["CI"] == "1")
            #expect(environment["VERCEL_TELEMETRY_DISABLED"] == "1")
            #expect(environment["AI_GATEWAY_API_KEY"] == nil)
            #expect(environment["OTHER_SECRET"] == nil)
            #expect(environment["CURSOR_TRACE_ID"] == nil)
            #expect(environment["VERCEL_TOKEN"] == nil)
            if arguments.first == "teams" {
                #expect(teamID == nil)
                #expect(arguments == ["teams", "list", "--format", "json", "--non-interactive"])
                return "{\"teams\":\(Self.teamsJSON),\"pagination\":{\"next\":null}}"
            }
            #expect(arguments[3] == "--non-interactive")
            #expect(Array(arguments.suffix(2)) == ["--scope", expectedTeam])
            #expect(arguments.prefix(1) == ["api"])
            #expect(arguments[2] == "--raw")
            switch arguments[1] {
            case "/v2/user": return user
            case "/ai-gateway/budgets/list?teamId=\(expectedTeam)&scopeType=user":
                return "{\"budgets\":[\(budgets.joined(separator: ","))]}"
            default:
                Issue.record("Unexpected endpoint")
                return "{}"
            }
        })
        var environment = [
            "AI_GATEWAY_API_KEY": "fixture-key",
            "OTHER_SECRET": "private-response", "CURSOR_TRACE_ID": "fixture-agent", "VERCEL_TOKEN": "fixture-token",
        ]
        environment["VERCEL_TEAM_ID"] = teamID
        return try await fetcher.fetch(environment: environment, now: now)
    }

    @Test
    func `blank team uses the CLI current selection and explicit overrides skip discovery`() async throws {
        let automatic = try await Self.fetch([Self.budget()], teamID: nil)
        #expect(automatic.identity?.accountOrganization == "team_fixture")
        #expect(automatic.primary?.usedPercent == 12.4)
        let override = try await Self.fetch([Self.budget()], teamID: "team_override")
        #expect(override.identity?.accountOrganization == "team_override")
    }

    @Test
    func `team discovery follows every page without switching the CLI team`() async throws {
        let fetcher = VercelCLIUsageFetcher(run: { arguments, _ in
            #expect(arguments.prefix(2) == ["teams", "list"])
            #expect(!arguments.contains("switch"))
            #expect(!arguments.contains("--scope"))
            if arguments.contains("--next") {
                #expect(arguments.suffix(2) == ["--next", "10"])
                return #"""
                {"teams":[{"id":"team_beta","slug":"beta","name":"Beta","current":true}],
                "pagination":{"next":null}}
                """#
            }
            return #"""
            {"teams":[{"id":"team_alpha","slug":"alpha","name":"Alpha","current":false}],
            "pagination":{"next":10}}
            """#
        })
        let teams = try await fetcher.teams(environment: [:])
        #expect(teams.map(\.id) == ["team_alpha", "team_beta"])
        #expect(teams.first(where: \.current)?.id == "team_beta")
    }

    @Test
    func `missing current teams are not replaced by the first membership`() async throws {
        let fetcher = VercelCLIUsageFetcher(run: { arguments, _ in
            #expect(arguments.first == "teams")
            return "{\"teams\":\(Self.teamsJSON.replacingOccurrences(of: "true", with: "false"))}"
        })
        do {
            _ = try await fetcher.fetch(environment: [:])
            Issue.record("Expected a team selection request")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .missingCredential)
        }
    }

    @Test
    func `malformed or incomplete team discovery fails instead of returning a partial list`() async throws {
        for body in [
            "private-response", "{}", #"{"teams":[],"pagination":{"next":10}}"#,
            "{\"teams\":\(Self.teamsJSON.replacingOccurrences(of: "false", with: "true"))}",
        ] {
            let fetcher = VercelCLIUsageFetcher(run: { _, _ in body })
            do {
                _ = try await fetcher.teams(environment: [:])
                Issue.record("Expected invalid team response")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .parseFailure)
                #expect(!error.message.contains("private-response"))
            }
        }
    }

    @Test
    func `CLI budgets belong to the logged in user within the explicitly selected team`() async throws {
        let snapshot = try await Self.fetch([Self.budget(user: "other_user", spend: "99"), Self.budget()])
        #expect(snapshot.primary?.usedPercent == 12.4)
        #expect(snapshot.primary?.resetDescription == "$12.40 / $100.00")
        #expect(snapshot.primary?.windowMinutes == 31 * 24 * 60)
        #expect(snapshot.primary?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        #expect(snapshot.identity?.accountID == "user_fixture")
        #expect(snapshot.identity?.accountEmail == "fixture@example.com")
        #expect(snapshot.identity?.accountOrganization == "team_fixture")
        #expect(snapshot.identity?.providerID == .vercel)
        #expect(snapshot.identity?.loginMethod == "CLI")
        #expect(snapshot.secondary == nil)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.details.first?.rows.map(\.value) == ["$12.40", "$100.00", "$87.60", "monthly"])
    }

    @Test
    func `custom user budgets override inherited defaults`() async throws {
        let inherited = Self.budget(spend: "20", limit: "50", source: "default")
        let custom = Self.budget(spend: "30", limit: "200")
        #expect(try await Self.fetch([inherited]).primary?.usedPercent == 40)
        #expect(try await Self.fetch([inherited, custom]).primary?.usedPercent == 15)
    }

    @Test
    func `unpaged requests select the user custom budget at the end of a large flat list`() async throws {
        let others = (0..<250).map { Self.budget(user: "other_user_\($0)", spend: "99") }
        let inherited = Self.budget(spend: "20", limit: "50", source: "default")
        let custom = Self.budget(spend: "30", limit: "200")
        let snapshot = try await Self.fetch([inherited] + others + [custom])
        #expect(snapshot.primary?.usedPercent == 15)
        #expect(snapshot.identity?.accountID == "user_fixture")
    }

    @Test
    func `unlimited users never borrow another member budget or invent zero spend`() async throws {
        for budgets in [
            [],
            [Self.budget(user: "other_user")],
            [Self.budget().replacingOccurrences(of: "\"active\":true", with: "\"active\":false")],
            [Self.budget().replacingOccurrences(of: "\"archived\":false", with: "\"archived\":true")],
        ] {
            let snapshot = try await Self.fetch(budgets)
            #expect(snapshot.primary == nil)
            #expect(snapshot.details.first?.rows.first?.value == "No personal budget configured")
        }
    }

    @Test
    func `UTC refresh periods handle week month and year boundaries`() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-12-31T23:59:00Z"))
        for (period, end, minutes) in [
            ("daily", "2027-01-01T00:00:00Z", 1440),
            ("weekly", "2027-01-04T00:00:00Z", 10080),
            ("monthly", "2027-01-01T00:00:00Z", 44640),
            ("none", "", 0),
        ] {
            let window = try #require(try await Self.fetch([Self.budget(period: period)], now: now).primary)
            #expect(window.resetsAt == ISO8601DateFormatter().date(from: end))
            #expect(window.windowMinutes == (minutes == 0 ? nil : minutes))
        }
    }

    @Test
    func `zero usage and budget overages are preserved`() async throws {
        #expect(try await Self.fetch([Self.budget(spend: "0")]).primary?.usedPercent == 0)
        let over = try await Self.fetch([Self.budget(spend: "125")])
        #expect(over.primary?.usedPercent == 125)
        #expect(over.details.first?.rows[2].value == "$0.00")
    }

    @Test
    func `malformed and ambiguous budgets fail without echoing account data`() async throws {
        for budgets in [
            ["{}"], [Self.budget(spend: "-1")], [Self.budget(limit: "0")],
            [Self.budget(limit: "-1")], [Self.budget(spend: "true")],
            [Self.budget(period: "private-response")], [Self.budget(), Self.budget()],
        ] {
            do {
                _ = try await Self.fetch(budgets)
                Issue.record("Expected invalid budget")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .parseFailure)
                #expect(!error.message.contains("private-response"))
            }
        }
    }

    @Test
    func `invalid explicit team scopes are rejected before running a command`() async throws {
        let fetcher = VercelCLIUsageFetcher(run: { _, _ in
            Issue.record("Invalid team must not launch the CLI")
            return "{}"
        })
        for team in ["my-team", "team_fixture&scopeType=team", "team_fixture\nother"] {
            let environment = ["VERCEL_TEAM_ID": team]
            await #expect(throws: ProviderFetchClassifiedError.self) {
                try await fetcher.fetch(environment: environment)
            }
        }
    }

    @Test
    func `CLI failures hide stderr and cancellation propagates`() async throws {
        let fetcher = VercelCLIUsageFetcher(run: { _, _ in
            throw SubprocessRunnerError.nonZeroExit(code: 1, stderr: "private-response")
        })
        do {
            _ = try await fetcher.fetch(environment: ["VERCEL_TEAM_ID": "team_fixture"])
            Issue.record("Expected CLI failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .apiFailure)
            #expect(!error.message.contains("private-response"))
        }
        let cancelled = VercelCLIUsageFetcher(run: { _, _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) {
            try await cancelled.fetch(environment: ["VERCEL_TEAM_ID": "team_fixture"])
        }
    }

    @Test
    func `personal CLI configuration does not require an API key or warn about its team ID`() {
        let config = CodexBarConfig(providers: [ProviderConfig(
            id: .vercel, source: .cli, workspaceID: "team_fixture")])
        #expect(CodexBarConfigValidator.validate(config).filter { $0.provider == .vercel }.isEmpty)
    }

    @Test
    func `invalid users and malformed responses fail closed`() async throws {
        for (user, response) in [
            ("{}", "{\"budgets\":[]}"),
            (#"{"user":{"id":""}}"#, "{\"budgets\":[]}"),
            (Self.user, "private-response"),
        ] {
            let fetcher = VercelCLIUsageFetcher(run: { arguments, _ in
                arguments[1] == "/v2/user" ? user : response
            })
            do {
                _ = try await fetcher.fetch(environment: ["VERCEL_TEAM_ID": "team_fixture"])
                Issue.record("Expected invalid output")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .parseFailure)
                #expect(!error.message.contains("private-response"))
            }
        }
    }

    @Test
    func `automatic mode discovers CLI teams while explicit sources retain their scope`() async {
        let pipeline = VercelProviderDescriptor.descriptor.fetchPlan.pipeline
        let api = await pipeline.resolveStrategies(ProviderCutoverTestSupport.context(
            environment: ["AI_GATEWAY_API_KEY": "fixture-key"]))
        #expect(api.map(\.id) == ["vercel.cli", "vercel.js"])
        let cli = await pipeline.resolveStrategies(ProviderCutoverTestSupport.context(
            environment: ["AI_GATEWAY_API_KEY": "fixture-key", "VERCEL_TEAM_ID": "team_fixture"]))
        #expect(cli.map(\.id) == ["vercel.cli"])
        let explicitAPI = await pipeline.resolveStrategies(ProviderCutoverTestSupport.context(
            environment: ["VERCEL_TEAM_ID": "team_fixture"], sourceMode: .api))
        #expect(explicitAPI.map(\.id) == ["vercel.js"])
        let explicitCLI = await pipeline.resolveStrategies(ProviderCutoverTestSupport.context(sourceMode: .cli))
        #expect(explicitCLI.map(\.id) == ["vercel.cli"])
        #expect(!VercelCLIFetchStrategy().shouldFallback(
            on: CancellationError(), context: ProviderCutoverTestSupport.context()))
        let failure = ProviderFetchClassifiedError(kind: .apiFailure, message: "fixture")
        #expect(VercelCLIFetchStrategy().shouldFallback(
            on: failure, context: ProviderCutoverTestSupport.context()))
        #expect(!VercelCLIFetchStrategy().shouldFallback(
            on: failure, context: ProviderCutoverTestSupport.context(environment: ["VERCEL_TEAM_ID": "team_fixture"])))
        #expect(!VercelCLIFetchStrategy().shouldFallback(
            on: failure, context: ProviderCutoverTestSupport.context(sourceMode: .cli)))
    }
}

@MainActor
struct VercelTeamSettingsTests {
    static func teams() throws -> [VercelCLITeam] {
        try JSONDecoder().decode([VercelCLITeam].self, from: Data(VercelCLIUsageTests.teamsJSON.utf8))
    }

    @Test
    func `teams load from CLI and selection stays in CodexBar configuration`() async throws {
        let teams = try Self.teams()
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "VercelTeamSettingsTests")
        let implementation = VercelProviderImplementation(loadTeams: { _ in teams })
        let context = fixture.settingsContext(provider: .vercel)
        let initial = try #require(implementation.settingsPickers(context: context).first { $0.id == "vercel-team" })
        #expect(initial.binding.wrappedValue.isEmpty)
        #expect(initial.options.map(\.id) == [""])
        let refresh = try #require(initial.trailingActions.first)
        await refresh.perform()
        let picker = try #require(implementation.settingsPickers(context: context).first { $0.id == "vercel-team" })
        #expect(picker.options.map(\.id) == ["", "team_other", "team_fixture"])
        picker.binding.wrappedValue = "team_other"
        #expect(fixture.settings.providerConfig(for: .vercel)?.workspaceID == "team_other")
        #expect(fixture.store.vercelTeams.first(where: \.current)?.id == "team_fixture")
        picker.binding.wrappedValue = ""
        #expect(fixture.settings.providerConfig(for: .vercel)?.workspaceID == nil)
        #expect(implementation.settingsFields(context: context).map(\.kind) == [.secure])
    }

    @Test
    func `switching teams retires the previous usage publication and clears its snapshot`() async throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "VercelTeamSwitchTests")
        let context = fixture.settingsContext(provider: .vercel)
        let implementation = VercelProviderImplementation()
        let picker = try #require(implementation.settingsPickers(context: context).first { $0.id == "vercel-team" })
        fixture.store.snapshots[.vercel] = try await VercelCLIUsageTests.fetch([VercelCLIUsageTests.budget()])
        let publication = fixture.store.providerPublicationRevision(for: .vercel)
        let revision = fixture.settings.providerConfigRevision(for: .vercel)
        picker.binding.wrappedValue = ""
        #expect(fixture.store.snapshots[.vercel] != nil)
        #expect(fixture.store.providerPublicationRevisionIsCurrent(publication, for: .vercel))
        picker.binding.wrappedValue = "team_other"
        #expect(fixture.store.snapshots[.vercel] == nil)
        #expect(fixture.settings.providerConfigRevision(for: .vercel) > revision)
        #expect(!fixture.store.providerPublicationRevisionIsCurrent(publication, for: .vercel))
    }

    @Test(arguments: [false, true])
    func `team discovery finishing after a selection change cannot replace the new inventory`(
        failure: Bool) async throws
    {
        let teams = try Self.teams()
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "VercelTeamDiscoveryRace")
        let started = AsyncStream<Void>.makeStream()
        let finish = AsyncStream<Void>.makeStream()
        let implementation = VercelProviderImplementation(loadTeams: { _ in
            started.continuation.yield(())
            for await _ in finish.stream {
                if failure { throw ProviderFetchClassifiedError(kind: .apiFailure, message: "fixture") }
                return teams
            }
            throw CancellationError()
        })
        let context = fixture.settingsContext(provider: .vercel)
        let picker = try #require(implementation.settingsPickers(context: context).first { $0.id == "vercel-team" })
        let action = try #require(picker.trailingActions.first)
        let request = Task { await action.perform() }
        defer {
            started.continuation.finish()
            finish.continuation.finish()
            request.cancel()
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        picker.binding.wrappedValue = "team_other"
        fixture.store.vercelTeams = [teams[0]]
        finish.continuation.yield(())
        await request.value
        #expect(fixture.store.vercelTeams == [teams[0]])
        #expect(!fixture.store.vercelTeamsRefreshing)
        #expect(context.statusText("vercel-teams") == nil)
    }

    @Test
    func `API source is selectable without changing the stored team`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "VercelSourceSettingsTests")
        fixture.settings[providerConfig: .vercel, field: .workspace] = "team_fixture"
        let context = fixture.settingsContext(provider: .vercel)
        let implementation = VercelProviderImplementation()
        let pickers = implementation.settingsPickers(context: context)
        let source = try #require(pickers.first { $0.id == "vercel-source" })
        #expect(source.options.map(\.id) == ["auto", "cli", "api"])
        source.binding.wrappedValue = "api"
        #expect(implementation.sourceMode(context: .init(provider: .vercel, settings: fixture.settings)) == .api)
        #expect(fixture.settings.providerConfig(for: .vercel)?.workspaceID == "team_fixture")
        #expect(pickers.first { $0.id == "vercel-team" }?.isVisible?() == false)
    }
}
