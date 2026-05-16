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
    static let contentWidth: CGFloat = 520
    static let contentHeight: CGFloat = 680

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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                header

                GroupBox("Repository") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let tracked = repoStore.trackedRepos.first {
                            CurrentRepoSummary(repo: tracked, delta: repoStore.lastDelta)
                        } else {
                            EmptyRepositoryView()
                        }

                        HStack(spacing: 8) {
                            TextField("owner/repo or https://github.com/owner/repo", text: $repoText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { validateManualRepo() }

                            Button {
                                validateManualRepo()
                            } label: {
                                if isValidating {
                                    ProgressView()
                                        .controlSize(.small)
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
                    .padding(8)
                }

                GroupBox("Refresh") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Poll interval", selection: Binding(
                            get: { settingsStore.settings.refreshInterval },
                            set: { newValue in settingsStore.update { $0.refreshInterval = newValue } }
                        )) {
                            ForEach(RefreshInterval.allCases) { interval in
                                Text(interval.displayName).tag(interval)
                            }
                        }
                        .pickerStyle(.segmented)

                        if let state = repoStore.rateLimitState, state.isLimited {
                            SettingsMessageView(message: .warning("GitHub rate limit active. The app will retry \(RelativeDateTimeFormatter.menu.string(for: state.resetAt) ?? "later")."))
                        } else {
                            Text(refreshSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }

                GroupBox("Notifications") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Notify on star increases", isOn: Binding(
                            get: { settingsStore.settings.notifyOnStarIncrease },
                            set: { newValue in settingsStore.update { $0.notifyOnStarIncrease = newValue } }
                        ))
                        Toggle("Play sound on star increases", isOn: Binding(
                            get: { settingsStore.settings.playSoundOnStarIncrease },
                            set: { newValue in settingsStore.update { $0.playSoundOnStarIncrease = newValue } }
                        ))
                        Toggle("Animate menu-bar counter on star increases", isOn: Binding(
                            get: { settingsStore.settings.animateOnStarIncrease },
                            set: { newValue in settingsStore.update { $0.animateOnStarIncrease = newValue } }
                        ))
                    }
                    .padding(8)
                }

                GroupBox("GitHub Account") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Public repositories you can access.", systemImage: "person.crop.circle.badge.checkmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            authStateBadge
                        }

                        HStack {
                            Button(authButtonTitle) {
                                startDeviceFlow()
                            }
                            .disabled(authState.isBusy)

                            Button {
                                loadPublicRepos()
                            } label: {
                                if isLoadingRepos {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Load Public Repos")
                                }
                            }
                            .disabled(isLoadingRepos || authState != .connected)
                        }

                        if let deviceCode {
                            DeviceCodePanel(deviceCode: deviceCode)
                        }

                        authMessageView

                        if !publicRepos.isEmpty {
                            TextField("Filter repositories", text: $repoFilter)
                                .textFieldStyle(.roundedBorder)
                        }

                        if isLoadingRepos {
                            ProgressView("Loading repositories…")
                                .controlSize(.small)
                        } else if authState == .connected && publicRepos.isEmpty {
                            SettingsMessageView(message: .info(hasLoadedPublicRepos ? "No public repositories returned for this account." : "Load public repositories from your GitHub account."))
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(filteredRepos.prefix(12)) { repo in
                                    Button {
                                        track(owner: repo.owner.login, name: repo.name, source: .oauth)
                                    } label: {
                                        HStack {
                                            Image(systemName: "book.closed")
                                            Text(repo.fullName)
                                        }
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                        }
                    }
                    .padding(8)
                }

                GroupBox("App") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Show Dock icon", isOn: Binding(
                            get: { !settingsStore.settings.hideDockIcon },
                            set: { newValue in settingsStore.update { $0.hideDockIcon = !newValue } }
                        ))

                        Divider()

                        if updaterController.hasGentleReminder {
                            SettingsMessageView(message: .success("An update is available."))
                        }

                        HStack(spacing: 12) {
                            Toggle("Auto-Update", isOn: Binding(
                                get: { updaterController.autoUpdateEnabled },
                                set: { updaterController.autoUpdateEnabled = $0 }
                            ))
                            .toggleStyle(.checkbox)
                            .disabled(updaterController.updater == nil)

                            Button("Check for Updates…") {
                                updaterController.checkForUpdates(nil)
                            }
                            .disabled(!updaterController.canCheckForUpdates)
                        }
                    }
                    .padding(8)
                }

                Text("Release downloads: total from latest 100 releases")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.contentWidth, height: Self.contentHeight, alignment: .topLeading)
        .onAppear {
            if repoText.isEmpty, let repo = repoStore.trackedRepos.first {
                repoText = repo.displayName
            }
            if KeychainTokenStore(service: "GHMenuStars.GitHubOAuth").hasToken() {
                authState = .connected
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIconFactory.iconImage(size: NSSize(width: 64, height: 64)))
                .resizable()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("GH Menu Stars")
                    .font(.title3.weight(.semibold))
                Text("Track a public repository from the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }

    private var refreshSummary: String {
        if let repo = repoStore.trackedRepos.first,
           let checkedAt = repo.lastCheckedAt {
            return "Last checked \(RelativeDateTimeFormatter.menu.string(for: checkedAt) ?? "recently")."
        }
        return "Checks start after you track a repository."
    }

    private var authButtonTitle: String {
        switch authState {
        case .requestingCode:
            return "Requesting…"
        case .waitingForAuthorization:
            return "Waiting…"
        case .connected:
            return "Reconnect GitHub"
        case .disconnected, .failed:
            return "Connect GitHub"
        }
    }

    private var authStateBadge: some View {
        let text: String
        let symbol: String
        switch authState {
        case .connected:
            text = "Connected"
            symbol = "checkmark.circle.fill"
        case .requestingCode, .waitingForAuthorization:
            text = "Connecting"
            symbol = "clock"
        case .failed:
            text = "Needs attention"
            symbol = "exclamationmark.circle"
        case .disconnected:
            text = "Optional"
            symbol = "circle"
        }
        return Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(authState == .connected ? .green : .secondary)
    }

    @ViewBuilder
    private var authMessageView: some View {
        switch authState {
        case .disconnected:
            SettingsMessageView(message: .info("Manual public repo tracking works without signing in. Connect GitHub only to pick from your public repositories."))
        case .requestingCode:
            SettingsMessageView(message: .info("Requesting a GitHub device code…"))
        case .waitingForAuthorization:
            SettingsMessageView(message: .info("Authorize in the browser. This window will update when GitHub confirms access."))
        case .connected:
            SettingsMessageView(message: .success("GitHub connected. Load public repositories to pick one."))
        case .failed(let message):
            SettingsMessageView(message: .warning(message))
        }
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
                try KeychainTokenStore(service: "GHMenuStars.GitHubOAuth").saveToken(token.accessToken)
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

private struct CurrentRepoSummary: View {
    let repo: TrackedRepo
    let delta: RepoDelta?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(repo.displayName, systemImage: "star.circle.fill")
                .font(.headline)
            HStack(spacing: 12) {
                Text(RepoDeltaFormatter.metricLine(label: "★", value: repo.lastStars, delta: delta?.starsDelta))
                Text(RepoDeltaFormatter.metricLine(label: "Downloads", value: repo.lastDownloads, delta: delta?.downloadsDelta))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct EmptyRepositoryView: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "star.slash")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No repository tracked")
                    .font(.headline)
                Text("Paste a public GitHub repo URL or owner/repo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DeviceCodePanel: View {
    let deviceCode: DeviceCodeResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(deviceCode.userCode)
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button("Copy Code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(deviceCode.userCode, forType: .string)
                }
                Button("Open GitHub") {
                    if let url = URL(string: deviceCode.verificationURI) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Text(deviceCode.verificationURI)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private enum SettingsMessage: Equatable {
    case info(String)
    case success(String)
    case warning(String)

    var text: String {
        switch self {
        case .info(let text), .success(let text), .warning(let text):
            return text
        }
    }

    var symbol: String {
        switch self {
        case .info:
            return "info.circle"
        case .success:
            return "checkmark.circle"
        case .warning:
            return "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .info:
            return .secondary
        case .success:
            return .green
        case .warning:
            return .orange
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
