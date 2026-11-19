import Foundation
import PRBarCore

/// Listas de GitHub que usa Configuración (repos de la cuenta, ramas, usuarios asignables), cacheadas en
/// memoria durante la sesión para no repetir la paginación cada vez que se abre un selector.
@MainActor
final class GitHubCatalog: ObservableObject {
    struct Entry<Value> {
        var value: Value
        var state: PickerLoadState
    }

    struct Branches: Equatable {
        var names: [String] = []
        var defaultBranch: String?
    }

    @Published private(set) var repos: [String: Entry<[RepoRef]>] = [:]
    @Published private(set) var branches: [String: Entry<Branches>] = [:]
    @Published private(set) var assignable: [String: Entry<[GitHubUser]>] = [:]

    private let api: GitHubAPI
    private let tokens: TokenProviding

    init(api: GitHubAPI, tokens: TokenProviding) {
        self.api = api
        self.tokens = tokens
    }

    // MARK: Repos de la cuenta

    func repos(for login: String) -> Entry<[RepoRef]> {
        repos[login] ?? Entry(value: [], state: .loading)
    }

    /// Sin `force`, no vuelve a pedir lo que ya se cargó (o se está cargando) en esta sesión; solo reintenta fallos.
    func loadRepos(for login: String, force: Bool = false) async {
        guard !login.isEmpty else { return }
        if !force, let entry = repos[login], !entry.state.isFailed { return }
        repos[login] = Entry(value: repos[login]?.value ?? [], state: .loading)
        do {
            let token = try await tokens.token(for: login)
            let list = try await api.viewerRepositories(token: token)
            repos[login] = Entry(value: list, state: .loaded)
        } catch {
            repos[login] = Entry(value: repos[login]?.value ?? [], state: .failed("Couldn’t load your repos: \(error.localizedDescription)"))
        }
    }

    // MARK: Ramas

    func branches(for login: String, repo: RepoRef) -> Entry<Branches> {
        branches[Self.key(login, repo)] ?? Entry(value: Branches(), state: .loading)
    }

    func loadBranches(for login: String, repo: RepoRef, force: Bool = false) async {
        let key = Self.key(login, repo)
        if !force, let entry = branches[key], !entry.state.isFailed { return }
        branches[key] = Entry(value: branches[key]?.value ?? Branches(), state: .loading)
        do {
            let token = try await tokens.token(for: login)
            async let names = api.branches(of: repo, token: token)
            async let defaultBranch = api.defaultBranch(of: repo, token: token)
            let value = Branches(names: try await names, defaultBranch: try? await defaultBranch)
            branches[key] = Entry(value: value, state: .loaded)
        } catch {
            branches[key] = Entry(value: Branches(), state: .failed("Couldn’t load branches: \(error.localizedDescription)"))
        }
    }

    // MARK: Usuarios asignables

    func assignableUsers(for login: String, repo: RepoRef) -> Entry<[GitHubUser]> {
        assignable[Self.key(login, repo)] ?? Entry(value: [], state: .loading)
    }

    func loadAssignableUsers(for login: String, repo: RepoRef, force: Bool = false) async {
        let key = Self.key(login, repo)
        if !force, let entry = assignable[key], !entry.state.isFailed { return }
        assignable[key] = Entry(value: assignable[key]?.value ?? [], state: .loading)
        do {
            let token = try await tokens.token(for: login)
            let users = try await api.assignableUsers(of: repo, token: token)
            assignable[key] = Entry(value: users, state: .loaded)
        } catch {
            assignable[key] = Entry(value: [], state: .failed("Couldn’t load users: \(error.localizedDescription)"))
        }
    }

    private static func key(_ login: String, _ repo: RepoRef) -> String { "\(login)|\(repo.fullName)" }
}
