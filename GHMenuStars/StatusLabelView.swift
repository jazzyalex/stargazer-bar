import SwiftUI

struct StatusLabelView: View {
    @ObservedObject var repoStore: TrackedRepoStore
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var animationCoordinator: AnimationCoordinator

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: displayValue.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(animationCoordinator.isAnimating ? celebrationColor : .primary)
                .shadow(
                    color: animationCoordinator.isAnimating ? celebrationColor.opacity(0.55) : .clear,
                    radius: animationCoordinator.isAnimating ? animationCoordinator.activeMode.glowRadius : 0
                )
            Text(displayValue.text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
            .padding(.horizontal, 6)
            .scaleEffect(animationCoordinator.isAnimating ? animationCoordinator.activeMode.pulseScale : 1.0)
            .animation(celebrationAnimation, value: animationCoordinator.isAnimating)
            .accessibilityLabel(displayValue.accessibilityLabel)
    }

    private var celebrationColor: Color {
        switch animationCoordinator.activeMode {
        case .off: return .primary
        case .subtle: return .yellow
        case .fun: return .orange
        }
    }

    private var celebrationAnimation: Animation {
        switch animationCoordinator.activeMode {
        case .off, .subtle:
            return .easeOut(duration: 0.22)
        case .fun:
            return .spring(response: 0.28, dampingFraction: 0.48)
        }
    }

    private var displayValue: MenuBarDisplayValue {
        MenuBarDisplayResolver.value(
            repos: repoStore.trackedRepos,
            settings: settingsStore.settings
        )
    }
}
