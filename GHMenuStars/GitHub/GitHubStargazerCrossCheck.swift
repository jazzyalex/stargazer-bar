import Foundation

private struct StargazerGraphRequest: Encodable {
    struct Variables: Encodable {
        let owner: String
        let name: String
        let after: String?
    }

    let variables: Variables
    let query = """
    query($owner: String!, $name: String!, $after: String) {
      viewer { databaseId }
      repository(owner: $owner, name: $name) {
        databaseId nameWithOwner visibility viewerPermission stargazerCount
        stargazers(first: 100, after: $after, orderBy: {field: STARRED_AT, direction: ASC}) {
          totalCount nodes { databaseId } pageInfo { hasNextPage endCursor }
        }
      }
    }
    """
}

private struct StargazerGraphResponse: Decodable {
    struct Account: Decodable { let databaseId: Int64? }
    struct Connection: Decodable {
        struct PageInfo: Decodable {
            let hasNextPage: Bool
            let endCursor: String?
        }

        let totalCount: Int
        let nodes: [Account?]
        let pageInfo: PageInfo
    }
    struct Repository: Decodable {
        let databaseId: Int64?
        let nameWithOwner: String
        let visibility: String
        let viewerPermission: String?
        let stargazerCount: Int
        let stargazers: Connection
    }
    struct Payload: Decodable {
        let viewer: Account
        let repository: Repository?
    }
    struct GraphError: Decodable {}

    let data: Payload?
    let errors: [GraphError]?
}

private struct StargazerHistoryWeek: Decodable {
    let week: Int64
    let total: Int
    let days: [Int]
}

extension GitHubClient {
    /// Limit the fallback to the public repository investigated with all three API surfaces.
    static let agentSessionsRepositoryID: Int64 = 1_060_421_643

    func corroborateAgentSessionsStargazers(
        _ observation: StargazerObservation, createdAt: Date?, token: String
    ) async throws -> StargazerSnapshot {
        let rest = observation.snapshot
        let slug = observation.repository.split(separator: "/", omittingEmptySubsequences: false)
        guard rest.scope.requiresStarHistoryCrossCheck, let createdAt,
              slug.count == 2, Self.validRepositoryComponent(String(slug[0])),
              Self.validRepositoryComponent(String(slug[1])) else {
            throw StargazerCheckError.inconsistent
        }
        let owner = String(slug[0])
        let name = String(slug[1])
        let expectedIDs = Set(rest.accounts.map(\.id))
        try await verifyGraphStargazers(observation, expectedIDs: expectedIDs, owner: owner, name: name, token: token)
        try await verifyStarHistory(repository: observation.repository, id: rest.scope.repositoryID,
                                    createdAt: createdAt, checkedAt: rest.completedAt, count: expectedIDs.count, token: token)

        let metadata = try await freshStargazerMetadata(owner: owner, name: name, token: token).value
        guard let repoID = metadata.id else { throw StargazerCheckError.inconsistent }
        guard repoID == rest.scope.repositoryID, !metadata.private,
              (metadata.visibility ?? "public") == rest.scope.visibility else { throw StargazerCheckError.scopeChanged }
        guard metadata.stargazersCount == observation.reportedCount,
              metadata.createdAt == createdAt else { throw StargazerCheckError.inconsistent }
        return StargazerSnapshot(scope: rest.scope, startedAt: rest.startedAt, completedAt: Date(),
            accounts: rest.accounts, reportedStarCount: observation.reportedCount)
    }

    private func verifyGraphStargazers(
        _ observation: StargazerObservation, expectedIDs: Set<Int64>, owner: String, name: String, token: String
    ) async throws {
        let scope = observation.snapshot.scope
        let pages = max(1, expectedIDs.count / 100 + (expectedIDs.count.isMultiple(of: 100) ? 0 : 1))
        var permission: String?
        var seen: Set<Int64> = []
        var cursors: Set<String> = []
        var after: String?
        for page in 1...pages {
            let body = try JSONEncoder().encode(StargazerGraphRequest(
                variables: .init(owner: owner, name: name, after: after)))
            let result: GitHubHTTPResult<StargazerGraphResponse> = try await request(
                path: "/graphql", etag: nil, requiresAuth: true, optionalAuthToken: token, strict: true, jsonBody: body)
            guard result.value.errors?.isEmpty != false,
                  let data = result.value.data, data.viewer.databaseId == scope.viewerID,
                  let repository = data.repository, repository.databaseId == scope.repositoryID,
                  repository.nameWithOwner.caseInsensitiveCompare(observation.repository) == .orderedSame,
                  repository.visibility.lowercased() == scope.visibility, let role = repository.viewerPermission,
                  permission == nil || permission == role,
                  repository.stargazerCount == observation.reportedCount,
                  repository.stargazers.totalCount == observation.reportedCount else {
                throw StargazerCheckError.inconsistent
            }
            permission = role
            let connection = repository.stargazers
            let more = page < pages
            let expectedSize = more ? 100 : expectedIDs.count - (page - 1) * 100
            guard connection.nodes.count == expectedSize, connection.pageInfo.hasNextPage == more else {
                throw StargazerCheckError.inconsistent
            }
            for node in connection.nodes {
                guard let id = node?.databaseId, expectedIDs.contains(id), seen.insert(id).inserted else {
                    throw StargazerCheckError.inconsistent
                }
            }
            if more {
                guard let cursor = connection.pageInfo.endCursor, !cursor.isEmpty, cursors.insert(cursor).inserted else {
                    throw StargazerCheckError.inconsistent
                }
                after = cursor
                try Self.checkBudget(result.rateLimitState, needed: pages - page)
            }
        }
        guard seen == expectedIDs else { throw StargazerCheckError.inconsistent }
    }

    private func verifyStarHistory(
        repository: String, id: Int64, createdAt: Date, checkedAt: Date, count: Int, token: String
    ) async throws {
        let week: TimeInterval = 7 * 86_400
        let resource = "/repos/\(repository)/stargazers/history"
        var next: String? = "\(resource)?per_page=30"
        var page = 1
        var previous: Date?
        var total = 0
        while let path = next {
            // The history endpoint supports at most 100 pages.
            guard page <= 100 else { throw StargazerCheckError.inconsistent }
            let result: GitHubHTTPResult<[StargazerHistoryWeek]> = try await request(
                path: path, etag: nil, requiresAuth: true, optionalAuthToken: token, strict: true)
            try Self.checkBudget(result.rateLimitState, needed: 1)
            guard (1...30).contains(result.value.count) else { throw StargazerCheckError.inconsistent }

            for bucket in result.value {
                let start = Date(timeIntervalSince1970: TimeInterval(bucket.week))
                guard start <= checkedAt, start.addingTimeInterval(week) > createdAt,
                      previous.map({ $0.timeIntervalSince(start) == week }) ?? (start.addingTimeInterval(week) > checkedAt),
                      bucket.total >= 0, bucket.total <= count - total, bucket.days.count == 7 else {
                    throw StargazerCheckError.inconsistent
                }
                var remainder = bucket.total
                for day in bucket.days {
                    guard day >= 0, day <= remainder else { throw StargazerCheckError.inconsistent }
                    remainder -= day
                }
                guard remainder == 0 else { throw StargazerCheckError.inconsistent }
                total += bucket.total
                previous = start
            }
            next = try Self.nextPage(result.linkHeader, current: page,
                resources: [resource, "/repositories/\(id)/stargazers/history"], query: ["per_page": "30"])
            if next != nil, result.value.count != 30 { throw StargazerCheckError.inconsistent }
            page += 1
        }
        guard total == count, let earliest = previous, earliest <= createdAt else {
            throw StargazerCheckError.inconsistent
        }
    }
}
