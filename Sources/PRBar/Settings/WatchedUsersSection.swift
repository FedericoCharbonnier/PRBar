import PRBarCore
import SwiftUI

/// Un usuario sugerido para seguir en un repo, con cuántos PRs abiertos suyos hay en el snapshot.
struct UserSuggestion: Identifiable {
    let user: GitHubUser
    let openPRs: Int
    var id: String { user.login.lowercased() }

    /// Unión de los usuarios asignables del repo y los autores de sus PRs en el snapshot, sin la cuenta,
    /// sin bots y sin los que ya se siguen. Ordenados por PRs abiertos (desc) y después por login.
    static func build(assignable: [GitHubUser], snapshotPRs: [PullRequest], me: String, watched: [String]) -> [UserSuggestion] {
        var users: [String: GitHubUser] = [:]
        var counts: [String: Int] = [:]
        for user in assignable {
            users[user.login.lowercased()] = user
        }
        for pr in snapshotPRs {
            let key = pr.author.lowercased()
            counts[key, default: 0] += 1
            if users[key] == nil {
                users[key] = GitHubUser(login: pr.author, name: nil, avatarURL: pr.authorAvatarURL)
            }
        }
        let excluded = Set(watched.map { $0.lowercased() } + [me.lowercased(), "ghost"])
        return users
            .filter { !excluded.contains($0.key) && !isBot($0.value.login) }
            .map { UserSuggestion(user: $0.value, openPRs: counts[$0.key] ?? 0) }
            .sorted { a, b in
                if a.openPRs != b.openPRs { return a.openPRs > b.openPRs }
                return a.user.login.localizedCaseInsensitiveCompare(b.user.login) == .orderedAscending
            }
    }

    private static let knownBots: Set<String> = ["dependabot", "renovate", "github-actions", "copilot", "codecov", "snyk-bot"]

    static func isBot(_ login: String) -> Bool {
        let lower = login.lowercased()
        return lower.hasSuffix("[bot]") || lower.hasSuffix("-bot") || knownBots.contains(lower)
    }
}

/// Sección "Usuarios a seguir" del detalle de un repo: los seguidos (con ✕) y un selector con sugerencias.
struct WatchedUsersSection: View {
    let model: AppModel
    @ObservedObject var catalog: GitHubCatalog
    @ObservedObject var prStore: PRStore
    let login: String
    let repo: RepoConfig

    var body: some View {
        let entry = catalog.assignableUsers(for: login, repo: repo.repo)
        Section {
            ForEach(repo.watchedUsers, id: \.self) { user in
                watchedRow(user, known: entry.value.first { $0.login.caseInsensitiveCompare(user) == .orderedSame })
            }
            SearchablePickerPopover(
                mode: .single,
                items: suggestions(entry.value),
                loadState: entry.state,
                placeholder: "Search users…",
                width: 300,
                title: \.user.login,
                subtitle: subtitle,
                avatar: { AnyView(AvatarView(login: $0.user.login, url: $0.user.avatarURL ?? Self.avatarURL($0.user.login), size: 20)) },
                freeform: .init(title: { "Add “\($0)”" }, submit: addTyped),
                onRetry: { Task { await catalog.loadAssignableUsers(for: login, repo: repo.repo, force: true) } },
                onPick: { add($0.user.login) }
            ) {
                Label("Add User…", systemImage: "person.badge.plus")
            }
            .help("Choose someone to follow in this repo")
        } header: {
            Text("People to follow")
        } footer: {
            Text(repo.watchedUsers.isEmpty
                 ? "No one yet: only PRs in this repo where your review is requested will show up."
                 : "Their PRs in this repo show up in “To Review”.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: "\(login)|\(repo.id)") { await catalog.loadAssignableUsers(for: login, repo: repo.repo) }
    }

    private func watchedRow(_ user: String, known: GitHubUser?) -> some View {
        HStack(spacing: 8) {
            AvatarView(login: user, url: known?.avatarURL ?? Self.avatarURL(user), size: 20)
            Text(user).lineLimit(1)
            if let name = known?.name, !name.isEmpty {
                Text(name).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            IconButton(systemImage: "xmark", help: "Unfollow \(user)", size: 10, weight: .semibold) {
                model.updateConfig { $0.removeWatchedUser(user, repoID: repo.id, login: login) }
            }
        }
    }

    private func subtitle(_ suggestion: UserSuggestion) -> String? {
        let prs = switch suggestion.openPRs {
        case 0: nil as String?
        case 1: "1 open PR"
        default: "\(suggestion.openPRs) open PRs"
        }
        return [suggestion.user.name, prs].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func suggestions(_ assignable: [GitHubUser]) -> [UserSuggestion] {
        let prs = prStore.snapshot?.items.map(\.pr).filter { $0.repo == repo.repo } ?? []
        return UserSuggestion.build(assignable: assignable, snapshotPRs: prs, me: login, watched: repo.watchedUsers)
    }

    private func add(_ user: String) {
        model.updateConfig { $0.addWatchedUser(user, repoID: repo.id, login: login) }
    }

    /// Valida el login escrito contra GitHub antes de agregarlo; devuelve el error para mostrar en línea.
    private func addTyped(_ text: String) async -> String? {
        let name = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        do {
            let token = try await model.accounts.token(for: login)
            guard let user = try await model.api.user(login: name, token: token) else {
                return "There’s no GitHub user named \(name)."
            }
            add(user.login)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func avatarURL(_ login: String) -> URL? {
        URL(string: "https://github.com/\(login).png?size=64")
    }
}
