import Foundation

struct ParsedRepo: Equatable {
    var owner: String
    var name: String
}

enum RepoURLParser {
    static func parse(_ input: String) throws -> ParsedRepo {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitHubError.invalidRepositoryInput }

        if let url = URL(string: trimmed), let host = url.host?.lowercased(), host == "github.com" {
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { throw GitHubError.invalidRepositoryInput }
            return try validate(owner: parts[0], name: stripGitSuffix(parts[1]))
        }

        let normalized = trimmed
            .replacingOccurrences(of: "git@github.com:", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = normalized.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw GitHubError.invalidRepositoryInput }
        return try validate(owner: parts[0], name: stripGitSuffix(parts[1]))
    }

    private static func stripGitSuffix(_ value: String) -> String {
        value.hasSuffix(".git") ? String(value.dropLast(4)) : value
    }

    private static func validate(owner: String, name: String) throws -> ParsedRepo {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !owner.isEmpty, !name.isEmpty,
              owner.rangeOfCharacter(from: allowed.inverted) == nil,
              name.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw GitHubError.invalidRepositoryInput
        }
        return ParsedRepo(owner: owner, name: name)
    }
}

