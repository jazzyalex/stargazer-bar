import Foundation

struct RateLimitState: Codable, Equatable {
    var limit: Int?
    var remaining: Int?
    var resetAt: Date?

    var isLimited: Bool {
        guard remaining == 0 else { return false }
        if let resetAt {
            return resetAt > Date()
        }
        return true
    }

    static func from(headers: [AnyHashable: Any]) -> RateLimitState? {
        let remaining = intHeader("X-RateLimit-Remaining", headers: headers)
        let limit = intHeader("X-RateLimit-Limit", headers: headers)
        let resetAt: Date?
        if let resetEpoch = intHeader("X-RateLimit-Reset", headers: headers) {
            resetAt = Date(timeIntervalSince1970: TimeInterval(resetEpoch))
        } else {
            resetAt = nil
        }
        guard remaining != nil || limit != nil || resetAt != nil else { return nil }
        return RateLimitState(limit: limit, remaining: remaining, resetAt: resetAt)
    }

    private static func intHeader(_ name: String, headers: [AnyHashable: Any]) -> Int? {
        for (key, value) in headers where String(describing: key).caseInsensitiveCompare(name) == .orderedSame {
            return Int(String(describing: value))
        }
        return nil
    }
}

