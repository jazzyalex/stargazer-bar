import SwiftUI

struct StatusLabelView: View {
    @ObservedObject var repoStore: TrackedRepoStore
    @ObservedObject var animationCoordinator: AnimationCoordinator

    var body: some View {
        Text(labelText)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .scaleEffect(animationCoordinator.isAnimating ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.18), value: animationCoordinator.isAnimating)
            .accessibilityLabel("GitHub stars \(labelText)")
    }

    private var labelText: String {
        guard let stars = repoStore.trackedRepos.first?.lastStars else { return "★ --" }
        return "★ \(NumberFormatter.menuInteger.string(from: NSNumber(value: stars)) ?? "\(stars)")"
    }
}

