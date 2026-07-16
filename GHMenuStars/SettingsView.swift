import AppKit
import SwiftUI

enum AppExternalLinks {
    static let projectPage = URL(string: "https://jazzyalex.github.io/stargazer-bar/")!
    static let gitHubRepository = URL(string: "https://github.com/jazzyalex/stargazer-bar")!
    /// Fine-grained token creation. GitHub does not document query-parameter
    /// prefill for this page the way it does for classic tokens, so the sheet
    /// lists the permissions instead of pretending they can be pre-ticked.
    static let newFineGrainedToken = URL(string: "https://github.com/settings/personal-access-tokens/new")!
    static let xProfile = URL(string: "https://x.com/jazzyalex")!
}

private enum RepoVisibilityFilter: Hashable {
    case all
    case publicOnly
    case privateOnly

    func includes(_ repo: GitHubRepoSummary) -> Bool {
        switch self {
        case .all: return true
        case .publicOnly: return !repo.isPrivate
        case .privateOnly: return repo.isPrivate
        }
    }
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
    let repoAccess: GitHubRepoAccess
    private let soundPreviewService = SoundService()

    @State private var repoText = ""
    @State private var validationMessage: SettingsMessage?
    @State private var isValidating = false
    @State private var authState: GitHubAuthViewState = .disconnected
    @State private var deviceCode: DeviceCodeResponse?
    @State private var publicRepos: [GitHubRepoSummary] = []
    @State private var isLoadingRepos = false
    @State private var hasLoadedPublicRepos = false
    /// The authenticated GitHub login, shown in the connection footer and cached
    /// with the directory so it survives relaunch.
    @State private var currentLogin: String?
    @State private var repoVisibilityFilter: RepoVisibilityFilter = .all
    @State private var repoFilter = ""
    @State private var repoPendingDeletion: TrackedRepo?
    @State private var patInput = ""
    @State private var patStatus: SettingsMessage?

    /// The repo whose add failed for want of a usable token. Non-nil is what
    /// makes the inline token field appear.
    @State private var repoNeedingToken: (owner: String, name: String, source: RepoSource)?

    init(
        repoStore: TrackedRepoStore,
        settingsStore: SettingsStore,
        gitHubClient: GitHubClient,
        repoAccess: GitHubRepoAccess,
        updaterController: UpdaterController
    ) {
        self._repoStore = ObservedObject(wrappedValue: repoStore)
        self._settingsStore = ObservedObject(wrappedValue: settingsStore)
        self._updaterController = ObservedObject(wrappedValue: updaterController)
        self.gitHubClient = gitHubClient
        self.repoAccess = repoAccess
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
        .onAppear {
            // The badge should reflect the stored token, not just this
            // window's session. Silent read — never shows keychain UI.
            if authState == .disconnected, GitHubCredentialStore.hasOAuthTokenSilently() {
                authState = .connected
            }
            // Show the cached repo list at once, then refresh silently.
            loadCachedDirectoryAndRefresh()
        }
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

    /// Anchors the loaded-repo picker so a successful Load Repos can scroll it
    /// into view — the GitHub section sits at the bottom of this tab, so the
    /// freshly loaded list would otherwise appear below the fold, invisible
    /// until the user thinks to scroll.
    private static let repoPickerAnchorID = "repoPicker"

    private var repositoryTab: some View {
        // Scrolls rather than clips. This window is a fixed 520x580 and content
        // has outgrown it three times now — each time truncating its own help
        // text mid-sentence. A taller window just moves the next overflow.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    repositorySection
                    addRepositorySection
                    menuBarSection
                    connectionSection
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: hasLoadedPublicRepos) { loaded in
                guard loaded else { return }
                // Let the picker lay out before scrolling to it — publicRepos
                // and this flag are set in the same state update, so the target
                // view may not exist yet when onChange first fires.
                DispatchQueue.main.async {
                    withAnimation {
                        proxy.scrollTo(Self.repoPickerAnchorID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// GitHub answers 404 for a private repo you can't see, exactly as it does
    /// for one that doesn't exist — so the add flow has to guess, and guess
    /// usefully. Which advice is right depends entirely on whether a token is
    /// already in play.
    private func addFailureMessage(for error: Error, owner: String, name: String) -> String {
        guard case GitHubError.notFoundOrPrivate = error else {
            return GitHubError.userMessage(for: error)
        }
        if repoAccess.isPATDead {
            return "Can't see \(owner)/\(name). Your private repo token was revoked or expired."
        }
        if !settingsStore.settings.hasPrivateRepoToken {
            return "Can't see \(owner)/\(name). If it's private, it needs a token."
        }
        return "Can't see \(owner)/\(name) with your saved token. Check the token grants access to this repository — and if it belongs to an organization, that the token's resource owner is that organization, not your personal account."
    }

    private var applicableMenuBarModes: [MenuBarDisplayMode] {
        let isPrivate = repoStore.repo(id: settingsStore.settings.selectedMenuBarRepoID)?.isPrivate == true
        return MenuBarDisplayMode.allCases.filter { $0.isApplicable(toPrivateRepo: isPrivate) }
    }

    private var needsTokenToProceed: Bool {
        repoNeedingToken != nil
    }

    private var patStatusText: String {
        if case .success(let text)? = patStatus { return text }
        return "Private repo token saved"
    }

    /// Save the token, dismiss the sheet, and resume the Add the user already
    /// asked for. There is no separate "add" action here: authenticating is a
    /// detour on the way to the thing they wanted.
    private func saveTokenAndResumeAdd() {
        guard let pending = repoNeedingToken else { return }
        do {
            try GitHubCredentialStore.standard().setPAT(patInput)
            repoStore.clearAllETags()
            repoAccess.resetTokenState()
            patInput = ""
            settingsStore.update { $0.hasPrivateRepoToken = true }
            patStatus = nil
            repoNeedingToken = nil
            validatePAT()
            validateRepo(owner: pending.owner, name: pending.name, source: pending.source)
        } catch {
            patStatus = .warning(GitHubError.userMessage(for: error))
        }
    }

    private func removePAT() {
        try? GitHubCredentialStore.standard().clearPAT()
        repoStore.clearAllETags()
        repoAccess.resetTokenState()
        patInput = ""
        settingsStore.update { $0.hasPrivateRepoToken = false }
        patStatus = nil
    }

    private func validatePAT() {
        guard let token = GitHubCredentialStore.loadPATSilently() else {
            patStatus = nil
            return
        }
        Task {
            do {
                let login = try await gitHubClient.fetchAuthenticatedLogin(token: token)
                await MainActor.run { patStatus = .success("Token active for \(login).") }
            } catch GitHubError.unauthorized {
                // The generic auth copy ("GitHub authorization is required")
                // blames the app's sign-in, which isn't what failed.
                await MainActor.run {
                    patStatus = .warning("GitHub rejected that token. Check it hasn't expired or been revoked, and that it's a fine-grained token.")
                }
            } catch {
                await MainActor.run { patStatus = .warning(GitHubError.userMessage(for: error)) }
            }
        }
    }

    private var repositorySection: some View {
        GroupBox("Your Repositories") {
            VStack(alignment: .leading, spacing: 10) {
                if repoStore.trackedRepos.isEmpty {
                    Text("No repositories tracked yet. Add one below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 6) {
                        ForEach(repoStore.trackedRepos) { repo in
                            RepositoryRow(
                                repo: repo,
                                isSelected: repoStore.repo(id: settingsStore.settings.selectedMenuBarRepoID)?.id == repo.id,
                                select: { selectMenuBarRepo(repo.id) },
                                remove: { repoPendingDeletion = repo },
                                sound: repo.starSound,
                                setSound: { repoStore.setStarSound($0, for: repo.id) },
                                previewSound: { soundPreviewService.play($0) },
                                isMuted: repo.isMuted,
                                setMuted: { repoStore.setMuted($0, for: repo.id) }
                            )
                        }
                    }
                }

                HStack {
                    Text("\(repoStore.trackedRepos.count) of \(TrackedRepoStore.maximumTrackedRepos) tracked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(8)
        }
        .sheet(isPresented: Binding(
            get: { repoNeedingToken != nil },
            set: { if !$0 { repoNeedingToken = nil } }
        )) {
            PrivateAccessSheet(
                repoName: repoNeedingToken.map { "\($0.owner)/\($0.name)" } ?? "",
                token: $patInput,
                status: patStatus,
                wasRevoked: repoAccess.isPATDead,
                cancel: {
                    repoNeedingToken = nil
                    patInput = ""
                },
                save: { saveTokenAndResumeAdd() }
            )
        }
        .alert(
            "Stop tracking \(repoPendingDeletion?.displayName ?? "this repository")?",
            isPresented: Binding(
                get: { repoPendingDeletion != nil },
                set: { if !$0 { repoPendingDeletion = nil } }
            ),
            presenting: repoPendingDeletion
        ) { repo in
            Button("Cancel", role: .cancel) { repoPendingDeletion = nil }
            Button("Remove", role: .destructive) {
                removeTrackedRepo(repo.id)
                repoPendingDeletion = nil
            }
        } message: { _ in
            Text("It will be removed from Stargazer Bar. You can add it again later.")
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
                    // Only modes that can actually produce a number for the
                    // selected repo. A mode that structurally has no data just
                    // shows "--" forever with no explanation.
                    ForEach(applicableMenuBarModes) { mode in
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

                if settingsStore.settings.menuBarDisplayMode == .selectedRepoCommits {
                    Picker("Commit window", selection: Binding(
                        get: { settingsStore.settings.commitActivityWindow },
                        set: { newValue in settingsStore.update { $0.commitActivityWindow = newValue } }
                    )) {
                        ForEach(CommitActivityWindow.allCases) { window in
                            Text(window.displayName).tag(window)
                        }
                    }
                }

                Picker("Trend range", selection: Binding(
                    get: { settingsStore.settings.repoTrendRange },
                    set: { newValue in settingsStore.update { $0.repoTrendRange = newValue } }
                )) {
                    ForEach(RepoTrendRange.allCases) { range in
                        Text(range.displayName).tag(range)
                    }
                }

                Picker("Radar activity", selection: Binding(
                    get: { settingsStore.settings.maintainerRadarActivityWindow },
                    set: { newValue in settingsStore.update { $0.maintainerRadarActivityWindow = newValue } }
                )) {
                    ForEach(MaintainerRadarActivityWindow.allCases) { window in
                        Text(window.displayName).tag(window)
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
                    Text("Open source and local-only. Stars help other maintainers find it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        SettingsLink("Project Page", url: AppExternalLinks.projectPage)
                        SettingsLink("GitHub", url: AppExternalLinks.gitHubRepository)
                        SettingsLink("★ Star", url: AppExternalLinks.gitHubRepository)
                        SettingsLink("X", url: AppExternalLinks.xProfile)
                    }
                    .font(.caption)
                }

                Spacer()
            }
            .padding(8)
        }
    }

    private var addRepositorySection: some View {
        GroupBox("Add a Repository") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Search your repositories", text: $repoFilter)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $repoVisibilityFilter) {
                        Text("All").tag(RepoVisibilityFilter.all)
                        Text("Public").tag(RepoVisibilityFilter.publicOnly)
                        Text("Private").tag(RepoVisibilityFilter.privateOnly)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }

                if publicRepos.isEmpty {
                    Text(directoryPlaceholder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(repoPickerCountLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredRepos.prefix(50)) { repo in
                                directoryRow(repo)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }

                Divider()

                HStack(spacing: 8) {
                    TextField("owner/repo or URL", text: $repoText)
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

                if let validationMessage {
                    SettingsMessageView(message: validationMessage)
                }
            }
            .padding(8)
            .id(Self.repoPickerAnchorID)
        }
    }

    private func directoryRow(_ repo: GitHubRepoSummary) -> some View {
        let isTracked = repoStore.containsRepo(owner: repo.owner.login, name: repo.name)
        return HStack(spacing: 6) {
            Image(systemName: repo.isPrivate ? "lock" : "book.closed")
                .foregroundStyle(.secondary)
            Text(repo.fullName)
                .lineLimit(1)
            if repo.isPrivate {
                Text("private")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
            }
            Spacer()
            if isTracked {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Already tracked")
            } else {
                Button {
                    addRepoFromDirectory(repo)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(isValidating)
                .help("Track this repository")
            }
        }
        .padding(.vertical, 2)
    }

    private var directoryPlaceholder: String {
        if isLoadingRepos { return "Loading your repositories…" }
        if authState == .connected { return "No repositories found. Try Refresh." }
        return "Connect GitHub in the section below to list your repositories."
    }

    private var connectionSection: some View {
        GroupBox("GitHub") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    authStateBadge
                    if authState == .connected, let currentLogin {
                        Text("@\(currentLogin)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if authState == .connected {
                        Button {
                            refreshDirectory(interactive: true)
                        } label: {
                            if isLoadingRepos {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Refresh")
                            }
                        }
                        .disabled(isLoadingRepos || authState.isBusy)
                    }
                    Button(authButtonTitle) { startDeviceFlow() }
                        .disabled(authState.isBusy)
                }

                if let deviceCode {
                    DeviceCodePanel(deviceCode: deviceCode)
                }

                // A place to see and remove a stored private-repo token. The
                // token is asked for inline, only when an add actually needs it.
                if settingsStore.settings.hasPrivateRepoToken {
                    Divider()
                    HStack(spacing: 8) {
                        if repoAccess.isPATDead {
                            Label("Private repo token was revoked or expired", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Label(patStatusText, systemImage: "lock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { removePAT() }
                            .controlSize(.small)
                    }
                }

                if case .failed(let message) = authState {
                    SettingsMessageView(message: .warning(message))
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
        return publicRepos.filter { repo in
            repoVisibilityFilter.includes(repo)
                && (query.isEmpty || repo.fullName.lowercased().contains(query))
        }
    }

    /// Names the picker so it reads as a result, not decoration — the list can
    /// land below the fold on load, and a labelled count is the cue that Load
    /// Repos did something and there's more to scroll to. The 50-row display cap
    /// is surfaced so a long list doesn't look silently truncated.
    private var repoPickerCountLabel: String {
        let total = publicRepos.count
        let noun = total == 1 ? "repository" : "repositories"
        if total > 50 {
            return "\(total) \(noun) — showing first 50, filter to narrow"
        }
        return "\(total) \(noun)"
    }

    private func validateManualRepo() {
        let input = repoText
        do {
            let parsed = try RepoURLParser.parse(input)
            // The paste field is for repos not in your list — attributed manual.
            // Repos added from the directory go through addRepoFromDirectory.
            validateRepo(owner: parsed.owner, name: parsed.name, source: .manual)
        } catch {
            validationMessage = .warning(GitHubError.userMessage(for: error))
        }
    }

    /// Adds a repo straight from the directory list. Goes through the same
    /// validate/add path as the paste field (so the 5-repo cap, private-token
    /// prompt, and error messages all apply), attributed to the OAuth source.
    private func addRepoFromDirectory(_ repo: GitHubRepoSummary) {
        validateRepo(owner: repo.owner.login, name: repo.name, source: .oauth)
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
                // No TrackedRepo exists yet and the user typed a bare owner/name,
                // so privacy is unknown: GitHub 404s identically for "missing"
                // and "you can't see it". The seam's ladder resolves it.
                let outcome = try await repoAccess.fetchRepo(
                    owner: owner, name: name, etag: nil, knownPrivate: false, repoID: nil
                )
                guard case .fetched(let repoResult, let isPrivate, let authToken) = outcome else {
                    // etag: nil was sent, so a 304 is impossible here.
                    throw GitHubError.notFoundOrPrivate
                }
                let releasesResult = try await gitHubClient.fetchReleases(
                    owner: owner, name: name, etag: nil, optionalAuthToken: authToken
                )
                let downloads = ReleaseDownloadAggregator.totalDownloads(from: releasesResult.value)
                let stars = isPrivate ? 0 : repoResult.value.stargazersCount
                let forks = isPrivate ? 0 : repoResult.value.forksCount
                let checkedAt = Date()
                // Release summaries come from the releases response we already
                // fetched, so populate them immediately — no extra request.
                let latestRelease = LatestReleaseSummaryBuilder.summary(from: releasesResult.value, totalDownloads: downloads)
                let recentReleases = RecentReleasesSummaryBuilder.summary(from: releasesResult.value, totalDownloads: downloads, now: checkedAt)
                // Track the repo as soon as the repo/releases lookups succeed.
                // The slower details — the stargazer/fork trend and the maintainer
                // radar — are backfilled in the background instead of blocking the
                // "Add" spinner.
                try await MainActor.run {
                    let repo = TrackedRepo(
                        owner: owner,
                        name: name,
                        source: source,
                        isPrivate: isPrivate,
                        lastStars: stars,
                        lastDownloads: downloads,
                        lastForks: forks,
                        lastCheckedAt: checkedAt,
                        lastSuccessfulCheckAt: checkedAt,
                        etagRepo: repoResult.etag,
                        etagReleases: releasesResult.etag,
                        trendPoints: [],
                        trendRange: nil,
                        latestRelease: latestRelease,
                        recentReleases: recentReleases
                    )
                    try repoStore.upsertTrackedRepo(repo)
                    if settingsStore.settings.selectedMenuBarRepoID == nil {
                        settingsStore.update { $0.selectedMenuBarRepoID = repoStore.repo(id: nil)?.id }
                    }
                    validationMessage = .success("Tracking \(owner)/\(name).")
                    repoNeedingToken = nil
                    isValidating = false
                    backfillDetails(owner: owner, name: name, isPrivate: isPrivate, authToken: authToken, stars: stars, forks: forks, latestRelease: latestRelease, checkedAt: checkedAt)
                }
            } catch TrackedRepoStoreError.maximumReached(let maximum) {
                await MainActor.run {
                    validationMessage = .warning("Remove a repository before adding another. Stargazer Bar tracks up to \(maximum) repositories.")
                    isValidating = false
                }
            } catch {
                await MainActor.run {
                    validationMessage = .warning(addFailureMessage(for: error, owner: owner, name: name))
                    // Offer the token inline only when a token could plausibly
                    // fix this: a 404 with no working token. Not for a typo the
                    // user can see, and not when a good token already failed.
                    if case GitHubError.notFoundOrPrivate = error,
                       !settingsStore.settings.hasPrivateRepoToken || repoAccess.isPATDead {
                        repoNeedingToken = (owner, name, source)
                    }
                    isValidating = false
                }
            }
        }
    }

    @MainActor
    private func backfillDetails(
        owner: String,
        name: String,
        isPrivate: Bool,
        authToken: String?,
        stars: Int,
        forks: Int,
        latestRelease: LatestReleaseSummary?,
        checkedAt: Date
    ) {
        let activityWindow = settingsStore.settings.maintainerRadarActivityWindow
        Task {
            let releaseAnchor = activityWindow == .off ? nil : latestRelease.flatMap {
                ReleaseDynamics.isFresh(publishedAt: $0.publishedAt, now: checkedAt) ? $0.publishedAt : nil
            }
            // Private repos: no star/fork trend to chart, and the radar must
            // carry the token that actually worked — the ambient one cannot see
            // this repo, so it would 404 into blank rows with no error, right
            // after the user's first success.
            async let pointsTask: [RepoTrendPoint] = isPrivate
                ? []
                : fetchTrendPoints(
                    owner: owner,
                    name: name,
                    stars: stars,
                    forks: forks,
                    checkedAt: checkedAt
                )
            async let radarTask = gitHubClient.fetchMaintainerRadar(
                owner: owner,
                name: name,
                activityWindow: activityWindow,
                releaseAnchor: releaseAnchor,
                now: checkedAt,
                optionalAuthToken: authToken
            )
            let (points, radar) = await (pointsTask, radarTask)

            guard let id = repoStore.trackedRepos.first(where: {
                $0.owner.caseInsensitiveCompare(owner) == .orderedSame
                    && $0.name.caseInsensitiveCompare(name) == .orderedSame
            })?.id else { return }
            if !points.isEmpty {
                repoStore.setTrendPoints(points, range: .all, for: id)
            }
            repoStore.setMaintainerRadar(radar.hasData ? radar : nil, for: id)
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
            let pageLimit = gitHubClient.trendBackfillPageLimit()
            async let starDates = gitHubClient.fetchStargazerDates(owner: owner, name: name, maxPages: pageLimit)
            async let forkDates = gitHubClient.fetchForkDates(owner: owner, name: name, maxPages: pageLimit)
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
        let isPrivate = repoStore.trackedRepos.first { $0.id == repoID }?.isPrivate == true
        settingsStore.update { settings in
            settings.selectedMenuBarRepoID = repoID
            // Picking a private repo used to force a star mode, which shows a
            // number that was never fetched. Commits is what a private repo
            // actually has, so select that instead of a metric it lacks.
            settings.menuBarDisplayMode = MenuBarDisplayResolver.modeAfterSelecting(
                isPrivate: isPrivate,
                current: settings.menuBarDisplayMode
            )
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
                try GitHubCredentialStore.standard().setOAuth(token.accessToken)
                await MainActor.run {
                    authState = .connected
                    deviceCode = nil
                    refreshDirectory(interactive: true)
                }
            } catch {
                await MainActor.run {
                    authState = .failed(GitHubError.userMessage(for: error))
                }
            }
        }
    }

    /// Loads the cached directory immediately and kicks off a silent refresh.
    /// Called on Settings appear — the list (including private repos) is visible
    /// at once, then updated in the background if a token is readable.
    private func loadCachedDirectoryAndRefresh() {
        if let cached = RepoDirectoryStore.load() {
            if publicRepos.isEmpty { publicRepos = cached.repos }
            if currentLogin == nil { currentLogin = cached.login }
        }
        refreshDirectory(interactive: false)
    }

    /// Refreshes the browsable repo directory (public + private).
    ///
    /// The two paths honour the "prompt only on real actions" rule:
    /// - `interactive` (Refresh button, device-flow completion) may show the
    ///   keychain dialog once and heals the item, surfaces errors, and starts
    ///   the device flow when there is no token.
    /// - silent (Settings auto-refresh) never prompts, never disturbs the cached
    ///   list on failure, and quietly updates when it can.
    ///
    /// Both tokens come from a single keychain read of the combined item, so a
    /// refresh costs at most one prompt and private repos ride along without a
    /// second dialog.
    private func refreshDirectory(interactive: Bool) {
        guard !isLoadingRepos else { return }
        isLoadingRepos = true
        if interactive { hasLoadedPublicRepos = false }
        let priorLogin = currentLogin
        let shouldRestore = interactive ? PreferencesWindow.shared.canRestoreAfterExternalPrompt : false
        Task {
            let credentials = await Task.detached {
                interactive
                    ? GitHubCredentialStore.standard().loadRequestingAccessIfNeeded()
                    : GitHubCredentialStore.standard().loadSilently()
            }.value
            if interactive {
                await MainActor.run {
                    PreferencesWindow.shared.restoreAfterExternalPrompt(if: shouldRestore)
                }
            }

            guard let oauth = credentials?.oauth, !oauth.isEmpty else {
                await MainActor.run {
                    isLoadingRepos = false
                    // Explicit refresh/connect with no token starts the flow; a
                    // passive refresh just leaves the cache in place.
                    if interactive { startDeviceFlow() }
                }
                return
            }

            do {
                let client = GitHubClient(tokenProvider: { oauth })
                let publicResult = try await client.fetchAccessiblePublicRepos()
                // A revoked PAT degrades to public-only rather than emptying the
                // picker — the user with a dead token still deserves their list.
                let privateResult: [GitHubRepoSummary]
                if let pat = credentials?.pat, !pat.isEmpty {
                    privateResult = (try? await client.fetchAccessiblePrivateRepos(token: pat)) ?? []
                } else {
                    privateResult = []
                }
                let mergedRepos = Self.merged(public: publicResult, private: privateResult)
                let login = (try? await client.fetchAuthenticatedLogin(token: oauth)) ?? priorLogin
                let directory = RepoDirectory(repos: mergedRepos, login: login, lastRefreshed: Date())
                RepoDirectoryStore.save(directory)
                await MainActor.run {
                    publicRepos = mergedRepos
                    currentLogin = login
                    authState = .connected
                    isLoadingRepos = false
                    if interactive { hasLoadedPublicRepos = true }
                }
            } catch {
                await MainActor.run {
                    // A failed refresh keeps the cached list; only the explicit
                    // path surfaces the error.
                    if interactive { authState = .failed(GitHubError.userMessage(for: error)) }
                    isLoadingRepos = false
                }
            }
        }
    }

    /// Private repos first — they're the ones the user can't reach any other way,
    /// and a picker that buries them under 25 public repos hasn't solved
    /// anything. Deduped by id, since a PAT with broad access can return repos
    /// the public listing already covered.
    static func merged(
        public publicRepos: [GitHubRepoSummary],
        private privateRepos: [GitHubRepoSummary]
    ) -> [GitHubRepoSummary] {
        var seen = Set<Int>()
        var result: [GitHubRepoSummary] = []
        for repo in privateRepos + publicRepos where seen.insert(repo.id).inserted {
            result.append(repo)
        }
        return result
    }

    private func merged(public publicRepos: [GitHubRepoSummary], private privateRepos: [GitHubRepoSummary]) -> [GitHubRepoSummary] {
        Self.merged(public: publicRepos, private: privateRepos)
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
    let isMuted: Bool
    let setMuted: (Bool) -> Void

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
            .disabled(isMuted)
            .help(isMuted ? "Muted — unmute to choose a sound" : "Star sound")

            Button { previewSound(sound) } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.plain)
            .disabled(isMuted || sound.isSilent)
            .help("Preview sound")

            Button { setMuted(!isMuted) } label: {
                Image(systemName: isMuted ? "bell.slash.fill" : "bell")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isMuted ? .primary : .secondary)
            .help(isMuted ? "Muted — no alerts for this repository. Click to unmute." : "Mute all alerts for this repository")

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
        let downloads = RepoDeltaFormatter.metricLine(label: "Downloads", value: repo.lastDownloads, delta: repo.lastDownloadsDelta)
        // Stars and forks are never fetched for a private repo, so showing them
        // would render zeroes we never looked up.
        guard !repo.isPrivate else { return "Private  \(downloads)" }
        let stars = RepoDeltaFormatter.metricLine(label: "Stars", value: repo.lastStars, delta: repo.lastStarsDelta)
        let forks = RepoDeltaFormatter.metricLine(label: "Forks", value: repo.lastForks, delta: repo.lastForksDelta)
        return "\(stars)  \(downloads)  \(forks)"
    }
}

/// Authenticating is a detour, not a second way to add a repo — so it happens in
/// a sheet that interrupts, gets what it needs, and gets out of the way. The
/// Settings window is a fixed 520x580, which is why this content cannot live
/// inline: it truncated its own instructions there.
private struct PrivateAccessSheet: View {
    let repoName: String
    @Binding var token: String
    let status: SettingsMessage?
    let wasRevoked: Bool
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(wasRevoked ? "Token expired" : "Private repository")
                .font(.headline)

            Text(wasRevoked
                 ? "Your saved token no longer works, so \(repoName) can't be read. Create a new one to continue."
                 : "\(repoName) isn't visible with your current access. If it's private, a fine-grained token will let Stargazer Bar read it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                NSWorkspace.shared.open(AppExternalLinks.newFineGrainedToken)
            } label: {
                Label("Create token on GitHub", systemImage: "arrow.up.forward.square")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set Repository access to \(repoName), then grant read-only:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(["Metadata", "Contents", "Issues", "Pull requests", "Actions"], id: \.self) { permission in
                        Text("• \(permission)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("If the repository belongs to an organization, set Resource owner to that organization — otherwise GitHub reports it as not found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            SecureField("Paste token (github_pat_…)", text: $token)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !token.isEmpty { save() } }

            if let status {
                SettingsMessageView(message: status)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
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
