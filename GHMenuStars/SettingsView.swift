import AppKit
import SwiftUI

enum AppExternalLinks {
    static let projectPage = URL(string: "https://jazzyalex.github.io/stargazer-bar/")!
    static let gitHubRepository = URL(string: "https://github.com/jazzyalex/stargazer-bar")!
    static let xProfile = URL(string: "https://x.com/jazzyalex")!
}

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
    static let contentHeight: CGFloat = 580

    @ObservedObject var repoStore: TrackedRepoStore
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var updaterController: UpdaterController
    let gitHubClient: GitHubClient
    private let soundPreviewService = SoundService()

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
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            repositoryTab
                .tabItem { Label("Repository", systemImage: "book.closed") }

            notificationsTab
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .padding(.top, 8)
        .frame(width: Self.contentWidth, height: Self.contentHeight)
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            aboutSection
            appSection
            refreshSection
            updatesSection
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var notificationsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            notificationsSection
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var repositoryTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            repositorySection
            menuBarSection
            accountSection
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var repositorySection: some View {
        GroupBox("Repositories") {
            VStack(alignment: .leading, spacing: 10) {
                if repoStore.trackedRepos.isEmpty {
                    Text("No repositories tracked yet.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(repoStore.trackedRepos) { repo in
                            RepositoryRow(
                                repo: repo,
                                isSelected: repoStore.repo(id: settingsStore.settings.selectedMenuBarRepoID)?.id == repo.id,
                                select: { selectMenuBarRepo(repo.id) },
                                remove: { removeTrackedRepo(repo.id) },
                                sound: repo.starSound,
                                setSound: { repoStore.setStarSound($0, for: repo.id) },
                                previewSound: { soundPreviewService.play($0) }
                            )
                        }
                    }
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
                            Text("Add")
                        }
                    }
                    .disabled(isValidating || repoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                HStack {
                    Text("\(repoStore.trackedRepos.count)/\(TrackedRepoStore.maximumTrackedRepos) repositories")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                if let validationMessage {
                    SettingsMessageView(message: validationMessage)
                }
            }
            .padding(8)
        }
    }

    private var menuBarSection: some View {
        GroupBox("Menu Bar") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Counter", selection: Binding(
                    get: { settingsStore.settings.menuBarDisplayMode },
                    set: { newValue in
                        settingsStore.update { settings in
                            settings.menuBarDisplayMode = newValue
                            if newValue.requiresSelectedRepo, settings.selectedMenuBarRepoID == nil {
                                settings.selectedMenuBarRepoID = repoStore.trackedRepos.first?.id
                            }
                        }
                    }
                )) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if settingsStore.settings.menuBarDisplayMode.requiresSelectedRepo {
                    Picker("Shown repo", selection: Binding<UUID?>(
                        get: { repoStore.repo(id: settingsStore.settings.selectedMenuBarRepoID)?.id },
                        set: { newValue in
                            settingsStore.update { $0.selectedMenuBarRepoID = newValue }
                        }
                    )) {
                        ForEach(repoStore.trackedRepos) { repo in
                            Text(repo.displayName).tag(Optional(repo.id))
                        }
                    }
                    .disabled(repoStore.trackedRepos.isEmpty)
                }

                Picker("Trend range", selection: Binding(
                    get: { settingsStore.settings.repoTrendRange },
                    set: { newValue in settingsStore.update { $0.repoTrendRange = newValue } }
                )) {
                    ForEach(RepoTrendRange.allCases) { range in
                        Text(range.displayName).tag(range)
                    }
                }
            }
            .padding(8)
        }
    }

    private var refreshSection: some View {
        GroupBox("Refresh") {
            VStack(alignment: .leading, spacing: 10) {
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
            .padding(8)
        }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Notify on star increases", isOn: Binding(
                get: { settingsStore.settings.notifyOnStarIncrease },
                set: { newValue in settingsStore.update { $0.notifyOnStarIncrease = newValue } }
            ))
            Picker("Celebrations", selection: Binding(
                get: { settingsStore.settings.celebrationMode },
                set: { newValue in
                    settingsStore.update { settings in
                        settings.celebrationMode = newValue
                        settings.animateOnStarIncrease = newValue != .off
                    }
                }
            )) {
                ForEach(CelebrationMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Play milestone sound", isOn: Binding(
                get: { settingsStore.settings.playSoundOnStarIncrease },
                set: { newValue in settingsStore.update { $0.playSoundOnStarIncrease = newValue } }
            ))
            .disabled(settingsStore.settings.celebrationMode == .off)
            Picker("Sound milestone", selection: Binding(
                get: { settingsStore.settings.starSoundThreshold },
                set: { newValue in settingsStore.update { $0.starSoundThreshold = newValue } }
            )) {
                ForEach(StarSoundThreshold.allCases) { threshold in
                    Text(threshold.displayName).tag(threshold)
                }
            }
            .disabled(!settingsStore.settings.playSoundOnStarIncrease || settingsStore.settings.celebrationMode == .off)
        }
        .padding(.top, 4)
    }

    private var appSection: some View {
        GroupBox("App") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Hide Dock icon", isOn: Binding(
                    get: { settingsStore.settings.hideDockIcon },
                    set: { newValue in settingsStore.update { $0.hideDockIcon = newValue } }
                ))
            }
            .padding(8)
        }
    }

    private var aboutSection: some View {
        GroupBox("About") {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Stargazer Bar")
                        .font(.headline)
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.1")")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        SettingsLink("Project Page", url: AppExternalLinks.projectPage)
                        SettingsLink("GitHub", url: AppExternalLinks.gitHubRepository)
                        SettingsLink("Star on GitHub", url: AppExternalLinks.gitHubRepository)
                        SettingsLink("X", url: AppExternalLinks.xProfile)
                    }
                    .font(.caption)
                }

                Spacer()
            }
            .padding(8)
        }
    }

    private var accountSection: some View {
        GroupBox("GitHub") {
            VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(authButtonTitle) { startDeviceFlow() }
                    .disabled(authState.isBusy)
                Button {
                    loadPublicRepos()
                } label: {
                    if isLoadingRepos {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Load Public Repos")
                    }
                }
                .disabled(isLoadingRepos || authState.isBusy)
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
                .frame(maxHeight: 220)
            }
            }
            .padding(8)
        }
    }

    private var updatesSection: some View {
        GroupBox("Updates") {
            VStack(alignment: .leading, spacing: 10) {
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
            .padding(8)
        }
    }

    // MARK: - Helpers

    private var lastCheckedSummary: String? {
        guard let checkedAt = repoStore.trackedRepos.compactMap(\.lastCheckedAt).max(),
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
        if repoStore.trackedRepos.count >= TrackedRepoStore.maximumTrackedRepos,
           !repoStore.containsRepo(owner: owner, name: name) {
            validationMessage = .warning("Remove a repository before adding another. Stargazer Bar tracks up to \(TrackedRepoStore.maximumTrackedRepos) repositories.")
            return
        }

        isValidating = true
        validationMessage = nil
        Task {
            do {
                let repoResult = try await gitHubClient.fetchRepo(owner: owner, name: name, etag: nil)
                guard !repoResult.value.private else { throw GitHubError.notFoundOrPrivate }
                let releasesResult = try await gitHubClient.fetchReleases(owner: owner, name: name, etag: nil)
                let downloads = ReleaseDownloadAggregator.totalDownloads(from: releasesResult.value)
                let checkedAt = Date()
                let trendPoints = await fetchTrendPoints(
                    owner: owner,
                    name: name,
                    stars: repoResult.value.stargazersCount,
                    forks: repoResult.value.forksCount,
                    checkedAt: checkedAt
                )
                try await MainActor.run {
                    let repo = TrackedRepo(
                        owner: owner,
                        name: name,
                        source: source,
                        lastStars: repoResult.value.stargazersCount,
                        lastDownloads: downloads,
                        lastForks: repoResult.value.forksCount,
                        lastCheckedAt: checkedAt,
                        lastSuccessfulCheckAt: checkedAt,
                        etagRepo: repoResult.etag,
                        etagReleases: releasesResult.etag,
                        trendPoints: trendPoints,
                        trendRange: trendPoints.isEmpty ? nil : .all
                    )
                    try repoStore.upsertTrackedRepo(repo)
                    if settingsStore.settings.selectedMenuBarRepoID == nil {
                        settingsStore.update { $0.selectedMenuBarRepoID = repoStore.repo(id: nil)?.id }
                    }
                    validationMessage = .success("Tracking \(owner)/\(name).")
                    isValidating = false
                }
            } catch TrackedRepoStoreError.maximumReached(let maximum) {
                await MainActor.run {
                    validationMessage = .warning("Remove a repository before adding another. Stargazer Bar tracks up to \(maximum) repositories.")
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

    private func fetchTrendPoints(
        owner: String,
        name: String,
        stars: Int,
        forks: Int,
        checkedAt: Date
    ) async -> [RepoTrendPoint] {
        do {
            async let starDates = gitHubClient.fetchStargazerDates(owner: owner, name: name)
            async let forkDates = gitHubClient.fetchForkDates(owner: owner, name: name)
            let (resolvedStarDates, resolvedForkDates) = try await (starDates, forkDates)
            return RepoTrendBuilder.points(
                stars: stars,
                forks: forks,
                starDates: resolvedStarDates,
                forkDates: resolvedForkDates,
                range: .all,
                now: checkedAt
            )
        } catch {
            return []
        }
    }

    private func track(owner: String, name: String, source: RepoSource) {
        repoText = "\(owner)/\(name)"
        validateRepo(owner: owner, name: name, source: source)
    }

    private func selectMenuBarRepo(_ repoID: UUID) {
        settingsStore.update { settings in
            settings.selectedMenuBarRepoID = repoID
            if !settings.menuBarDisplayMode.requiresSelectedRepo {
                settings.menuBarDisplayMode = .selectedRepoStars
            }
        }
    }

    private func removeTrackedRepo(_ repoID: UUID) {
        repoStore.removeTrackedRepo(id: repoID)
        if settingsStore.settings.selectedMenuBarRepoID == repoID {
            settingsStore.update { $0.selectedMenuBarRepoID = repoStore.trackedRepos.first?.id }
        }
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
        let shouldRestoreSettingsAfterPrompt = PreferencesWindow.shared.canRestoreAfterExternalPrompt
        Task {
            let token: String
            do {
                guard let keychainToken = try loadGitHubTokenForRepoList(), !keychainToken.isEmpty else {
                    await MainActor.run {
                        isLoadingRepos = false
                        PreferencesWindow.shared.restoreAfterExternalPrompt(if: shouldRestoreSettingsAfterPrompt)
                        startDeviceFlow()
                    }
                    return
                }
                token = keychainToken
                await MainActor.run {
                    PreferencesWindow.shared.restoreAfterExternalPrompt(if: shouldRestoreSettingsAfterPrompt)
                }
            } catch {
                await MainActor.run {
                    authState = .failed(GitHubError.userMessage(for: error))
                    isLoadingRepos = false
                    PreferencesWindow.shared.restoreAfterExternalPrompt(if: shouldRestoreSettingsAfterPrompt)
                }
                return
            }

            do {
                let authenticatedClient = GitHubClient(tokenProvider: { token })
                let repos = try await authenticatedClient.fetchAccessiblePublicRepos()
                await MainActor.run {
                    publicRepos = repos
                    authState = .connected
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

    private func loadGitHubTokenForRepoList() throws -> String? {
        let currentStore = KeychainTokenStore.gitHubOAuthStore()
        if let token = try currentStore.loadToken(allowUserInteraction: true) {
            return token
        }

        let legacyStore = KeychainTokenStore(service: KeychainTokenStore.legacyGitHubOAuthService)
        guard let legacyToken = try legacyStore.loadToken(allowUserInteraction: true) else {
            return nil
        }
        try currentStore.saveToken(legacyToken)
        return legacyToken
    }
}

private struct RepositoryRow: View {
    let repo: TrackedRepo
    let isSelected: Bool
    let select: () -> Void
    let remove: () -> Void
    let sound: StarSound
    let setSound: (StarSound) -> Void
    let previewSound: (StarSound) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Show in menu bar")

            VStack(alignment: .leading, spacing: 2) {
                Text(repo.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(metricsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 120, alignment: .leading)

            Spacer()

            Picker("Sound", selection: Binding(
                get: { sound },
                set: setSound
            )) {
                ForEach(StarSound.allCases) { sound in
                    Text(sound.displayName).tag(sound)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 130)
            .help("Star sound")

            Button { previewSound(sound) } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.plain)
            .disabled(sound.isSilent)
            .help("Preview sound")

            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove repository")
        }
        .padding(.vertical, 3)
    }

    private var metricsText: String {
        let stars = RepoDeltaFormatter.metricLine(label: "Stars", value: repo.lastStars, delta: repo.lastStarsDelta)
        let downloads = RepoDeltaFormatter.metricLine(label: "Downloads", value: repo.lastDownloads, delta: repo.lastDownloadsDelta)
        let forks = RepoDeltaFormatter.metricLine(label: "Forks", value: repo.lastForks, delta: repo.lastForksDelta)
        return "\(stars)  \(downloads)  \(forks)"
    }
}

private struct SettingsLink: View {
    let title: String
    let url: URL
    @State private var isPointing = false

    init(_ title: String, url: URL) {
        self.title = title
        self.url = url
    }

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text(title)
                .foregroundStyle(Color(nsColor: .linkColor))
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering, !isPointing {
                NSCursor.pointingHand.push()
                isPointing = true
            } else if !isHovering, isPointing {
                NSCursor.pop()
                isPointing = false
            }
        }
        .onDisappear {
            if isPointing {
                NSCursor.pop()
                isPointing = false
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
