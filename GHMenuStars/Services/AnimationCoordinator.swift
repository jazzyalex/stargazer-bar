import Combine
import Foundation

@MainActor
final class AnimationCoordinator: ObservableObject {
    @Published private(set) var isAnimating = false

    func pulse() {
        isAnimating = true
        Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            await MainActor.run {
                self.isAnimating = false
            }
        }
    }
}

