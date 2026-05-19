import AppKit
import SwiftUI

private enum GitHubAuthViewState: Equatable {
    case disconnected
    case requestingCode
    case waitingForAuthorization
    case connected
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .requestingCode, .waitingForAuthorization:
            return true
        case .disconnected, .connected, .failed:
            return false
        }
    }
}

struct SettingsView: View {
    static let contentWidth: CGFloat = 460
    static let contentHeight: CGFloat = 620

    @ObservedObject var repoStore: TrackedRepoStore
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var updaterController: UpdaterController
    let gitHubClient: GitHubClient

    @State private var repoText = ""
    @State private var validationMessage: SettingsMessage?
    @State private var isValidating = false
    @State private var authState: GitHubAuthViewState = .disconnected
    @State private var deviceCode: DeviceCodeResponse?
    @State private var publicRepos: [GitHubRepoSummary] = []
    @State private var isLoadingRepos = false
    @State private var hasLoadedPublicRepos = false
    @State private var repoFilter = ""

    init(
        repoStore: TrackedRepoStore,
        settingsStore: SettingsStore,
        gitHubClient: GitHubClient,
        updaterController: UpdaterController
    ) {
        self._repoStore = ObservedObject(wrappedValue: repoStore)
        self._settingsStore = ObservedObject(wrappedValue: settingsStore)
        self._updaterController = ObservedObject(wrappedValue: updaterController)
        self.gitHubClient = gitHubClient
    }

    var body: some View {
        Form {
            Section("Repository") {
                if let tracked = repoStore.trackedRepos.first {
                    LabeledContent {
                        Text(RepoDeltaFormatter.metricLine(label: "★", value: tracked.lastStars, delta: repoStore.lastDelta?.starsDelta))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                    } label: {
                        Text(tracked.displayName)
                            .font(.callout)
                    }
                } else {
                    Text("No repository tracked yet.")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    TextField("owner/repo", text: $repoText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { validateManualRepo() }

                    Button {
                        validateManualRepo()
                    } label: {
                        if isValidating {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Track")
                        }
                    }
                    .disabled(isValidating || repoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let validationMessage {
                    SettingsMessageView(message: validationMessage)
                }
            }

            Section("Refresh") {
                Picker("Poll interval", selection: Binding(
                    get: { settingsStore.settings.refreshInterval },
                    set: { newValue in settingsStore.update { $0.refreshInterval = newValue } }
                )) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if let state = repoStore.rateLimitState, state.isLimited {
                    SettingsMessageView(message: .warning("Rate limit active — retrying \(RelativeDateTimeFormatter.menu.string(for: state.resetAt) ?? "later")."))
                } else if let summary = lastCheckedSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Notifications") {
                Toggle("Notify on star increases", isOn: Binding(
                    get: { settingsStore.settings.notifyOnStarIncrease },
                    set: { newValue in settingsStore.update { $0.notifyOnStarIncrease = newValue } }
                ))
                Toggle("Play sound", isOn: Binding(
                    get: { settingsStore.settings.playSoundOnStarIncrease },
                    set: { newValue in settingsStore.update { $0.playSoundOnStarIncrease = newValue } }
                ))
                Toggle("Animate menu-bar counter", isOn: Binding(
                    get: { settingsStore.settings.animateOnStarIncrease },
                    set: { newValue in settingsStore.update { $0.animateOnStarIncrease = newValue } }
                ))
            }

            Section("GitHub") {
                HStack(spacing: 10) {
                    Button(authButtonTitle) { startDeviceFlow() }
                        .disabled(authState.isBusy)
                    if authState == .connected {
                        Button {
                            loadPublicRepos()
                        } label: {
                            if isLoadingRepos {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Load Public Repos")
                            }
                        }
                        .disabled(isLoadingRepos)
                    }
                    Spacer()
                    authStateBadge
                }

                if let deviceCode {
                    DeviceCodePanel(deviceCode: deviceCode)
                }

                if case .failed(let message) = authState {
                    SettingsMessageView(message: .warning(message))
                }

                if !publicRepos.isEmpty {
                    TextField("Filter", text: $repoFilter)
                        .textFieldStyle(.roundedBorder)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(filteredRepos.prefix(50)) { repo in
                                Button {
                                    track(owner: repo.owner.login, name: repo.name, source: .oauth)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "book.closed")
                                            .foregroundStyle(.secondary)
                                        Text(repo.fullName)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }

            Section("App") {
                Toggle("Show Dock icon", isOn: Binding(
                    get: { !settingsStore.settings.hideDockIcon },
                    set: { newValue in settingsStore.update { $0.hideDockIcon = !newValue } }
                ))
            }

            Section("Updates") {
                Toggle("Automatic updates", isOn: Binding(
                    get: { updaterController.autoUpdateEnabled },
                    set: { updaterController.setAutoUpdateEnabled($0) }
                ))
                .disabled(!updaterController.canChangeAutoUpdatePreference)

                HStack {
                    if updaterController.hasGentleReminder {
                        Label("An update is available.", systemImage: "arrow.down.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Text("Sparkle, EdDSA-signed and notarized.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Now") {
                        updaterController.checkForUpdates(nil)
                    }
                    .controlSize(.small)
                    .disabled(!updaterController.canRequestUpdateCheck)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.contentWidth, height: Self.contentHeight)
        .onAppear {
            if repoText.isEmpty, let repo = repoStore.trackedRepos.first {
                repoText = repo.displayName
            }
            if KeychainTokenStore.hasGitHubOAuthToken() {
                authState = .connected
            }
        }
    }

    // MARK: - Helpers

    private var lastCheckedSummary: String? {
        guard let repo = repoStore.trackedRepos.first,
              let checkedAt = repo.lastCheckedAt,
              let relative = RelativeDateTimeFormatter.menu.string(for: checkedAt)
        else { return nil }
        return "Last checked \(relative)."
    }

    private var authButtonTitle: String {
        switch authState {
        case .requestingCode:        return "Requesting…"
        case .waitingForAuthorization: return "Waiting…"
        case .connected:             return "Reconnect GitHub"
        case .disconnected, .failed: return "Connect GitHub"
        }
    }

    private var authStateBadge: some View {
        let text: String
        let symbol: String
        let tint: Color
        switch authState {
        case .connected:
            text = "Connected"; symbol = "checkmark.circle.fill"; tint = .green
        case .requestingCode, .waitingForAuthorization:
            text = "Connecting"; symbol = "clock"; tint = .secondary
        case .failed:
            text = "Error"; symbol = "exclamationmark.circle"; tint = .orange
        case .disconnected:
            text = "Optional"; symbol = "circle"; tint = .secondary
        }
        return Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(tint)
    }

    private var filteredRepos: [GitHubRepoSummary] {
        let query = repoFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return publicRepos }
        return publicRepos.filter { $0.fullName.lowercased().contains(query) }
    }

    private func validateManualRepo() {
        let input = repoText
        do {
            let parsed = try RepoURLParser.parse(input)
            validateRepo(owner: parsed.owner, name: parsed.name, source: .manual)
        } catch {
            validationMessage = .warning(GitHubError.userMessage(for: error))
        }
    }

    private func validateRepo(owner: String, name: String, source: RepoSource) {
        isValidating = true
        validationMessage = nil
        Task {
            do {
                let repoResult = try await gitHubClient.fetchRepo(owner: owner, name: name, etag: nil)
                guard !repoResult.value.private else { throw GitHubError.notFoundOrPrivate }
                let releasesResult = try await gitHubClient.fetchReleases(owner: owner, name: name, etag: nil)
                let downloads = ReleaseDownloadAggregator.totalDownloads(from: releasesResult.value)
                await MainActor.run {
                    let repo = TrackedRepo(
                        owner: owner,
                        name: name,
                        source: source,
                        lastStars: repoResult.value.stargazersCount,
                        lastDownloads: downloads,
                        lastCheckedAt: Date(),
                        lastSuccessfulCheckAt: Date(),
                        etagRepo: repoResult.etag,
                        etagReleases: releasesResult.etag
                    )
                    repoStore.setTrackedRepo(repo)
                    validationMessage = .success("Tracking \(owner)/\(name).")
                    isValidating = false
                }
            } catch {
                await MainActor.run {
                    validationMessage = .warning(GitHubError.userMessage(for: error))
                    isValidating = false
                }
            }
        }
    }

    private func track(owner: String, name: String, source: RepoSource) {
        repoText = "\(owner)/\(name)"
        validateRepo(owner: owner, name: name, source: source)
    }

    private func startDeviceFlow() {
        guard let clientID = GitHubOAuthConfiguration.clientID(settings: settingsStore.settings) else {
            authState = .failed("GitHub connection is not configured in this build.")
            return
        }

        authState = .requestingCode
        deviceCode = nil
        Task {
            do {
                let response = try await DeviceFlowClient().requestDeviceCode(clientID: clientID)
                await MainActor.run {
                    deviceCode = response
                    authState = .waitingForAuthorization
                    if let url = URL(string: response.verificationURI) {
                        NSWorkspace.shared.open(url)
                    }
                }
                let token = try await DeviceFlowClient().pollForToken(
                    clientID: clientID,
                    deviceCode: response.deviceCode,
                    interval: response.interval
                )
                try KeychainTokenStore.gitHubOAuthStore().saveToken(token.accessToken)
                await MainActor.run {
                    authState = .connected
                    deviceCode = nil
                    loadPublicRepos()
                }
            } catch {
                await MainActor.run {
                    authState = .failed(GitHubError.userMessage(for: error))
                }
            }
        }
    }

    private func loadPublicRepos() {
        isLoadingRepos = true
        hasLoadedPublicRepos = false
        Task {
            do {
                let repos = try await gitHubClient.fetchAccessiblePublicRepos()
                await MainActor.run {
                    publicRepos = repos
                    hasLoadedPublicRepos = true
                    isLoadingRepos = false
                }
            } catch {
                await MainActor.run {
                    authState = .failed(GitHubError.userMessage(for: error))
                    isLoadingRepos = false
                }
            }
        }
    }
}

private struct DeviceCodePanel: View {
    let deviceCode: DeviceCodeResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(deviceCode.userCode)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(deviceCode.userCode, forType: .string)
                }
                .controlSize(.small)
                Button("Open GitHub") {
                    if let url = URL(string: deviceCode.verificationURI) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                Spacer()
            }
            Text(deviceCode.verificationURI)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}

private enum SettingsMessage: Equatable {
    case info(String)
    case success(String)
    case warning(String)

    var text: String {
        switch self {
        case .info(let t), .success(let t), .warning(let t): return t
        }
    }
    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        }
    }
    var color: Color {
        switch self {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        }
    }
}

private struct SettingsMessageView: View {
    let message: SettingsMessage
    var body: some View {
        Label(message.text, systemImage: message.symbol)
            .font(.caption)
            .foregroundStyle(message.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
