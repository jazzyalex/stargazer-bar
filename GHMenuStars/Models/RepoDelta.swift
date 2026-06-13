struct RepoDelta: Codable, Equatable {
    var starsDelta: Int
    var downloadsDelta: Int
    var forksDelta: Int

    private enum CodingKeys: String, CodingKey {
        case starsDelta
        case downloadsDelta
        case forksDelta
    }

    var hasStarIncrease: Bool { starsDelta > 0 }
    var hasCelebrationIncrease: Bool { starsDelta > 0 || downloadsDelta > 0 }

    init(starsDelta: Int, downloadsDelta: Int, forksDelta: Int = 0) {
        self.starsDelta = starsDelta
        self.downloadsDelta = downloadsDelta
        self.forksDelta = forksDelta
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        starsDelta = try container.decode(Int.self, forKey: .starsDelta)
        downloadsDelta = try container.decode(Int.self, forKey: .downloadsDelta)
        forksDelta = try container.decodeIfPresent(Int.self, forKey: .forksDelta) ?? 0
    }
}
