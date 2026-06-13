import Combine
import Foundation

@MainActor
final class AnimationCoordinator: ObservableObject {
    @Published private(set) var isAnimating = false
    @Published private(set) var activeMode: CelebrationMode = .off
    private var pulseTask: Task<Void, Never>?

    func pulse(mode: CelebrationMode) {
        guard mode != .off else { return }
        pulseTask?.cancel()
        activeMode = mode
        isAnimating = true
        pulseTask = Task {
            try? await Task.sleep(nanoseconds: mode.pulseDuration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.isAnimating = false
                self.activeMode = .off
            }
        }
    }
}
