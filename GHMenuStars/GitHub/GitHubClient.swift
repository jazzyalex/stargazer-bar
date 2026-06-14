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
            return "Repository was not found or is private. V1 tracks public repositories only."
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

struct GitHubRelease: Decodable, Equatable {
    var assets: [GitHubReleaseAsset]
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

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case fullName = "full_name"
        case owner
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
    private let session: URLSession
    private let tokenProvider: () -> String?
    private let decoder: JSONDecoder

    init(session: URLSession = .shared, tokenProvider: @escaping () -> String? = { nil }) {
        self.session = session
        self.tokenProvider = tokenProvider
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func fetchRepo(owner: String, name: String, etag: String?) async throws -> GitHubHTTPResult<GitHubRepoResponse> {
        try await request(
            path: "/repos/\(owner)/\(name)",
            etag: etag,
            requiresAuth: false
        )
    }

    func fetchReleases(owner: String, name: String, etag: String?) async throws -> GitHubHTTPResult<[GitHubRelease]> {
        try await request(
            path: "/repos/\(owner)/\(name)/releases?per_page=100",
            etag: etag,
            requiresAuth: false
        )
    }

    func fetchRecentStargazerDates(owner: String, name: String, since: Date) async throws -> [Date] {
        try await fetchStargazerDates(owner: owner, name: name, since: since)
    }

    func fetchStargazerDates(owner: String, name: String, since: Date? = nil) async throws -> [Date] {
        let basePath = "/repos/\(owner)/\(name)/stargazers?per_page=100"
        let firstPage: GitHubHTTPResult<[GitHubStargazer]> = try await request(
            path: basePath,
            etag: nil,
            requiresAuth: false,
            accept: "application/vnd.github.star+json"
        )
        var dates = firstPage.value.map(\.starredAt).filter { date in
            since.map { date >= $0 } ?? true
        }
        guard let lastPage = Self.pageNumber(from: firstPage.lastPagePath), lastPage > 1 else {
            return dates.sorted()
        }

        let pages = since == nil
            ? Array(2...lastPage)
            : Array(stride(from: lastPage, through: 2, by: -1))
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

    func fetchForkDates(owner: String, name: String, since: Date? = nil) async throws -> [Date] {
        var path: String? = "/repos/\(owner)/\(name)/forks?sort=newest&per_page=100"
        var dates: [Date] = []

        while let currentPath = path {
            let result: GitHubHTTPResult<[GitHubFork]> = try await request(
                path: currentPath,
                etag: nil,
                requiresAuth: false
            )
            let pageDates = result.value.map(\.createdAt)
            dates.append(contentsOf: pageDates.filter { date in
                since.map { date >= $0 } ?? true
            })
            if let since, !pageDates.isEmpty, pageDates.allSatisfy({ $0 < since }) {
                break
            }
            path = result.nextPagePath
        }

        return dates.sorted()
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

    func fetchMaintainerRadar(owner: String, name: String) async -> RepoMaintainerRadar {
        async let openPullRequests = optionalSearchIssueCount(query: "repo:\(owner)/\(name) is:pr is:open")
        async let unansweredIssues = optionalSearchIssueCount(query: "repo:\(owner)/\(name) is:issue is:open comments:0")
        async let workflowFailure = optionalLatestFailedWorkflow(owner: owner, name: name)
        let (pullRequests, issues, workflow) = await (openPullRequests, unansweredIssues, workflowFailure)

        return RepoMaintainerRadar(
            openPullRequests: pullRequests,
            unansweredIssues: issues,
            latestFailedWorkflow: workflow.failure,
            workflowChecked: workflow.checked,
            checkedAt: Date()
        )
    }

    private func optionalSearchIssueCount(query: String) async -> Int? {
        do {
            return try await searchIssueCount(query: query)
        } catch {
            return nil
        }
    }

    private func searchIssueCount(query: String) async throws -> Int {
        let result: GitHubHTTPResult<GitHubSearchCount> = try await request(
            path: Self.path("/search/issues", queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "per_page", value: "1")
            ]),
            etag: nil,
            requiresAuth: false
        )
        return result.value.totalCount
    }

    private func optionalLatestFailedWorkflow(owner: String, name: String) async -> (checked: Bool, failure: RepoWorkflowFailure?) {
        do {
            return (true, try await latestFailedWorkflow(owner: owner, name: name))
        } catch {
            return (false, nil)
        }
    }

    private func latestFailedWorkflow(owner: String, name: String) async throws -> RepoWorkflowFailure? {
        let result: GitHubHTTPResult<GitHubWorkflowRunsResponse> = try await request(
            path: "/repos/\(owner)/\(name)/actions/runs?per_page=20",
            etag: nil,
            requiresAuth: false
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
                url: run.htmlURL
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
        accept: String = "application/vnd.github+json"
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
        if requiresAuth, let token = tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if requiresAuth {
            throw GitHubError.missingToken
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
}
