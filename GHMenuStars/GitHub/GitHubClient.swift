import Foundation

enum GitHubError: Error, Equatable {
    case invalidRepositoryInput
    case notFoundOrPrivate
    case rateLimited(RateLimitState)
    case unauthorized
    case notModified
    case server(Int)
    case decoding
    case authPending
    case authDenied
    case missingToken
    case transport(String)

    static func userMessage(for error: Error) -> String {
        switch error {
        case GitHubError.invalidRepositoryInput:
            return "Enter a GitHub repository as owner/repo or https://github.com/owner/repo."
        case GitHubError.notFoundOrPrivate:
            return "Repository not found, or no token in Settings can see it. For a private repository, add a fine-grained token in Settings — and if it belongs to an organization, set the token's resource owner to that organization."
        case GitHubError.rateLimited(let state):
            return "GitHub rate limit active. Retry \(RelativeDateTimeFormatter.menu.string(for: state.resetAt) ?? "later")."
        case GitHubError.unauthorized, GitHubError.missingToken:
            return "GitHub authorization is required for that action."
        case GitHubError.authPending:
            return "Authorization is still pending."
        case GitHubError.authDenied:
            return "GitHub authorization was denied."
        case GitHubError.server(let statusCode):
            return "GitHub returned HTTP \(statusCode). Try again later."
        case GitHubError.decoding:
            return "GitHub returned an unexpected response."
        case GitHubError.transport(let message):
            return message
        default:
            return "GitHub request failed. Try again later."
        }
    }
}

struct GitHubRepoResponse: Decodable, Equatable {
    var fullName: String
    var stargazersCount: Int
    var forksCount: Int
    var `private`: Bool

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case stargazersCount = "stargazers_count"
        case forksCount = "forks_count"
        case `private`
    }
}

struct GitHubRelease: Equatable {
    var tagName: String = ""
    var name: String?
    var publishedAt: Date?
    var draft: Bool = false
    var prerelease: Bool = false
    var assets: [GitHubReleaseAsset]
}

extension GitHubRelease: Decodable {
    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case publishedAt = "published_at"
        case draft
        case prerelease
        case assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decodeIfPresent(String.self, forKey: .tagName) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name)
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        assets = try container.decodeIfPresent([GitHubReleaseAsset].self, forKey: .assets) ?? []
    }
}

struct GitHubReleaseAsset: Decodable, Equatable {
    var name: String
    var downloadCount: Int

    enum CodingKeys: String, CodingKey {
        case name
        case downloadCount = "download_count"
    }
}

struct GitHubStargazer: Decodable, Equatable {
    var starredAt: Date

    enum CodingKeys: String, CodingKey {
        case starredAt = "starred_at"
    }
}

struct GitHubFork: Decodable, Equatable {
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
    }
}

struct GitHubAuthenticatedUser: Decodable, Equatable {
    var login: String
}

private struct GitHubRepoActivity: Decodable {
    var activityType: String
    var ref: String
    var timestamp: Date

    enum CodingKeys: String, CodingKey {
        case activityType = "activity_type"
        case ref
        case timestamp
    }
}

private struct GitHubCommitDate: Decodable {
    struct Commit: Decodable {
        struct Author: Decodable { var date: Date }
        var author: Author
    }
    var sha: String
    var commit: Commit
}

private struct GitHubSearchCount: Decodable, Equatable {
    var totalCount: Int

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
    }
}

private struct GitHubWorkflowRunsResponse: Decodable, Equatable {
    var workflowRuns: [GitHubWorkflowRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

private struct GitHubCommitSummary: Decodable, Equatable {
    var sha: String
}

private struct GitHubWorkflowRun: Decodable, Equatable {
    var workflowID: Int?
    var name: String?
    var displayTitle: String?
    var htmlURL: String
    var status: String?
    var conclusion: String?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case workflowID = "workflow_id"
        case name
        case displayTitle = "display_title"
        case htmlURL = "html_url"
        case status
        case conclusion
        case createdAt = "created_at"
    }
}

struct GitHubRepoSummary: Decodable, Identifiable, Equatable {
    struct Owner: Decodable, Equatable {
        var login: String
    }

    var id: Int
    var name: String
    var fullName: String
    var owner: Owner
    var isPrivate: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case fullName = "full_name"
        case owner
        case isPrivate = "private"
    }

    // Hand-written because Swift's synthesized decoder ignores a property's
    // default value: a missing "private" key throws keyNotFound rather than
    // falling back to false.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        fullName = try container.decode(String.self, forKey: .fullName)
        owner = try container.decode(Owner.self, forKey: .owner)
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
    }

    init(id: Int, name: String, fullName: String, owner: Owner, isPrivate: Bool = false) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.owner = owner
        self.isPrivate = isPrivate
    }
}

struct GitHubHTTPResult<T> {
    var value: T
    var etag: String?
    var rateLimitState: RateLimitState?
    var nextPagePath: String?
    var lastPagePath: String?
}

final class GitHubClient {
    /// Page cap for incremental (since-scoped) trend refreshes — a poll only sees
    /// events added since the last check, so a couple of pages is plenty.
    static let trendPageLimit = 10

    /// Page cap for the one-time full-history backfill when authenticated. Deep
    /// enough to cover realistic repos in full (10k pages × 100 ≈ 1M stars) while
    /// still bounding a pathological outlier. Only paid once, in the background.
    static let trendBackfillPageLimitAuthenticated = 500

    /// Page cap per branch for the commit window: 20 pages = 2,000 commits in 30
    /// days on one branch. Past that the exact figure stops meaning anything in a
    /// menu bar, and the cap stops a pathological repo from stalling a poll.
    static let commitPageLimit = 20

    private let session: URLSession
    private let tokenProvider: () -> String?
    private let optionalTokenProvider: () -> String?
    private let decoder: JSONDecoder

    init(
        session: URLSession = .shared,
        tokenProvider: @escaping () -> String? = { nil },
        optionalTokenProvider: @escaping () -> String? = { nil }
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
        self.optionalTokenProvider = optionalTokenProvider
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Page cap for a full-history trend backfill: generous when authenticated
    /// (5,000 req/hr headroom), tight when anonymous to protect the 60 req/hr limit.
    func trendBackfillPageLimit() -> Int {
        optionalTokenProvider() != nil ? Self.trendBackfillPageLimitAuthenticated : Self.trendPageLimit
    }

    func fetchRepo(
        owner: String,
        name: String,
        etag: String?,
        optionalAuthToken: String? = nil
    ) async throws -> GitHubHTTPResult<GitHubRepoResponse> {
        try await request(
            path: "/repos/\(owner)/\(name)",
            etag: etag,
            requiresAuth: false,
            optionalAuthToken: optionalAuthToken
        )
    }

    func fetchReleases(
        owner: String,
        name: String,
        etag: String?,
        optionalAuthToken: String? = nil
    ) async throws -> GitHubHTTPResult<[GitHubRelease]> {
        try await request(
            path: "/repos/\(owner)/\(name)/releases?per_page=100",
            etag: etag,
            requiresAuth: false,
            optionalAuthToken: optionalAuthToken
        )
    }

    func fetchRecentStargazerDates(owner: String, name: String, since: Date) async throws -> [Date] {
        try await fetchStargazerDates(owner: owner, name: name, since: since)
    }

    func fetchStargazerDates(owner: String, name: String, since: Date? = nil, maxPages: Int? = nil) async throws -> [Date] {
        let basePath = "/repos/\(owner)/\(name)/stargazers?per_page=100"
        let firstPage: GitHubHTTPResult<[GitHubStargazer]> = try await request(
            path: basePath,
            etag: nil,
            requiresAuth: false,
            accept: "application/vnd.github.star+json"
        )
        guard let lastPage = Self.pageNumber(from: firstPage.lastPagePath), lastPage > 1 else {
            return firstPage.value.map(\.starredAt).filter { date in
                since.map { date >= $0 } ?? true
            }.sorted()
        }

        // For an all-time backfill on a large repo, fetch only the newest pages.
        // Older stargazers fall outside the retained trend window (the baseline
        // is derived from the total count), and fetching every page would blow
        // the rate limit. The `since`-scoped path already self-limits by date.
        let pages: [Int]
        let includesFirstPage: Bool
        if since == nil, let maxPages, lastPage > maxPages {
            pages = Array(stride(from: lastPage, through: lastPage - maxPages + 1, by: -1))
            includesFirstPage = false
        } else {
            pages = since == nil
                ? Array(2...lastPage)
                : Array(stride(from: lastPage, through: 2, by: -1))
            includesFirstPage = true
        }

        var dates = includesFirstPage
            ? firstPage.value.map(\.starredAt).filter { date in since.map { date >= $0 } ?? true }
            : []
        for page in pages {
            let result: GitHubHTTPResult<[GitHubStargazer]> = try await request(
                path: "\(basePath)&page=\(page)",
                etag: nil,
                requiresAuth: false,
                accept: "application/vnd.github.star+json"
            )
            let pageDates = result.value.map(\.starredAt)
            dates.append(contentsOf: pageDates.filter { date in
                since.map { date >= $0 } ?? true
            })
            if let since, !pageDates.isEmpty, pageDates.allSatisfy({ $0 < since }) {
                break
            }
        }

        return dates.sorted()
    }

    func fetchRecentForkDates(owner: String, name: String, since: Date) async throws -> [Date] {
        try await fetchForkDates(owner: owner, name: name, since: since)
    }

    func fetchForkDates(owner: String, name: String, since: Date? = nil, maxPages: Int? = nil) async throws -> [Date] {
        var path: String? = "/repos/\(owner)/\(name)/forks?sort=newest&per_page=100"
        var dates: [Date] = []
        var pagesFetched = 0

        while let currentPath = path {
            let result: GitHubHTTPResult<[GitHubFork]> = try await request(
                path: currentPath,
                etag: nil,
                requiresAuth: false
            )
            pagesFetched += 1
            let pageDates = result.value.map(\.createdAt)
            dates.append(contentsOf: pageDates.filter { date in
                since.map { date >= $0 } ?? true
            })
            if let since, !pageDates.isEmpty, pageDates.allSatisfy({ $0 < since }) {
                break
            }
            // Forks come newest-first, so capping keeps the most recent pages.
            if let maxPages, pagesFetched >= maxPages {
                break
            }
            path = result.nextPagePath
        }

        return dates.sorted()
    }

    /// Validates a pasted token by asking who it belongs to. Deliberately does
    /// not try to enumerate the token's grant: no endpoint reports that
    /// reliably for a fine-grained PAT, so promising a repo count in the UI
    /// would be promising something we can't know.
    func fetchAuthenticatedLogin(token: String) async throws -> String {
        let result: GitHubHTTPResult<GitHubAuthenticatedUser> = try await request(
            path: "/user",
            etag: nil,
            requiresAuth: false,
            optionalAuthToken: token
        )
        return result.value.login
    }

    /// Lists the private repos a fine-grained PAT can reach.
    ///
    /// Deliberately separate from the OAuth-backed public listing rather than
    /// replacing it: the OAuth scope (`public_repo`) cannot see private repos at
    /// all, and routing the whole picker through the PAT would empty it entirely
    /// the moment that token expires — or for any user who never adds one.
    func fetchAccessiblePrivateRepos(token: String) async throws -> [GitHubRepoSummary] {
        var repos: [GitHubRepoSummary] = []
        var path: String? = "/user/repos?visibility=private&affiliation=owner,collaborator&sort=updated&per_page=100"

        while let currentPath = path {
            let result: GitHubHTTPResult<[GitHubRepoSummary]> = try await request(
                path: currentPath,
                etag: nil,
                requiresAuth: false,
                optionalAuthToken: token
            )
            repos.append(contentsOf: result.value)
            path = result.nextPagePath
        }

        return repos
    }

    func fetchAccessiblePublicRepos() async throws -> [GitHubRepoSummary] {
        var repos: [GitHubRepoSummary] = []
        var path: String? = "/user/repos?visibility=public&affiliation=owner,collaborator&sort=updated&per_page=100"

        while let currentPath = path {
            let result: GitHubHTTPResult<[GitHubRepoSummary]> = try await request(
                path: currentPath,
                etag: nil,
                requiresAuth: true
            )
            repos.append(contentsOf: result.value)
            path = result.nextPagePath
        }

        return repos
    }

    func fetchMaintainerRadar(
        owner: String,
        name: String,
        activityWindow: MaintainerRadarActivityWindow,
        releaseAnchor: Date? = nil,
        now: Date = Date(),
        optionalAuthToken: String? = nil
    ) async -> RepoMaintainerRadar {
        let activityStart = releaseAnchor ?? activityWindow.startDate(now: now)
        // A supplied token wins. For a private repo this is the PAT; the ambient
        // provider only ever holds the OAuth token, which cannot see the repo —
        // every call would 404 and the optional* wrappers below would swallow it
        // into blank rows with no error.
        let optionalAuthToken = optionalAuthToken ?? optionalTokenProvider()
        async let openPullRequests = optionalSearchIssueCount(
            query: "repo:\(owner)/\(name) is:pr is:open",
            optionalAuthToken: optionalAuthToken
        )
        async let newPullRequests = optionalActivityCount(
            owner: owner,
            name: name,
            kind: .pullRequest,
            since: activityStart,
            optionalAuthToken: optionalAuthToken
        )
        async let newIssues = optionalActivityCount(
            owner: owner,
            name: name,
            kind: .issue,
            since: activityStart,
            optionalAuthToken: optionalAuthToken
        )
        async let unansweredIssues = optionalSearchIssueCount(
            query: "repo:\(owner)/\(name) is:issue is:open comments:0",
            optionalAuthToken: optionalAuthToken
        )
        async let recentCommits = optionalCrossBranchCommitCount(
            owner: owner,
            name: name,
            since: activityStart,
            now: now,
            optionalAuthToken: optionalAuthToken
        )
        async let workflowFailure = optionalLatestFailedWorkflow(
            owner: owner,
            name: name,
            optionalAuthToken: optionalAuthToken
        )
        let (pullRequests, freshPullRequests, freshIssues, needsReply, commits, workflow) = await (
            openPullRequests,
            newPullRequests,
            newIssues,
            unansweredIssues,
            recentCommits,
            workflowFailure
        )

        return RepoMaintainerRadar(
            openPullRequests: pullRequests,
            newPullRequests: freshPullRequests,
            newIssues: freshIssues,
            unansweredIssues: needsReply,
            recentCommits: commits,
            activityWindow: activityStart == nil ? nil : activityWindow,
            activityAnchoredSince: releaseAnchor,
            latestFailedWorkflow: workflow.failure,
            workflowChecked: workflow.checked,
            checkedAt: now
        )
    }

    private enum ActivityKind {
        case issue
        case pullRequest

        var searchQualifier: String {
            switch self {
            case .issue: return "is:issue"
            case .pullRequest: return "is:pr"
            }
        }
    }

    private func optionalActivityCount(
        owner: String,
        name: String,
        kind: ActivityKind,
        since: Date?,
        optionalAuthToken: String?
    ) async -> Int? {
        guard let since else { return nil }
        let query = "repo:\(owner)/\(name) \(kind.searchQualifier) is:open created:>=\(Self.iso8601String(from: since))"
        return await optionalSearchIssueCount(query: query, optionalAuthToken: optionalAuthToken)
    }

    private func optionalSearchIssueCount(query: String, optionalAuthToken: String?) async -> Int? {
        do {
            return try await searchIssueCount(query: query, optionalAuthToken: optionalAuthToken)
        } catch {
            return nil
        }
    }

    private func searchIssueCount(query: String, optionalAuthToken: String?) async throws -> Int {
        let result: GitHubHTTPResult<GitHubSearchCount> = try await request(
            path: Self.path("/search/issues", queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "per_page", value: "1")
            ]),
            etag: nil,
            requiresAuth: false,
            optionalAuthToken: optionalAuthToken
        )
        return result.value.totalCount
    }

    /// Counts commits across **every branch** touched in the window, not just the
    /// default one.
    ///
    /// `/repos/{o}/{r}/commits` only ever reports the default branch. On a repo
    /// whose work lives on a feature branch that reads 0 while the author is
    /// committing daily — measured on a real repo: 0 on `main`, 100+ on the
    /// feature branch, same week.
    ///
    /// `/activity` reports pushes across all refs in one call, so it tells us
    /// which branches actually moved; we then fan out only over those. Commits
    /// must be deduped by SHA, because a branch cut from main replays main's
    /// shared history and naive summing would multiply-count it.
    /// Commit *dates* across every branch touched in the window.
    ///
    /// Dates rather than a count, because one fetch then feeds both surfaces:
    /// the radar's windowed number and the chart's daily buckets. Counting
    /// twice would double the API cost to say the same thing.
    func fetchCrossBranchCommitDates(
        owner: String,
        name: String,
        since: Date,
        now: Date = Date(),
        optionalAuthToken: String? = nil
    ) async -> [Date]? {
        do {
            let period = Self.activityTimePeriod(since: since, now: now)
            let activity: GitHubHTTPResult<[GitHubRepoActivity]> = try await request(
                path: "/repos/\(owner)/\(name)/activity?time_period=\(period)&per_page=100",
                etag: nil,
                requiresAuth: false,
                optionalAuthToken: optionalAuthToken
            )
            let refs = Set(
                activity.value
                    .filter { $0.timestamp >= since }
                    .filter { $0.activityType.contains("push") }
                    .compactMap { $0.ref.split(separator: "/").last.map(String.init) }
            )
            guard !refs.isEmpty else { return [] }

            // Dedupe by SHA: a branch cut from main replays main's shared
            // history, so summing per-ref counts multiplies the same commits.
            var seen: [String: Date] = [:]
            for ref in refs.sorted() {
                // Follow pages. A single per_page=100 request silently caps at
                // exactly 100, so a branch with 137 commits reported "100" — a
                // number that looks real and is wrong, which is worse than an
                // obvious failure.
                var path: String? = Self.path("/repos/\(owner)/\(name)/commits", queryItems: [
                    URLQueryItem(name: "sha", value: ref),
                    URLQueryItem(name: "since", value: Self.iso8601String(from: since)),
                    URLQueryItem(name: "per_page", value: "100")
                ])
                var pages = 0
                while let currentPath = path, pages < Self.commitPageLimit {
                    let commits: GitHubHTTPResult<[GitHubCommitDate]> = try await request(
                        path: currentPath,
                        etag: nil,
                        requiresAuth: false,
                        optionalAuthToken: optionalAuthToken
                    )
                    for commit in commits.value where seen[commit.sha] == nil {
                        seen[commit.sha] = commit.commit.author.date
                    }
                    path = commits.nextPagePath
                    pages += 1
                }
            }
            return Array(seen.values).sorted()
        } catch {
            return nil
        }
    }

    /// `/activity` windows server-side but only offers coarse periods, so pick the
    /// smallest one that still contains `since`; the caller filters precisely.
    static func activityTimePeriod(since: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(since)
        if interval <= 86_400 { return "day" }
        if interval <= 7 * 86_400 { return "week" }
        if interval <= 30 * 86_400 { return "month" }
        return "quarter"
    }

    private func optionalCrossBranchCommitCount(
        owner: String,
        name: String,
        since: Date?,
        now: Date,
        optionalAuthToken: String?
    ) async -> Int? {
        guard let since else { return nil }
        return await fetchCrossBranchCommitDates(
            owner: owner, name: name, since: since, now: now, optionalAuthToken: optionalAuthToken
        )?.count
    }

    private func optionalCommitCount(
        owner: String,
        name: String,
        since: Date?,
        optionalAuthToken: String?
    ) async -> Int? {
        guard let since else { return nil }
        do {
            return try await commitCount(owner: owner, name: name, since: since, optionalAuthToken: optionalAuthToken)
        } catch {
            return nil
        }
    }

    private func commitCount(owner: String, name: String, since: Date, optionalAuthToken: String?) async throws -> Int {
        let result: GitHubHTTPResult<[GitHubCommitSummary]> = try await request(
            path: Self.path("/repos/\(owner)/\(name)/commits", queryItems: [
                URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since)),
                URLQueryItem(name: "per_page", value: "1")
            ]),
            etag: nil,
            requiresAuth: false,
            optionalAuthToken: optionalAuthToken
        )
        if let lastPage = Self.pageNumber(from: result.lastPagePath) {
            return lastPage
        }
        return result.value.count
    }

    private func optionalLatestFailedWorkflow(
        owner: String,
        name: String,
        optionalAuthToken: String?
    ) async -> (checked: Bool, failure: RepoWorkflowFailure?) {
        do {
            return (true, try await latestFailedWorkflow(owner: owner, name: name, optionalAuthToken: optionalAuthToken))
        } catch {
            return (false, nil)
        }
    }

    private func latestFailedWorkflow(
        owner: String,
        name: String,
        optionalAuthToken: String?
    ) async throws -> RepoWorkflowFailure? {
        let result: GitHubHTTPResult<GitHubWorkflowRunsResponse> = try await request(
            path: "/repos/\(owner)/\(name)/actions/runs?per_page=20",
            etag: nil,
            requiresAuth: false,
            optionalAuthToken: optionalAuthToken
        )
        let runs = result.value.workflowRuns.sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        var seenWorkflowKeys = Set<String>()
        for run in runs {
            let key = run.workflowID.map(String.init) ?? run.name ?? run.htmlURL
            guard !seenWorkflowKeys.contains(key) else { continue }
            seenWorkflowKeys.insert(key)
            guard Self.isFailingWorkflowConclusion(run.conclusion) else { continue }
            return RepoWorkflowFailure(
                name: run.name ?? run.displayTitle ?? "Workflow failure",
                url: run.htmlURL,
                failedAt: run.createdAt
            )
        }
        return nil
    }

    private static func isFailingWorkflowConclusion(_ conclusion: String?) -> Bool {
        guard let conclusion else { return false }
        return ["action_required", "failure", "startup_failure", "timed_out"].contains(conclusion)
    }

    private func request<T: Decodable>(
        path: String,
        etag: String?,
        requiresAuth: Bool,
        accept: String = "application/vnd.github+json",
        optionalAuthToken: String? = nil
    ) async throws -> GitHubHTTPResult<T> {
        guard let url = URL(string: "https://api.github.com\(path)") else {
            throw GitHubError.transport("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("GHMenuStars/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if requiresAuth {
            guard let token = tokenProvider() else {
                throw GitHubError.missingToken
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let token = optionalAuthToken ?? optionalTokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GitHubError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.transport("Missing HTTP response")
        }
        let rate = RateLimitState.from(headers: http.allHeaderFields)
        switch http.statusCode {
        case 200..<300:
            do {
                let value = try decoder.decode(T.self, from: data)
                return GitHubHTTPResult(
                    value: value,
                    etag: http.value(forHTTPHeaderField: "ETag"),
                    rateLimitState: rate,
                    nextPagePath: Self.pagePath(from: http, relation: "next"),
                    lastPagePath: Self.pagePath(from: http, relation: "last")
                )
            } catch {
                throw GitHubError.decoding
            }
        case 304:
            throw GitHubError.notModified
        case 401:
            if let rate, rate.isLimited {
                throw GitHubError.rateLimited(rate)
            }
            throw GitHubError.unauthorized
        case 403:
            if let rate, rate.isLimited {
                throw GitHubError.rateLimited(rate)
            }
            throw GitHubError.server(http.statusCode)
        case 404:
            throw GitHubError.notFoundOrPrivate
        default:
            throw GitHubError.server(http.statusCode)
        }
    }

    private static func pagePath(from response: HTTPURLResponse, relation: String) -> String? {
        guard let linkHeader = response.value(forHTTPHeaderField: "Link") else { return nil }

        for rawLink in Self.linkHeaderEntries(from: linkHeader) {
            let parts = rawLink.split(separator: ";").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.contains("rel=\"\(relation)\""),
                  let urlPart = parts.first,
                  urlPart.hasPrefix("<"),
                  urlPart.hasSuffix(">") else {
                continue
            }

            let urlString = String(urlPart.dropFirst().dropLast())
            guard let url = URL(string: urlString),
                  url.host?.caseInsensitiveCompare("api.github.com") == .orderedSame else {
                continue
            }

            var path = url.path
            if let query = url.query {
                path += "?\(query)"
            }
            return path
        }

        return nil
    }

    private static func pageNumber(from path: String?) -> Int? {
        guard let path,
              let components = URLComponents(string: "https://api.github.com\(path)") else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "page" })?.value.flatMap(Int.init)
    }

    private static func linkHeaderEntries(from header: String) -> [String] {
        var entries: [String] = []
        var current = ""
        var isInsideURL = false

        for character in header {
            switch character {
            case "<":
                isInsideURL = true
                current.append(character)
            case ">":
                isInsideURL = false
                current.append(character)
            case "," where !isInsideURL:
                let entry = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !entry.isEmpty {
                    entries.append(entry)
                }
                current = ""
            default:
                current.append(character)
            }
        }

        let entry = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entry.isEmpty {
            entries.append(entry)
        }
        return entries
    }

    private static func path(_ path: String, queryItems: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.path = path
        components.queryItems = queryItems
        return components.string ?? path
    }

    private static func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
