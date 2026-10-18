import Foundation
import Testing
@testable import CodexBarCore

struct VercelCLIUsageTests {
    static let now = Date(timeIntervalSince1970: 1_792_339_200)
    static let user = #"{"user":{"id":"user_fixture","email":"fixture@example.com"}}"#

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
        now: Date = Self.now) async throws -> UsageSnapshot
    {
        let fetcher = VercelCLIUsageFetcher(run: { arguments, environment in
            #expect(arguments[3] == "--non-interactive")
            #expect(Array(arguments.suffix(2)) == ["--scope", "team_fixture"])
            #expect(arguments.prefix(1) == ["api"])
            #expect(arguments[2] == "--raw")
            #expect(environment["CI"] == "1")
            #expect(environment["VERCEL_TELEMETRY_DISABLED"] == "1")
            #expect(environment["AI_GATEWAY_API_KEY"] == nil)
            #expect(environment["OTHER_SECRET"] == nil)
            #expect(environment["CURSOR_TRACE_ID"] == nil)
            #expect(environment["VERCEL_TOKEN"] == nil)
            switch arguments[1] {
            case "/v2/user": return user
            case "/ai-gateway/budgets/list?teamId=team_fixture&scopeType=user":
                return "{\"budgets\":[\(budgets.joined(separator: ","))]}"
            default:
                Issue.record("Unexpected endpoint")
                return "{}"
            }
        })
        return try await fetcher.fetch(environment: [
            "VERCEL_TEAM_ID": "team_fixture", "AI_GATEWAY_API_KEY": "fixture-key",
            "OTHER_SECRET": "private-response", "CURSOR_TRACE_ID": "fixture-agent", "VERCEL_TOKEN": "fixture-token",
        ], now: now)
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
    func `team scope is required before running any command`() async throws {
        let fetcher = VercelCLIUsageFetcher(run: { _, _ in
            Issue.record("Invalid team must not launch the CLI")
            return "{}"
        })
        for team in ["", "my-team", "team_fixture&scopeType=team", "team_fixture\nother"] {
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
    func `invalid users and incomplete responses fail closed`() async throws {
        for (user, response) in [
            ("{}", "{\"budgets\":[]}"),
            (#"{"user":{"id":""}}"#, "{\"budgets\":[]}"),
            (Self.user, "private-response"),
            (Self.user, #"{"budgets":[],"nextCursor":"more"}"#),
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
    func `personal budgets are opt in and API key balances retain their source`() async {
        let pipeline = VercelProviderDescriptor.descriptor.fetchPlan.pipeline
        let api = await pipeline.resolveStrategies(ProviderCutoverTestSupport.context(
            environment: ["AI_GATEWAY_API_KEY": "fixture-key"]))
        #expect(api.map(\.id) == ["vercel.js"])
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
    }
}
