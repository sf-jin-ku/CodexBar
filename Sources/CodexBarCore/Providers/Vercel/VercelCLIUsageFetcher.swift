import Foundation

public struct VercelCLIUsageFetcher: Sendable {
    var run: @Sendable ([String], [String: String], TimeInterval) async throws -> String = Self.runCommand
    var clockNow: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }

    public init() {}

    init(
        run: @escaping @Sendable ([String], [String: String], TimeInterval) async throws -> String,
        clockNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now })
    {
        self.run = run
        self.clockNow = clockNow
    }

    func fetch(environment: [String: String], now: Date = Date()) async throws -> UsageSnapshot {
        let deadline = self.clockNow().advanced(by: .seconds(30))
        let teamID: String
        if let configured = SettingsValue.cleaned(environment["VERCEL_TEAM_ID"]) {
            guard Self.isTeamID(configured) else { throw Self.invalidOutput }
            teamID = configured
        } else if let current = try await self.teams(environment: environment, deadline: deadline)
            .first(where: \.current)
        {
            teamID = current.id
        } else {
            throw ProviderFetchClassifiedError(
                kind: .missingCredential,
                message: "Select a Vercel team in CodexBar or run 'vercel teams switch' to choose your CLI team.")
        }
        let user: UserResponse = try await self.read(
            "/v2/user", teamID: teamID, environment: environment, deadline: deadline)
        guard !user.user.id.isEmpty else { throw Self.invalidOutput }
        var matches: [Budget] = []
        var cursor: String?
        var cursors: Set<String> = []
        for pageIndex in 0..<100 {
            var endpoint = "/ai-gateway/budgets/list?teamId=\(teamID)&scopeType=user&limit=200"
            if let cursor {
                guard let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
                    throw Self.invalidOutput
                }
                endpoint += "&cursor=\(encoded)"
            }
            let page: BudgetResponse = try await self.read(
                endpoint, teamID: teamID, environment: environment, deadline: deadline)
            matches += page.budgets.filter {
                $0.scopeType == "user" && $0.scopeId == user.user.id && $0.active && !$0.archived
            }
            guard let next = page.nextCursor else { break }
            guard !next.isEmpty, cursors.insert(next).inserted, pageIndex < 99 else { throw Self.invalidOutput }
            cursor = next
        }
        let custom = matches.filter { $0.source != "default" }
        let effective = custom.isEmpty ? matches : custom
        guard effective.count <= 1 else { throw Self.invalidOutput }
        let identity = ProviderIdentitySnapshot(
            providerID: .vercel,
            accountEmail: user.user.email,
            accountOrganization: teamID,
            loginMethod: "CLI",
            accountID: user.user.id)
        guard let budget = effective.first else {
            return try UsageSnapshot(
                primary: nil,
                secondary: nil,
                details: [ProviderDetailSection(title: "Personal budget", rows: [
                    .makeRow(label: "Budget", value: "No personal budget configured"),
                ])],
                updatedAt: now,
                identity: identity,
                dataConfidence: .exact)
        }
        guard budget.limitAmount.isFinite, budget.limitAmount > 0,
              budget.currentSpend.isFinite, budget.currentSpend >= 0
        else { throw Self.invalidOutput }
        let percent = budget.currentSpend / budget.limitAmount * 100
        guard percent.isFinite else { throw Self.invalidOutput }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let interval = budget.refreshPeriod.component.flatMap { calendar.dateInterval(of: $0, for: now) }
        let spent = UsageFormatter.usdString(budget.currentSpend)
        let limit = UsageFormatter.usdString(budget.limitAmount)
        let window = RateWindow(
            usedPercent: percent,
            windowMinutes: interval.map { Int($0.duration / 60) },
            resetsAt: interval?.end,
            resetDescription: "\(spent) / \(limit)")
        return try UsageSnapshot(
            primary: window,
            secondary: nil,
            details: [ProviderDetailSection(title: "Personal budget", rows: [
                .makeRow(label: "Spent", value: spent),
                .makeRow(label: "Limit", value: limit),
                .makeRow(
                    label: "Remaining",
                    value: UsageFormatter.usdString(max(0, budget.limitAmount - budget.currentSpend))),
                .makeRow(label: "Refresh", value: budget.refreshPeriod.rawValue),
            ])],
            updatedAt: now,
            identity: identity,
            dataConfidence: .exact)
    }

    public func teams(environment: [String: String]) async throws -> [VercelCLITeam] {
        try await self.teams(environment: environment, deadline: self.clockNow().advanced(by: .seconds(30)))
    }

    private func teams(
        environment: [String: String], deadline: ContinuousClock.Instant) async throws -> [VercelCLITeam]
    {
        var teams: [VercelCLITeam] = []
        var ids: Set<String> = []
        var cursor: Int?
        var cursors: Set<Int> = []
        for _ in 0..<20 {
            var arguments = ["teams", "list", "--format", "json", "--non-interactive"]
            if let cursor { arguments += ["--next", String(cursor)] }
            let page: TeamsResponse = try await self.command(arguments, environment: environment, deadline: deadline)
            for team in page.teams where team.id.hasPrefix("team_") {
                guard Self.isTeamID(team.id), !team.name.isEmpty, !team.slug.isEmpty,
                      ids.insert(team.id).inserted
                else { throw Self.invalidOutput }
                teams.append(team)
            }
            cursor = page.pagination?.next
            guard let next = cursor else {
                guard teams.filter(\.current).count <= 1 else { throw Self.invalidOutput }
                return teams
            }
            guard next >= 0, cursors.insert(next).inserted else { throw Self.invalidOutput }
        }
        throw Self.invalidOutput
    }

    private static func isTeamID(_ value: String) -> Bool {
        value.range(of: #"^team_[A-Za-z0-9]+$"#, options: .regularExpression) != nil
    }

    private func read<Value: Decodable>(
        _ endpoint: String,
        teamID: String,
        environment: [String: String],
        deadline: ContinuousClock.Instant) async throws -> Value
    {
        // CLI의 기본 팀이 URL의 teamId를 덮어쓰므로 호출 범위도 같은 팀으로 고정한다.
        try await self.command(
            ["api", endpoint, "--raw", "--non-interactive", "--scope", teamID],
            environment: environment,
            deadline: deadline)
    }

    private func command<Value: Decodable>(
        _ arguments: [String], environment: [String: String], deadline: ContinuousClock.Instant) async throws -> Value
    {
        let timeout = try self.commandTimeout(deadline: deadline)
        let output: String
        do {
            output = try await self.run(arguments, Self.commandEnvironment(environment), timeout)
        } catch {
            try Task.checkCancellation()
            switch error {
            case is CancellationError:
                throw CancellationError()
            case SubprocessRunnerError.binaryNotFound:
                throw ProviderFetchClassifiedError(
                    kind: .missingCredential,
                    message: "Install the Vercel CLI and run 'vercel login' to read personal budgets.")
            case SubprocessRunnerError.timedOut:
                throw Self.timedOut
            case SubprocessRunnerError.outputTooLarge:
                throw ProviderFetchClassifiedError(
                    kind: .parseFailure, message: "Vercel CLI response exceeded the 1 MiB output limit.")
            default:
                throw ProviderFetchClassifiedError(
                    kind: .apiFailure,
                    message: "Vercel CLI could not read personal budgets. "
                        + "Check 'vercel login', team access, and CLI updates.")
            }
        }
        _ = try self.commandTimeout(deadline: deadline)
        guard let decoded = try? JSONDecoder().decode(Value.self, from: Data(output.utf8)) else {
            throw Self.invalidOutput
        }
        _ = try self.commandTimeout(deadline: deadline)
        return decoded
    }

    private func commandTimeout(deadline: ContinuousClock.Instant) throws -> TimeInterval {
        try Task.checkCancellation()
        let remaining = self.clockNow().duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard seconds > 0 else { throw Self.timedOut }
        return min(15, seconds)
    }

    private static let timedOut = ProviderFetchClassifiedError(
        kind: .networkFailure, message: "Vercel CLI usage or team lookup timed out. Try refreshing again.")

    private static let invalidOutput = ProviderFetchClassifiedError(
        kind: .parseFailure, message: "Vercel CLI returned an unrecognized usage or team response.")

    private static func runCommand(
        _ arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> String
    {
        let path = PathBuilder.effectivePATH(
            purposes: [.tty, .nodeTooling], env: environment, loginPATH: LoginShellPathCache.shared.current)
        guard let binary = BinaryLocator.find(
            "vercel", in: path.split(separator: ":").map(String.init), fileManager: .default)
        else {
            throw SubprocessRunnerError.binaryNotFound("vercel")
        }
        var childEnvironment = environment
        childEnvironment["PATH"] = path
        let result = try await SubprocessRunner.run(
            binary: binary,
            arguments: arguments,
            environment: childEnvironment,
            timeout: timeout,
            maxOutputBytes: 1024 * 1024,
            standardInput: FileHandle.nullDevice,
            currentDirectoryURL: URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true),
            label: "vercel-personal-budget")
        return result.stdout
    }

    private static func commandEnvironment(_ environment: [String: String]) -> [String: String] {
        let allowed = Set([
            "PATH",
            "HOME", "XDG_CONFIG_HOME", "APPDATA", "LANG", "LC_ALL", "LC_CTYPE", "TZ",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
            "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        ])
        var childEnvironment = environment.filter { allowed.contains($0.key) }
        // 이전 CLI의 SAML 재인증도 브라우저를 열지 않도록 CI 모드를 명시한다.
        childEnvironment["CI"] = "1"
        childEnvironment["NO_COLOR"] = "1"
        childEnvironment["VERCEL_TELEMETRY_DISABLED"] = "1"
        return childEnvironment
    }

    private struct UserResponse: Decodable {
        let user: User
        struct User: Decodable {
            let id: String
            let email: String?
        }
    }

    private struct BudgetResponse: Decodable {
        let budgets: [Budget]
        let nextCursor: String?
    }

    private struct TeamsResponse: Decodable {
        let teams: [VercelCLITeam]
        let pagination: Pagination?
        struct Pagination: Decodable {
            let next: Int?
        }
    }

    private struct Budget: Decodable {
        let scopeType: String
        let scopeId: String
        let limitAmount: Double
        let currentSpend: Double
        let refreshPeriod: RefreshPeriod
        let active: Bool
        let archived: Bool
        let source: String?
    }

    private enum RefreshPeriod: String, Decodable {
        case daily, weekly, monthly, none

        var component: Calendar.Component? {
            switch self {
            case .daily: .day
            case .weekly: .weekOfYear
            case .monthly: .month
            case .none: nil
            }
        }
    }
}

struct VercelCLIFetchStrategy: ProviderFetchStrategy {
    let id = "vercel.cli"
    let kind: ProviderFetchKind = .cli
    var fetcher = VercelCLIUsageFetcher()

    func isAvailable(_: ProviderFetchContext) async -> Bool { true }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        try await self.makeResult(
            usage: self.fetcher.fetch(environment: context.env), sourceLabel: "cli")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto && SettingsValue.cleaned(context.env["VERCEL_TEAM_ID"]) == nil
            && !(error is CancellationError)
    }
}

public struct VercelCLITeam: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let slug: String
    public let name: String
    public let current: Bool
}
