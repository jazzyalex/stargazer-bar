import Foundation

enum StargazerHistoryError: Error { case invalidRecord }

struct StargazerHistory: Codable, Equatable {
    let version: Int
    let snapshot: StargazerSnapshot
    let events: [StargazerDisappearance]
    let continuityBroken: Bool
}

@MainActor
struct StargazerHistoryStore {
    let directory: URL

    static var standard: Self {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(directory: support.appendingPathComponent("com.jazzyalex.StargazerBar/Stargazers", isDirectory: true))
    }

    func read(_ repoID: UUID) throws -> StargazerHistory? {
        let data: Data
        do {
            data = try Data(contentsOf: location(repoID))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        guard let record = try? JSONDecoder().decode(StargazerHistory.self, from: data),
              record.version == 1, Self.valid(record.snapshot),
              record.events.allSatisfy({
                  $0.account.id > 0 && GitHubClient.validLogin($0.account.login) && $0.account.seenAt <= $0.missingAt
              }) else { throw StargazerHistoryError.invalidRecord }
        return record
    }

    func accept(_ snapshot: StargazerSnapshot, repository: String, repoID: UUID) throws -> StargazerHistory {
        let previous = try read(repoID)
        guard Self.valid(snapshot),
              !snapshot.scope.requiresStarHistoryCrossCheck || snapshot.reportedStarCount != nil,
              previous.map({ $0.snapshot.completedAt < snapshot.startedAt }) ?? true else {
            throw StargazerCheckError.inconsistent
        }
        var events = previous?.events ?? []
        if let previous, !previous.continuityBroken, previous.snapshot.scope == snapshot.scope {
            let currentIDs = Set(snapshot.accounts.map(\.id))
            events.append(contentsOf: previous.snapshot.accounts.filter { !currentIDs.contains($0.id) }.map {
                StargazerDisappearance(id: UUID(), scope: snapshot.scope, repository: repository,
                                       account: $0, missingAt: snapshot.completedAt)
            })
        }
        let cutoff = snapshot.completedAt.addingTimeInterval(-90 * 86_400)
        let retained = events.filter { $0.missingAt >= cutoff }.sorted {
            if $0.missingAt != $1.missingAt { return $0.missingAt > $1.missingAt }
            return $0.account.id < $1.account.id
        }
        let record = StargazerHistory(version: 1, snapshot: snapshot, events: Array(retained.prefix(2_000)),
                                      continuityBroken: false)
        try save(record, repoID: repoID)
        return record
    }

    func markContinuityBreak(_ repoID: UUID) throws {
        guard let record = try read(repoID), !record.continuityBroken else { return }
        try save(StargazerHistory(version: record.version, snapshot: record.snapshot, events: record.events,
                                  continuityBroken: true), repoID: repoID)
    }

    func remove(_ repoID: UUID) throws {
        do {
            try FileManager.default.removeItem(at: location(repoID))
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
    }

    private func save(_ record: StargazerHistory, repoID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(record).write(to: location(repoID), options: .atomic)
    }

    private func location(_ repoID: UUID) -> URL {
        directory.appendingPathComponent(repoID.uuidString).appendingPathExtension("json")
    }

    private static func valid(_ snapshot: StargazerSnapshot) -> Bool {
        snapshot.scope.repositoryID > 0 && snapshot.scope.viewerID > 0 &&
            snapshot.startedAt <= snapshot.completedAt &&
            (snapshot.reportedStarCount.map {
                $0 >= 0 && snapshot.scope.requiresStarHistoryCrossCheck
            } ?? true) &&
            Set(snapshot.accounts.map(\.id)).count == snapshot.accounts.count &&
            snapshot.accounts.allSatisfy {
                $0.id > 0 && GitHubClient.validLogin($0.login) &&
                    (snapshot.startedAt...snapshot.completedAt).contains($0.seenAt)
            }
    }
}
