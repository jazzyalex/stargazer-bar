import SwiftUI

struct StatusLabelView: View {
    @ObservedObject var repoStore: TrackedRepoStore
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var animationCoordinator: AnimationCoordinator

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: displayValue.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(animationCoordinator.isAnimating ? .yellow : .primary)
            Text(displayValue.text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
            .padding(.horizontal, 6)
            .scaleEffect(animationCoordinator.isAnimating ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.18), value: animationCoordinator.isAnimating)
            .accessibilityLabel(displayValue.accessibilityLabel)
    }

    private var displayValue: MenuBarDisplayValue {
        MenuBarDisplayResolver.value(
            repos: repoStore.trackedRepos,
            settings: settingsStore.settings
        )
    }
}
