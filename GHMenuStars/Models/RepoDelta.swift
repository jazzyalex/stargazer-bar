struct RepoDelta: Codable, Equatable {
    var starsDelta: Int
    var downloadsDelta: Int

    var hasStarIncrease: Bool { starsDelta > 0 }
}

