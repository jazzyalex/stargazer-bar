import SwiftUI

struct SettingsView: View {
    static let contentWidth: CGFloat = 520
    static let contentHeight: CGFloat = 610

    @ObservedObject var repoStore: TrackedRepoStore
    @ObservedObject var settingsStore: SettingsStore
    let gitHubClient: GitHubClient

    @State private var repoText = ""
    @State private var validationMessage: String?
    @State private var isValidating = false
    @State private var authMessage: String?
    @State private var deviceCode: DeviceCodeResponse?
    @State private var publicRepos: [GitHubRepoSummary] = []
    @State private var isLoadingRepos = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Repository") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("owner/repo or https://github.com/owner/repo", text: $repoText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { validateManualRepo() }

                        HStack {
                            Button(isValidating ? "Checking…" : "Track Public Repo") {
                                validateManualRepo()
                            }
                            .disabled(isValidating || repoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            if let tracked = repoStore.trackedRepos.first {
                                Text("Tracking \(tracked.displayName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let validationMessage {
                            Text(validationMessage)
                                .font(.caption)
                                .foregroundStyle(validationMessage.hasPrefix("Tracking") ? .green : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
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
                            Text("GitHub rate limit active. The app will retry \(RelativeDateTimeFormatter.menu.string(for: state.resetAt) ?? "later").")
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
                        Text("Public repositories you can access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("GitHub OAuth app client_id", text: Binding(
                            get: { settingsStore.settings.gitHubOAuthClientID },
                            set: { newValue in settingsStore.update { $0.gitHubOAuthClientID = newValue } }
                        ))
                        .textFieldStyle(.roundedBorder)

                        HStack {
                            Button("Connect GitHub") {
                                startDeviceFlow()
                            }
                            .disabled(settingsStore.settings.gitHubOAuthClientID.isEmpty)

                            Button(isLoadingRepos ? "Loading…" : "Load Public Repos") {
                                loadPublicRepos()
                            }
                            .disabled(isLoadingRepos)
                        }

                        if let deviceCode {
                            Text("Open \(deviceCode.verificationURI) and enter \(deviceCode.userCode).")
                                .font(.caption)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let authMessage {
                            Text(authMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        ForEach(publicRepos) { repo in
                            Button(repo.fullName) {
                                track(owner: repo.owner.login, name: repo.name, source: .oauth)
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .padding(8)
                }

                GroupBox("App") {
                    Toggle("Show Dock icon", isOn: Binding(
                        get: { !settingsStore.settings.hideDockIcon },
                        set: { newValue in settingsStore.update { $0.hideDockIcon = !newValue } }
                    ))
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
        }
    }

    private func validateManualRepo() {
        let input = repoText
        isValidating = true
        validationMessage = nil
        Task {
            do {
                let parsed = try RepoURLParser.parse(input)
                let repoResult = try await gitHubClient.fetchRepo(owner: parsed.owner, name: parsed.name, etag: nil)
                guard !repoResult.value.private else { throw GitHubError.notFoundOrPrivate }
                let releasesResult = try await gitHubClient.fetchReleases(owner: parsed.owner, name: parsed.name, etag: nil)
                let downloads = ReleaseDownloadAggregator.totalDownloads(from: releasesResult.value)
                await MainActor.run {
                    let repo = TrackedRepo(
                        owner: parsed.owner,
                        name: parsed.name,
                        source: .manual,
                        lastStars: repoResult.value.stargazersCount,
                        lastDownloads: downloads,
                        lastCheckedAt: Date(),
                        lastSuccessfulCheckAt: Date(),
                        etagRepo: repoResult.etag,
                        etagReleases: releasesResult.etag
                    )
                    repoStore.setTrackedRepo(repo)
                    validationMessage = "Tracking \(parsed.owner)/\(parsed.name)."
                    isValidating = false
                }
            } catch {
                await MainActor.run {
                    validationMessage = GitHubError.userMessage(for: error)
                    isValidating = false
                }
            }
        }
    }

    private func track(owner: String, name: String, source: RepoSource) {
        repoStore.setTrackedRepo(TrackedRepo(owner: owner, name: name, source: source))
    }

    private func startDeviceFlow() {
        authMessage = nil
        Task {
            do {
                let response = try await DeviceFlowClient().requestDeviceCode(clientID: settingsStore.settings.gitHubOAuthClientID)
                await MainActor.run {
                    deviceCode = response
                    authMessage = "After authorizing, click Load Public Repos."
                    if let url = URL(string: response.verificationURI) {
                        NSWorkspace.shared.open(url)
                    }
                }
                let token = try await DeviceFlowClient().pollForToken(
                    clientID: settingsStore.settings.gitHubOAuthClientID,
                    deviceCode: response.deviceCode,
                    interval: response.interval
                )
                try KeychainTokenStore(service: "GHMenuStars.GitHubOAuth").saveToken(token.accessToken)
                await MainActor.run {
                    authMessage = "Connected."
                }
            } catch {
                await MainActor.run {
                    authMessage = GitHubError.userMessage(for: error)
                }
            }
        }
    }

    private func loadPublicRepos() {
        isLoadingRepos = true
        Task {
            do {
                let repos = try await gitHubClient.fetchAccessiblePublicRepos()
                await MainActor.run {
                    publicRepos = repos
                    authMessage = repos.isEmpty ? "No public repositories returned." : nil
                    isLoadingRepos = false
                }
            } catch {
                await MainActor.run {
                    authMessage = GitHubError.userMessage(for: error)
                    isLoadingRepos = false
                }
            }
        }
    }
}
