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
        default:
            return "GitHub request failed. Try again later."
        }
    }
}

struct GitHubRepoResponse: Decodable, Equatable {
    var fullName: String
    var stargazersCount: Int
    var `private`: Bool

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case stargazersCount = "stargazers_count"
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
}

final class GitHubClient {
    private let session: URLSession
    private let tokenProvider: () -> String?
    private let decoder: JSONDecoder

    init(session: URLSession = .shared, tokenProvider: @escaping () -> String? = { nil }) {
        self.session = session
        self.tokenProvider = tokenProvider
        self.decoder = JSONDecoder()
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

    private func request<T: Decodable>(path: String, etag: String?, requiresAuth: Bool) async throws -> GitHubHTTPResult<T> {
        guard let url = URL(string: "https://api.github.com\(path)") else {
            throw GitHubError.transport("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GHMenuStars/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let token = tokenProvider() {
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
                    nextPagePath: Self.nextPagePath(from: http)
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

    private static func nextPagePath(from response: HTTPURLResponse) -> String? {
        guard let linkHeader = response.value(forHTTPHeaderField: "Link") else { return nil }

        for rawLink in Self.linkHeaderEntries(from: linkHeader) {
            let parts = rawLink.split(separator: ";").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.contains(#"rel="next""#),
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
}
