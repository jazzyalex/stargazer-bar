import Foundation

enum StarSound: String, Codable, CaseIterable, Identifiable {
    case glass
    case pop
    case ping
    case tink
    case hero
    case funk
    case bottle
    case purr
    case submarine
    case coinDrop
    case tinyFanfare
    case plucky
    case silent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .glass: return "Glass"
        case .pop: return "Pop"
        case .ping: return "Ping"
        case .tink: return "Tink"
        case .hero: return "Hero"
        case .funk: return "Funk"
        case .bottle: return "Bottle"
        case .purr: return "Purr"
        case .submarine: return "Submarine"
        case .coinDrop: return "Coin Drop"
        case .tinyFanfare: return "Tiny Fanfare"
        case .plucky: return "Plucky"
        case .silent: return "Silent"
        }
    }

    var systemSoundName: String? {
        switch self {
        case .glass: return "Glass"
        case .pop: return "Pop"
        case .ping: return "Ping"
        case .tink: return "Tink"
        case .hero: return "Hero"
        case .funk: return "Funk"
        case .bottle: return "Bottle"
        case .purr: return "Purr"
        case .submarine: return "Submarine"
        case .coinDrop, .tinyFanfare, .plucky, .silent: return nil
        }
    }

    var isSilent: Bool { self == .silent }
}

enum StarSoundThreshold: Int, Codable, CaseIterable, Identifiable {
    case one = 1
    case ten = 10
    case hundred = 100

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .one: return "1+ star"
        case .ten: return "10+ stars"
        case .hundred: return "100+ stars"
        }
    }

    func isMet(by delta: Int) -> Bool {
        delta >= rawValue
    }
}
