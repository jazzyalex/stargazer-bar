import Foundation

enum StargazerCheckError: Error {
    case inconsistent
    case accessUnverified
    case insufficientBudget
    case scopeChanged
}

struct StargazerAccount: Codable, Equatable, Identifiable {
    let id: Int64
    let login: String
    let seenAt: Date
}

struct StargazerScope: Codable, Equatable {
    let repositoryID: Int64
    let viewerID: Int64
    let credentialSource: String
    let visibility: String

    var requiresStarHistoryCrossCheck: Bool {
        repositoryID == GitHubClient.agentSessionsRepositoryID && visibility == "public"
    }
}

struct StargazerSnapshot: Codable, Equatable {
    let scope: StargazerScope
    let startedAt: Date
    let completedAt: Date
    let accounts: [StargazerAccount]
    /// The headline count from a check corroborated by GraphQL and star history.
    var reportedStarCount: Int? = nil
}

struct StargazerDisappearance: Codable, Equatable, Identifiable {
    let id: UUID
    let scope: StargazerScope
    let repository: String
    let account: StargazerAccount
    let missingAt: Date
}

struct GitHubStargazerAuthor: Decodable {
    let id: Int64
    let login: String
    let name: String?
    let bio: String?
    let followers: Int?
    let publicRepos: Int?
    let blog: String?
    let twitterUsername: String?

    enum CodingKeys: String, CodingKey {
        case id, login, name, bio, followers, blog
        case publicRepos = "public_repos"
        case twitterUsername = "twitter_username"
    }

    var profileLinks: [StargazerProfileLink] {
        var links: [StargazerProfileLink] = []
        if let url = URL(string: "https://github.com\(GitHubClient.path("/\(login)", queryItems: []))") {
            links.append(StargazerProfileLink(label: "GitHub", url: url))
        }
        if let twitterUsername, !twitterUsername.isEmpty,
           twitterUsername.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }),
           let url = URL(string: "https://x.com/\(twitterUsername)") {
            links.append(StargazerProfileLink(label: "X", url: url))
        }
        if let blog, let link = StargazerProfileLink.site(blog) { links.append(link) }
        return links
    }
}

struct StargazerProfileLink: Identifiable {
    let label: String
    let url: URL
    var id: URL { url }

    static func site(_ value: String) -> Self? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: address),
              components.scheme == "https" || components.scheme == "http",
              let host = components.host?.lowercased(), host.contains("."),
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        let base = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        switch base {
        case "linkedin.com": return Self(label: "LinkedIn", url: url)
        case "x.com", "twitter.com": return Self(label: "X", url: url)
        case "mastodon.social": return Self(label: "Mastodon", url: url)
        case "bsky.app": return Self(label: "Bluesky", url: url)
        default: return Self(label: "Website", url: url)
        }
    }

    static func unique(_ links: [Self]) -> [Self] {
        var seen: Set<String> = []
        return links.filter { link in
            guard let url = URLComponents(url: link.url, resolvingAgainstBaseURL: false) else { return false }
            let host = url.host?.lowercased().replacingOccurrences(of: "www.", with: "", options: .anchored)
            let domain = host == "twitter.com" ? "x.com" : host
            return seen.insert("\(domain ?? "")\(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))|\(url.query ?? "")").inserted
        }
    }
}

private struct StargazerEntry: Decodable {
    struct User: Decodable { let id: Int64; let login: String }
    let user: User
    let starredAt: Date

    enum CodingKeys: String, CodingKey {
        case user
        case starredAt = "starred_at"
    }
}

private struct AuthorRepository: Decodable {
    let id: Int64
    let owner: GitHubRepoResponse.Owner
    let stargazersCount: Int64
    let `private`: Bool

    enum CodingKeys: String, CodingKey {
        case id, owner, `private`
        case stargazersCount = "stargazers_count"
    }
}

extension GitHubClient {
    struct StargazerObservation {
        let snapshot: StargazerSnapshot
        let dates: [Date]
        let repository: String
        let reportedCount: Int
    }

    func freshStargazerMetadata(owner: String, name: String, token: String) async throws -> GitHubHTTPResult<GitHubRepoResponse> {
        try await request(path: Self.path("/repos/\(owner)/\(name)", queryItems: []),
                          etag: nil, requiresAuth: true, optionalAuthToken: token, strict: true)
    }

    func observeStargazers(
        metadata: GitHubHTTPResult<GitHubRepoResponse>,
        viewerID: Int64,
        credentialSource: String,
        token: String,
        verifyDirectoryAccess: (Int64, String) async throws -> Bool
    ) async throws -> StargazerObservation {
        let start = Date()
        let before = metadata.value
        let slug = before.fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard let repositoryID = before.id, repositoryID > 0, viewerID > 0,
              slug.count == 2, slug.allSatisfy({ Self.validRepositoryComponent(String($0)) }),
              before.stargazersCount >= 0 else { throw StargazerCheckError.inconsistent }
        let visibility = before.visibility ?? (before.private ? "private" : "public")
        let count = before.stargazersCount
        let pages = max(1, count / 100 + (count.isMultiple(of: 100) ? 0 : 1))
        let required = pages == 1 ? 2 : pages * 2 + 1
        var remainingRequests = required
        var latestRate = metadata.rateLimitState
        let firstPage = "/repos/\(before.fullName)/stargazers"
        let resources = [firstPage, "/repositories/\(repositoryID)/stargazers"]
        try Self.checkBudget(metadata.rateLimitState, needed: required)

        func walk() async throws -> ([StargazerAccount], [Date]) {
            var accounts: [StargazerAccount] = []
            var dates: [Date] = []
            var ids: Set<Int64> = []
            var path = "\(firstPage)?per_page=100"
            for page in 1...pages {
                let result: GitHubHTTPResult<[StargazerEntry]> = try await request(
                    path: path, etag: nil, requiresAuth: true, accept: "application/vnd.github.star+json",
                    optionalAuthToken: token, strict: true
                )
                remainingRequests -= 1
                latestRate = result.rateLimitState ?? latestRate
                try Self.checkBudget(result.rateLimitState, needed: remainingRequests)
                let readAt = Date()
                let size = result.value.count
                guard page == pages ? ((1...100).contains(size) || (count == 0 && size == 0)) : size == 100
                else { throw StargazerCheckError.inconsistent }
                for entry in result.value {
                    guard entry.user.id > 0, Self.validLogin(entry.user.login), ids.insert(entry.user.id).inserted else {
                        throw StargazerCheckError.inconsistent
                    }
                    accounts.append(StargazerAccount(id: entry.user.id, login: entry.user.login, seenAt: readAt))
                    dates.append(entry.starredAt)
                }
                let next = try Self.nextPage(result.linkHeader, current: page, resources: resources,
                                             query: ["per_page": "100"], last: pages)
                guard (next != nil) == (page < pages) else { throw StargazerCheckError.inconsistent }
                if let next { path = next }
            }
            return (accounts, dates)
        }

        var (accounts, dates) = try await walk()
        // A nonempty terminal page can disagree with the aggregate count. Require
        // a second matching walk even for a one-page display-only list.
        if pages > 1 || accounts.count != count {
            if pages == 1 {
                remainingRequests += 1
                try Self.checkBudget(latestRate, needed: remainingRequests)
            }
            let firstIDs = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.login) })
            (accounts, dates) = try await walk()
            guard firstIDs == Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.login) }) else {
                throw StargazerCheckError.inconsistent
            }
        }

        let after = try await freshStargazerMetadata(owner: String(slug[0]), name: String(slug[1]), token: token).value
        guard let afterID = after.id else { throw StargazerCheckError.inconsistent }
        guard afterID == repositoryID, after.private == before.private,
              (after.visibility ?? (after.private ? "private" : "public")) == visibility
        else { throw StargazerCheckError.scopeChanged }
        guard after.stargazersCount == count else { throw StargazerCheckError.inconsistent }
        if accounts.isEmpty, after.owner?.id != viewerID, after.permissions?.verifiesAccess != true {
            guard try await verifyDirectoryAccess(repositoryID, visibility) else { throw StargazerCheckError.accessUnverified }
        }
        let scope = StargazerScope(repositoryID: repositoryID, viewerID: viewerID,
                                   credentialSource: credentialSource, visibility: visibility)
        accounts.sort { $0.login.localizedStandardCompare($1.login) == .orderedAscending }
        return StargazerObservation(snapshot: StargazerSnapshot(scope: scope, startedAt: start,
                         completedAt: Date(), accounts: accounts), dates: dates.sorted(), repository: after.fullName,
                         reportedCount: count)
    }

    /// Visits directory pages until the authenticated account's explicit access is established.
    func stargazerDirectoryContains(token: String, repositoryID: Int64, visibility: String, seen: inout Set<Int64>) async throws -> Bool {
        let resource = "/user/repos"
        let visibility = visibility == "public" ? "public" : "private"
        let query = ["visibility": visibility, "affiliation": "owner,collaborator,organization_member", "per_page": "100"]
        var next: String? = Self.path(resource, queryItems: query.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        })
        var page = 1
        while let path = next {
            let result: GitHubHTTPResult<[GitHubRepoSummary]> = try await request(path: path, etag: nil,
                requiresAuth: true, optionalAuthToken: token, strict: true)
            seen.formUnion(result.value.map { Int64($0.id) })
            if seen.contains(repositoryID) { return true }
            next = try Self.nextPage(result.linkHeader, current: page, resources: [resource], query: query)
            page += 1
        }
        return false
    }

    func fetchStargazerAuthor(id: Int64, token: String) async throws -> GitHubStargazerAuthor {
        let result: GitHubHTTPResult<GitHubStargazerAuthor> = try await request(
            path: "/user/\(id)", etag: nil, requiresAuth: true, optionalAuthToken: token, strict: true)
        guard result.value.id == id, Self.validLogin(result.value.login) else { throw StargazerCheckError.inconsistent }
        return result.value
    }

    func fetchStarsReceived(author: GitHubStargazerAuthor, token: String) async throws -> Int64 {
        let resource = Self.path("/users/\(author.login)/repos", queryItems: [])
        let query = ["type": "owner", "per_page": "100"]
        var next: String? = "\(resource)?type=owner&per_page=100"
        var seen: Set<Int64> = []
        var total: Int64 = 0
        var page = 1
        while let path = next {
            let result: GitHubHTTPResult<[AuthorRepository]> = try await request(path: path, etag: nil,
                requiresAuth: true, optionalAuthToken: token, strict: true)
            for repo in result.value {
                let (sum, overflow) = total.addingReportingOverflow(repo.stargazersCount)
                guard repo.id > 0, repo.owner.id == author.id, !repo.private, repo.stargazersCount >= 0,
                      !overflow, seen.insert(repo.id).inserted else { throw StargazerCheckError.inconsistent }
                total = sum
            }
            next = try Self.nextPage(result.linkHeader, current: page,
                                     resources: [resource, "/user/\(author.id)/repos"], query: query)
            if next != nil, result.value.count != 100 { throw StargazerCheckError.inconsistent }
            page += 1
        }
        guard author.publicRepos.map({ $0 == seen.count }) ?? !seen.isEmpty else { throw StargazerCheckError.inconsistent }
        return total
    }

    func fetchStargazerSocialLinks(author: GitHubStargazerAuthor, token: String) async throws -> [StargazerProfileLink] {
        struct Account: Decodable { let url: String }
        let resource = Self.path("/users/\(author.login)/social_accounts", queryItems: [])
        var next: String? = "\(resource)?per_page=100"
        var links: [StargazerProfileLink] = []
        var page = 1
        while let path = next {
            let result: GitHubHTTPResult<[Account]> = try await request(path: path, etag: nil, requiresAuth: true,
                                                                      optionalAuthToken: token, strict: true)
            links.append(contentsOf: result.value.compactMap { StargazerProfileLink.site($0.url) })
            next = try Self.nextPage(result.linkHeader, current: page,
                                     resources: [resource, "/user/\(author.id)/social_accounts"], query: ["per_page": "100"])
            page += 1
        }
        guard !links.isEmpty else { return [] }
        let verified = try await fetchStargazerAuthor(id: author.id, token: token)
        guard verified.login.caseInsensitiveCompare(author.login) == .orderedSame else { throw StargazerCheckError.inconsistent }
        return links
    }

    static func checkBudget(_ rate: RateLimitState?, needed: Int) throws {
        if let rate, rate.isLimited { throw GitHubError.rateLimited(rate) }
        if let remaining = rate?.remaining, remaining < needed { throw StargazerCheckError.insufficientBudget }
    }

    static func validLogin(_ value: String) -> Bool {
        let base = value.hasSuffix("[bot]") ? value.dropLast(5) : value[...]
        return !base.isEmpty && base.utf8.allSatisfy { asciiNameByte($0) }
    }

    static func validRepositoryComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.allSatisfy { asciiNameByte($0) || $0 == 46 }
    }

    private static func asciiNameByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
    }

    static func nextPage(_ header: String?, current: Int, resources: [String], query: [String: String],
                         last: Int? = nil) throws -> String? {
        guard let header else { return nil }
        var next: String?
        for entry in linkHeaderEntries(from: header) {
            guard entry.first == "<", let end = entry.firstIndex(of: ">") else { throw StargazerCheckError.inconsistent }
            let parameters = entry[entry.index(after: end)...].split(separator: ";").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let relations = parameters.filter { $0.hasPrefix("rel=") }
            guard relations.count == 1, let relation = relations.first else { throw StargazerCheckError.inconsistent }
            guard relation == "rel=\"next\"" || relation == "rel=\"last\"" else { continue }
            guard let url = URLComponents(string: String(entry[entry.index(after: entry.startIndex)..<end])),
                  url.scheme == "https", url.host?.lowercased() == "api.github.com", url.port == nil,
                  url.user == nil, url.password == nil, url.fragment == nil,
                  resources.contains(where: { $0.caseInsensitiveCompare(url.path) == .orderedSame }),
                  let items = url.queryItems,
                  Set(items.map(\.name)).count == items.count,
                  let pageNumber = items.first(where: { $0.name == "page" })?.value.flatMap(Int.init),
                  items.count == query.count + 1,
                  query.allSatisfy({ key, value in items.contains(URLQueryItem(name: key, value: value)) })
            else { throw StargazerCheckError.inconsistent }
            if relation == "rel=\"next\"" {
                guard next == nil, pageNumber == current + 1, let encoded = url.percentEncodedQuery else {
                    throw StargazerCheckError.inconsistent
                }
                next = "\(url.percentEncodedPath)?\(encoded)"
            } else if pageNumber < current || (last != nil && pageNumber != last) {
                throw StargazerCheckError.inconsistent
            }
        }
        return next
    }
}
