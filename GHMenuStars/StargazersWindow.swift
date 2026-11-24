import AppKit
import SwiftUI

@MainActor
final class StargazersWindow {
    private var controller: NSWindowController?

    func show(repoID: UUID, repoStore: TrackedRepoStore, polling: RepoPollingService,
              openSettings: @escaping () -> Void) {
        guard let tracking = polling.stargazerTracking else { return }
        let root = StargazersView(repoID: repoID, repoStore: repoStore, tracking: tracking,
                                  checkNow: { [weak polling] in polling?.refreshNow(repoID: repoID) },
                                  openSettings: openSettings)
        if let hosting = controller?.window?.contentViewController as? NSHostingController<StargazersView> {
            hosting.rootView = root
        } else {
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Stargazers"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.setContentSize(NSSize(width: 760, height: 510))
            window.contentMinSize = NSSize(width: 560, height: 380)
            window.center()
            controller = NSWindowController(window: window)
        }
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller?.window?.makeKeyAndOrderFront(nil)
    }
}

private struct StargazerProfileLoad: Equatable {
    let accountIDs: [Int64]
    let scope: StargazerScope?
    let paused: Bool
}

private struct VisibleStargazers: PreferenceKey {
    static let defaultValue: Set<Int64> = []

    static func reduce(value: inout Set<Int64>, nextValue: () -> Set<Int64>) {
        value.formUnion(nextValue())
    }
}

@MainActor
private struct StargazersView: View {
    private enum Tab: String, CaseIterable { case current = "Current", disappeared = "Disappeared" }

    let repoID: UUID
    @ObservedObject var repoStore: TrackedRepoStore
    @ObservedObject var tracking: StargazerTrackingService
    let checkNow: () -> Void
    let openSettings: () -> Void

    @State private var tab = Tab.current
    @State private var search = ""
    @State private var visibleAccountIDs: Set<Int64> = []
    @State private var selection: Int64?
    @State private var loadingTotals = false
    @State private var totalsTask: Task<Void, Never>?

    private var repo: TrackedRepo? { repoStore.trackedRepos.first { $0.id == repoID } }
    private var entry: StargazerTrackingService.Entry? { tracking.entries[repoID] }
    private var snapshot: StargazerSnapshot? { entry?.displayedSnapshot }
    private var events: [StargazerDisappearance] {
        guard let snapshot else { return [] }
        return entry?.history?.events.filter { $0.scope == snapshot.scope } ?? []
    }
    private var filtered: [StargazerAccount] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = query.hasPrefix("@") ? String(query.dropFirst()) : query
        let accounts = snapshot?.accounts ?? []
        guard !term.isEmpty else { return accounts }
        return accounts.filter {
            $0.login.localizedCaseInsensitiveContains(term) ||
                tracking.profiles[$0.id]?.name?.localizedCaseInsensitiveContains(term) == true
        }
    }
    private var visible: [StargazerAccount] { filtered.filter { visibleAccountIDs.contains($0.id) } }
    private var paused: Bool { tracking.checking || repoStore.rateLimitState?.isLimited == true }
    private var visibleProfiles: StargazerProfileLoad {
        StargazerProfileLoad(accountIDs: tab == .current ? visible.map(\.id) : [], scope: snapshot?.scope, paused: paused)
    }
    private var selectedAccount: StargazerAccount? {
        let accounts = filtered
        return accounts.first { $0.id == selection } ?? accounts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if snapshot != nil {
                Picker("Stargazer view", selection: $tab) {
                    Text("Current").tag(Tab.current)
                    Text(events.isEmpty ? "Disappeared" : "Disappeared  \(events.count)").tag(Tab.disappeared)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding([.horizontal, .bottom], 16)
                switch tab {
                case .current: current
                case .disappeared: disappeared
                }
            } else {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "person.2").font(.title2).foregroundStyle(.secondary)
                    Text(repo == nil ? "Repository no longer tracked" : entry?.issue ?? "No complete check yet")
                        .multilineTextAlignment(.center)
                    if repo != nil { Button("GitHub Settings", action: openSettings) }
                }
                .padding()
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .id(repoID)
        .onChange(of: repoID) { _ in
            tab = .current
            search = ""
            selection = nil
            stopLoadingTotals()
        }
        .onChange(of: search) { _ in stopLoadingTotals() }
        .onChange(of: tab) { _ in stopLoadingTotals() }
        .onChange(of: paused) { _ in stopLoadingTotals() }
        .onDisappear { stopLoadingTotals() }
        .task(id: visibleProfiles) {
            let load = visibleProfiles
            guard !load.paused, !load.accountIDs.isEmpty else { return }
            // Wait for the viewport to settle before starting profile requests.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            await tracking.loadProfiles(load.accountIDs, repoID: repoID)
        }
        .task(id: detailLoad) {
            guard tab == .current, !paused, let id = selectedAccount?.id else { return }
            await tracking.loadDetails(id, repoID: repoID, includeSocials: true)
        }
    }

    private var detailLoad: StargazerProfileLoad {
        StargazerProfileLoad(accountIDs: tab == .current ? [selectedAccount?.id].compactMap { $0 } : [],
                             scope: snapshot?.scope, paused: paused)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if let repo {
                    Text(verbatim: repo.owner).font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: repo.name).font(.title2.bold())
                } else {
                    Text("Stargazers").font(.title2.bold())
                }
                if let snapshot {
                    let count = snapshot.accounts.count
                    if let reportedCount = entry?.countMismatch?.reportedCount ?? snapshot.reportedStarCount, reportedCount != count {
                        Text("\(count) accounts returned · GitHub reports \(reportedCount) stars")
                            .font(.caption).foregroundStyle(.secondary)
                        if entry?.countMismatch != nil {
                            Label("Count mismatch. Disappearance tracking is paused.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                            Text("Last list check finished \(date(snapshot.completedAt))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label("Tracking accounts verified by REST, GraphQL, and star history.",
                                  systemImage: "checkmark.seal")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Last complete check \(date(snapshot.completedAt))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        let noun = count == 1 ? "stargazer" : "stargazers"
                        Text("\(count) \(noun) · Last complete check \(date(snapshot.completedAt))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let issue = entry?.issue {
                        Text(issue).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let cleanupError = tracking.cleanupError {
                    Text(cleanupError).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: checkNow) {
                if tracking.checking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text("Checking…")
                    }
                } else {
                    Label("Check Now", systemImage: "arrow.clockwise")
                }
            }
            .disabled(paused || repo == nil)
        }
        .padding(16)
    }

    private var current: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search stargazers", text: $search).textFieldStyle(.plain)
                }
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button(loadingTotals ? "Loading star totals…" : "Load visible star totals", action: loadTotals)
                    .disabled(visible.isEmpty || paused || loadingTotals)
            }
            .padding([.horizontal, .bottom], 16)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                accountList
                if let selectedAccount {
                    Divider()
                    ScrollView {
                        profileCard(selectedAccount).padding(14)
                    }
                    .frame(width: 215)
                }
            }
            Divider()
            Text(accountCountLabel).font(.caption).foregroundStyle(.secondary).padding(10)
        }
    }

    private var accountList: some View {
        let accounts = filtered
        let selectedID = selectedAccount?.id
        return VStack(spacing: 0) {
            HStack {
                Text("Account")
                Spacer()
                Text("Stars received")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(9)
            Divider()
            if accounts.isEmpty {
                Text(search.isEmpty ? "No stargazers in this check" : "No matching stargazers")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                scrollableAccounts(accounts, selectedID: selectedID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func scrollableAccounts(_ accounts: [StargazerAccount], selectedID: Int64?) -> some View {
        GeometryReader { viewport in
            let bounds = CGRect(origin: .zero, size: viewport.size)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(accounts) { account in
                            Button { selection = account.id } label: {
                                accountRow(account, selected: account.id == selectedID)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(account.id == selectedID ? .isSelected : [])
                            .background {
                                GeometryReader { row in
                                    let frame = row.frame(in: .named("Stargazer accounts"))
                                    Color.clear.preference(key: VisibleStargazers.self,
                                        value: frame.intersects(bounds) ? [account.id] : [])
                                }
                            }
                        }
                    }
                    .padding(4)
                }
                .coordinateSpace(name: "Stargazer accounts")
                .scrollIndicators(.visible)
                .onPreferenceChange(VisibleStargazers.self) { visibleAccountIDs = $0 }
                .onChange(of: search) { _ in
                    if let first = accounts.first { reader.scrollTo(first.id, anchor: .top) }
                }
            }
        }
    }

    private func accountRow(_ account: StargazerAccount, selected: Bool) -> some View {
        let profile = tracking.profiles[account.id]
        let subtitle = [profile?.name, profile?.bio].compactMap { shortText($0) }.joined(separator: " · ")
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "@\(account.login)").fontWeight(.medium)
                if !subtitle.isEmpty {
                    Text(verbatim: subtitle).foregroundStyle(.secondary).font(.caption).lineLimit(1)
                }
            }
            Spacer()
            if let count = tracking.totals[account.id] {
                Text(count.formatted()).monospacedDigit()
            } else if tracking.unavailableTotals.contains(account.id) {
                Text("Unavailable").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 38)
        .background(selected ? Color.accentColor.opacity(0.17) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func profileCard(_ account: StargazerAccount) -> some View {
        let profile = tracking.profiles[account.id]
        let handle = "@\(profile?.login ?? account.login)"
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "person.crop.square").font(.title2).foregroundStyle(Color.accentColor)
            if let name = shortText(profile?.name) {
                Text(verbatim: name).font(.headline)
            }
            Text(verbatim: handle).font(.caption).foregroundStyle(.secondary)
            if let bio = shortText(profile?.bio) {
                Text(verbatim: bio)
            }
            if let stars = tracking.totals[account.id] {
                metric("Stars received", stars.formatted())
                if let measured = tracking.totalDates[account.id] {
                    Text("Owned public repos · \(date(measured))").font(.caption).foregroundStyle(.secondary)
                }
            } else if tracking.unavailableTotals.contains(account.id) {
                metric("Stars received", "Unavailable")
            }
            if let followers = profile?.followers { metric("Followers", followers.formatted()) }
            if let profile {
                Divider()
                let links = StargazerProfileLink.unique(profile.profileLinks + (tracking.socialLinks[account.id] ?? []))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 9) { ForEach(links, content: externalLink) }
                    VStack(alignment: .leading, spacing: 5) { ForEach(links, content: externalLink) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func externalLink(_ link: StargazerProfileLink) -> some View {
        Link(destination: link.url) {
            HStack(spacing: 3) {
                Text(link.label)
                Image(systemName: "arrow.up.right").accessibilityHidden(true)
            }
            .fixedSize()
        }
        .font(.caption)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).monospacedDigit()
        }
    }

    @ViewBuilder
    private var disappeared: some View {
        if entry?.history == nil {
            VStack(spacing: 8) {
                Text("Disappearance tracking is paused").font(.headline)
                Text("The last list check finished. Tracking starts after the account list passes verification.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            disappearanceHistory
        }
    }

    private var disappearanceHistory: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("These accounts appeared in one complete check and were missing in a later one. Unstarring, account deletion, suspension, or visibility changes can produce this result.",
                  systemImage: "info.circle")
                .foregroundStyle(.secondary)
                .padding([.horizontal, .bottom], 16)
            Divider()
            if events.isEmpty {
                Text("No disappearances detected yet").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: "@\(event.account.login)").fontWeight(.medium)
                                    Text(verbatim: event.repository).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                observation("Last seen", event.account.seenAt)
                                observation("First missing check", event.missingAt)
                            }
                            .padding(12)
                            Divider()
                        }
                    }
                }
            }
            Divider()
            Text("\(events.count) detections in retained history")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
    }

    private func observation(_ label: String, _ time: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(date(time)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accountCountLabel: String {
        let count = filtered.count
        return "\(count) \(count == 1 ? "account" : "accounts")"
    }

    private func loadTotals() {
        let ids = visible.map(\.id)
        loadingTotals = true
        totalsTask = Task {
            for id in ids {
                guard !Task.isCancelled else { return }
                await tracking.loadDetails(id, repoID: repoID, includeSocials: false)
            }
            if !Task.isCancelled { loadingTotals = false }
        }
    }

    private func stopLoadingTotals() {
        totalsTask?.cancel()
        totalsTask = nil
        loadingTotals = false
    }

    private func shortText(_ source: String?) -> String? {
        let clean = source?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        return clean.isEmpty ? nil : String(clean.prefix(300))
    }

    private func date(_ value: Date) -> String {
        value.formatted(date: .abbreviated, time: .shortened)
    }
}
