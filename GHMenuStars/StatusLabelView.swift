import SwiftUI

struct StatusLabelView: View {
    @ObservedObject var repoStore: TrackedRepoStore
    @ObservedObject var animationCoordinator: AnimationCoordinator

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(animationCoordinator.isAnimating ? .yellow : .primary)
            Text(valueText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
            .padding(.horizontal, 6)
            .scaleEffect(animationCoordinator.isAnimating ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.18), value: animationCoordinator.isAnimating)
            .accessibilityLabel("GitHub stars \(accessibilityValue)")
    }

    private var valueText: String {
        guard let stars = repoStore.trackedRepos.first?.lastStars else { return "--" }
        return NumberFormatter.menuInteger.string(from: NSNumber(value: stars)) ?? "\(stars)"
    }

    private var accessibilityValue: String {
        guard let stars = repoStore.trackedRepos.first?.lastStars else { return "not configured" }
        return "\(stars)"
    }
}
