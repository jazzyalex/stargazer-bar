import AppKit

final class SoundService {
    func play() {
        NSSound(named: NSSound.Name("Glass"))?.play()
    }
}

