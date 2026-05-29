import AppKit
import Foundation

final class SoundService {
    private var generatedSounds: [StarSound: NSSound] = [:]

    func play(_ sound: StarSound = .glass) {
        guard !sound.isSilent else { return }
        if let systemSoundName = sound.systemSoundName {
            NSSound(named: NSSound.Name(systemSoundName))?.play()
            return
        }
        generatedSound(for: sound)?.play()
    }

    private func generatedSound(for sound: StarSound) -> NSSound? {
        if let existing = generatedSounds[sound] {
            return existing
        }
        guard let data = WaveSoundFactory.data(for: sound),
              let generated = NSSound(data: data) else {
            return nil
        }
        generatedSounds[sound] = generated
        return generated
    }
}

private enum WaveSoundFactory {
    private static let sampleRate = 44_100

    static func data(for sound: StarSound) -> Data? {
        switch sound {
        case .coinDrop:
            return waveData(notes: [
                Note(frequency: 1_320, duration: 0.07, volume: 0.55),
                Note(frequency: 1_760, duration: 0.10, volume: 0.45),
                Note(frequency: 2_200, duration: 0.06, volume: 0.35)
            ])
        case .tinyFanfare:
            return waveData(notes: [
                Note(frequency: 523.25, duration: 0.08, volume: 0.42),
                Note(frequency: 659.25, duration: 0.08, volume: 0.42),
                Note(frequency: 783.99, duration: 0.14, volume: 0.45)
            ])
        case .plucky:
            return waveData(notes: [
                Note(frequency: 392.00, duration: 0.06, volume: 0.48),
                Note(frequency: 0, duration: 0.025, volume: 0),
                Note(frequency: 587.33, duration: 0.07, volume: 0.42),
                Note(frequency: 0, duration: 0.025, volume: 0),
                Note(frequency: 493.88, duration: 0.09, volume: 0.40)
            ])
        case .glass, .pop, .ping, .tink, .hero, .funk, .bottle, .purr, .submarine, .silent:
            return nil
        }
    }

    private static func waveData(notes: [Note]) -> Data {
        let samples = notes.flatMap(samples(for:))
        var data = Data()
        let byteRate = UInt32(sampleRate * 2)
        let subchunk2Size = UInt32(samples.count * 2)
        let chunkSize = UInt32(36) + subchunk2Size

        data.append("RIFF".data(using: .ascii)!)
        data.appendLE(chunkSize)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(1))
        data.appendLE(UInt32(sampleRate))
        data.appendLE(byteRate)
        data.appendLE(UInt16(2))
        data.appendLE(UInt16(16))
        data.append("data".data(using: .ascii)!)
        data.appendLE(subchunk2Size)
        samples.forEach { data.appendLE($0) }
        return data
    }

    private static func samples(for note: Note) -> [Int16] {
        let count = max(1, Int(Double(sampleRate) * note.duration))
        guard note.frequency > 0, note.volume > 0 else {
            return Array(repeating: 0, count: count)
        }

        return (0..<count).map { index in
            let progress = Double(index) / Double(max(1, count - 1))
            let envelope = min(progress / 0.08, 1) * max(0, 1 - progress)
            let phase = 2 * Double.pi * note.frequency * Double(index) / Double(sampleRate)
            let harmonic = sin(phase) + 0.35 * sin(phase * 2)
            let value = harmonic * envelope * note.volume
            return Int16(max(-1, min(1, value)) * Double(Int16.max))
        }
    }
}

private struct Note {
    let frequency: Double
    let duration: Double
    let volume: Double
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendLE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }

    mutating func appendLE(_ value: Int16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<Int16>.size))
    }
}
