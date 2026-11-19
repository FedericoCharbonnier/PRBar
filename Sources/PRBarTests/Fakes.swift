import Foundation
import PRBarCore

final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    typealias Call = (executable: String, arguments: [String], environment: [String: String]?, currentDirectory: URL?, timeout: TimeInterval?)
    private let lock = NSLock()
    private var recorded: [Call] = []
    /// Las llamadas en orden. Se puede usar desde varias tareas a la vez.
    var calls: [Call] { lock.withLock { recorded } }
    private let handler: (String, [String]) -> ProcessResult

    init(_ handler: @escaping (String, [String]) -> ProcessResult) {
        self.handler = handler
    }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?, timeout: TimeInterval?) async throws -> ProcessResult {
        lock.withLock { recorded.append((executable, arguments, environment, currentDirectory, timeout)) }
        return handler(executable, arguments)
    }
}

final class FakeStreamingRunner: StreamingProcessRunning, @unchecked Sendable {
    typealias Call = (executable: String, arguments: [String], environment: [String: String]?, currentDirectory: URL?, timeout: TimeInterval?)
    private(set) var calls: [Call] = []
    /// Por llamada: si se pidió el entorno exacto (`runStreamingIsolated`) en vez de heredar el de la app.
    private(set) var isolated: [Bool] = []
    private let handler: (String, [String], URL?) throws -> (lines: [String], result: ProcessResult)
    /// Error que `runStreamingIsolated` lanza después de emitir las líneas (p. ej. un timeout a mitad de corrida).
    var failAfterOutput: Error?

    /// El handler recibe (executable, arguments, currentDirectory); si lanza, `runStreaming` relanza ese error.
    init(_ handler: @escaping (String, [String], URL?) throws -> (lines: [String], result: ProcessResult)) {
        self.handler = handler
    }

    func runStreaming(
        _ executable: String, _ arguments: [String],
        environment: [String: String]?, currentDirectory: URL?, timeout: TimeInterval?,
        onStdoutLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        calls.append((executable, arguments, environment, currentDirectory, timeout))
        isolated.append(false)
        let output = try handler(executable, arguments, currentDirectory)
        output.lines.forEach(onStdoutLine)
        return output.result
    }

    func runStreamingIsolated(
        _ executable: String, _ arguments: [String],
        environment: [String: String], currentDirectory: URL?, timeout: TimeInterval?,
        onStdoutLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        calls.append((executable, arguments, environment, currentDirectory, timeout))
        isolated.append(true)
        let output = try handler(executable, arguments, currentDirectory)
        output.lines.forEach(onStdoutLine)
        if let failAfterOutput { throw failAfterOutput }
        return output.result
    }
}

/// Caja mutable para capturar valores desde closures en los tests.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Runner falso que se porta como `SystemProcessRunner` ante la cancelación: si la tarea que llama ya está
/// cancelada, lanza `CancellationError` sin correr nada; `slow` decide qué llamadas quedan "colgadas"
/// (hasta que se cancele la tarea). Guarda cada llamada y si se hizo desde una tarea cancelada.
final class CancellableFakeRunner: ProcessRunning, @unchecked Sendable {
    typealias Call = (arguments: [String], cancelled: Bool)
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.withLock { recorded } }
    private let slow: @Sendable ([String]) -> Bool
    private let handler: @Sendable ([String]) -> ProcessResult
    /// Se llama (sin lock) cuando una llamada lenta empieza a esperar.
    let onSlowStart: @Sendable ([String]) -> Void

    init(slow: @escaping @Sendable ([String]) -> Bool, onSlowStart: @escaping @Sendable ([String]) -> Void = { _ in },
         _ handler: @escaping @Sendable ([String]) -> ProcessResult) {
        self.slow = slow
        self.onSlowStart = onSlowStart
        self.handler = handler
    }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?, timeout: TimeInterval?) async throws -> ProcessResult {
        let cancelled = Task.isCancelled
        lock.withLock { recorded.append((arguments, cancelled)) }
        if cancelled { throw CancellationError() }
        if slow(arguments) {
            onSlowStart(arguments)
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        return handler(arguments)
    }
}

/// SHA que devuelven `git rev-parse` y `gh pr view` en los fakes: el commit que se trajo de verdad, distinto
/// del `headOid` del snapshot de los fixtures.
let fetchedSHA = "f00dfeed00000000000000000000000000c0ffee"

/// Runner de git/gh para el pipeline: `rev-parse` y `gh pr view` devuelven `fetchedSHA`; el resto va a `handler`.
func gitFake(_ handler: @escaping (String, [String]) -> ProcessResult = { _, _ in ok("") }) -> FakeProcessRunner {
    FakeProcessRunner { executable, args in
        if args.contains("rev-parse") || (args.first == "pr" && args.dropFirst().first == "view") { return ok(fetchedSHA + "\n") }
        return handler(executable, args)
    }
}

func ok(_ stdout: String) -> ProcessResult { ProcessResult(status: 0, stdout: stdout, stderr: "") }
func fail(_ stderr: String, status: Int32 = 1) -> ProcessResult { ProcessResult(status: status, stdout: "", stderr: stderr) }

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    private var responses: [(status: Int, headers: [String: String], body: String)]

    init(_ responses: [(status: Int, headers: [String: String], body: String)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let next = responses.isEmpty ? (status: 500, headers: [:], body: "{}") : responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: next.headers)!
        return (Data(next.body.utf8), response)
    }

    func bodyString(_ index: Int) -> String {
        String(decoding: requests[index].httpBody ?? Data(), as: UTF8.self)
    }
}

struct FakeAPI: GitHubAPI {
    var prs: [String: Result<RepoPRs, PRBarError>] = [:]
    /// Errores que no son `PRBarError` (p. ej. `URLError`), por repo.
    var rawErrors: [String: Error] = [:]
    /// Repos pedidos a `openPullRequests`, en orden.
    let calls = Box<[String]>([])

    func openPullRequests(in repo: RepoRef, token: String) async throws -> RepoPRs {
        calls.value.append(repo.fullName)
        if let error = rawErrors[repo.fullName] { throw error }
        guard let result = prs[repo.fullName] else { throw PRBarError.http(status: 404, message: "not found") }
        return try result.get()
    }
    func viewerRepositories(token: String) async throws -> [RepoRef] { [] }
    func branches(of repo: RepoRef, token: String) async throws -> [String] { [] }
    func assignableUsers(of repo: RepoRef, token: String) async throws -> [GitHubUser] { [] }
    func defaultBranch(of repo: RepoRef, token: String) async throws -> String { "main" }
    func user(login: String, token: String) async throws -> GitHubUser? { nil }
    func pullRequestFiles(repo: RepoRef, number: Int, token: String) async throws -> [PRFile] { [] }
    /// What `pullRequestDetails` returns (no description by default).
    var details: Result<PRDetails, PRBarError> = .success(PRDetails(title: "PR", body: "", headOid: nil))
    /// Tokens `pullRequestDetails` was called with.
    let detailsTokens = Box<[String]>([])

    func pullRequestDetails(repo: RepoRef, number: Int, token: String) async throws -> PRDetails {
        detailsTokens.value.append(token)
        return try details.get()
    }
    func submitReview(repo: RepoRef, number: Int, submission: ReviewSubmission, token: String) async throws -> URL {
        URL(string: "https://github.com/\(repo.fullName)/pull/\(number)#pullrequestreview-1")!
    }
    func reviewFeedback(repo: RepoRef, number: Int, token: String) async throws -> PRFeedback {
        PRFeedback(
            headRefName: "feature", headRefOid: "abc", isCrossRepository: false, lastCommitAt: Date(timeIntervalSince1970: 0),
            threads: [], reviews: [])
    }
    func replyToReviewComment(repo: RepoRef, number: Int, commentID: Int, body: String, token: String) async throws -> URL {
        URL(string: "https://github.com/\(repo.fullName)/pull/\(number)#discussion_r\(commentID)")!
    }
    func addIssueComment(repo: RepoRef, number: Int, body: String, token: String) async throws -> URL {
        URL(string: "https://github.com/\(repo.fullName)/pull/\(number)#issuecomment-1")!
    }
}

struct FakeTokens: TokenProviding {
    var failing: Set<String> = []

    func token(for login: String) async throws -> String {
        if failing.contains(login) { throw PRBarError.unauthorized }
        return "tok-\(login)"
    }
}

func account(_ login: String, watching: [String] = ["juan"], bases: [String] = [], enabled: Bool = true) -> AccountConfig {
    AccountConfig(login: login, enabled: enabled, repos: [RepoConfig(owner: "o", name: "r", baseBranches: bases, watchedUsers: watching)])
}

func config(_ accounts: AccountConfig...) -> AppConfig {
    var config = AppConfig()
    config.accounts = accounts
    return config
}

final class FakeSlackAPI: SlackAPI, @unchecked Sendable {
    private(set) var posts: [(channel: String, text: String, threadTS: String?)] = []
    private(set) var tokens: [String] = []
    /// Resultados por post, en orden; sin resultados programados devuelve "ts-<n>".
    var results: [Result<String, PRBarError>] = []
    /// Se llama durante cada post (con su número, desde 1), mientras el announcer está suspendido esperándolo.
    var onPost: (@Sendable (Int) async -> Void)?

    func postMessage(channel: String, text: String, threadTS: String?, token: String) async throws -> String {
        posts.append((channel, text, threadTS))
        tokens.append(token)
        if let onPost { await onPost(posts.count) }
        if !results.isEmpty { return try results.removeFirst().get() }
        return "ts-\(posts.count)"
    }

    /// Canal real que devuelve `postMessageResult` (p. ej. el `D…` de un DM).
    var postedChannel: String?

    func postMessageResult(channel: String, text: String, threadTS: String?, token: String) async throws -> SlackPostResult {
        SlackPostResult(ts: try await postMessage(channel: channel, text: text, threadTS: threadTS, token: token), channel: postedChannel)
    }

    private(set) var authCalls = 0
    var authError: PRBarError?

    func authTest(token: String) async throws -> SlackIdentity {
        authCalls += 1
        if let authError { throw authError }
        return SlackIdentity(team: "Acme", user: "prbar", userID: "U1")
    }

    /// Mensajes por hilo (`canal/ts`) que devuelve `threadReplies`.
    var threads: [String: [SlackMessage]] = [:]
    private(set) var threadCalls: [(channel: String, ts: String)] = []
    var threadError: PRBarError?

    func threadReplies(channel: String, ts: String, token: String) async throws -> [SlackMessage] {
        threadCalls.append((channel, ts))
        if let threadError { throw threadError }
        return threads["\(channel)/\(ts)"] ?? []
    }
    func channels(token: String) async throws -> SlackChannelList { SlackChannelList(channels: [], truncated: false) }

    /// Mensajes raíz por canal que devuelve `history`.
    var messages: [String: [SlackMessage]] = [:]
    private(set) var historyCalls: [(channel: String, oldest: Date)] = []
    /// Error por canal para `history`.
    var historyErrors: [String: PRBarError] = [:]

    func history(channel: String, oldest: Date, token: String) async throws -> [SlackMessage] {
        historyCalls.append((channel, oldest))
        tokens.append(token)
        if let error = historyErrors[channel] { throw error }
        return messages[channel] ?? []
    }

    private(set) var reactions: [(channel: String, ts: String, name: String)] = []
    /// Error por nombre de emoji para `addReaction`.
    var reactionErrors: [String: PRBarError] = [:]
    /// Se llama durante cada reacción (con su número, desde 1).
    var onReaction: (@Sendable (Int) async -> Void)?

    func addReaction(channel: String, ts: String, name: String, token: String) async throws {
        reactions.append((channel, ts, name))
        tokens.append(token)
        if let onReaction { await onReaction(reactions.count) }
        if let error = reactionErrors[name] { throw error }
    }
}

final class FakeSecrets: SecretStore, @unchecked Sendable {
    private var values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    /// Lecturas del valor (las que en el Llavero real pueden pedir permiso).
    private(set) var reads = 0
    private(set) var existsChecks = 0

    func read(_ key: String) throws -> String? {
        reads += 1
        return values[key]
    }

    func exists(_ key: String) throws -> Bool {
        existsChecks += 1
        return values[key]?.isEmpty == false
    }

    func write(_ value: String?, for key: String) throws {
        values[key] = value
    }

    /// Valor guardado, sin contar como lectura.
    func peek(_ key: String) -> String? { values[key] }
}

/// GitHub falso para "Responder": `feedback` programable y graba cada respuesta publicada. `failPosts` tiene
/// los números de post (desde 1, contando todos los intentos) que fallan con un 502.
final class FakeFeedbackAPI: GitHubAPI, @unchecked Sendable {
    enum Post: Equatable { case reply(commentID: Int, body: String), issue(body: String) }

    private let lock = NSLock()
    private var recorded: [Post] = []
    private var recordedTokens: [String] = []
    private var attempts = 0
    var feedback: PRFeedback
    var feedbackError: Error?
    /// What `pullRequestDetails` returns (Spanish by default, like the rest of the fixtures).
    var details = PRDetails(
        title: "Limitar los pedidos por IP",
        body: "Este PR agrega un límite de pedidos por dirección IP para frenar los abusos del endpoint de login.",
        headOid: nil)
    var detailsError: Error?
    /// Calls to `pullRequestDetails`.
    private(set) var detailsCalls = 0
    var failPosts: Set<Int> = []
    /// Se llama antes de cada intento de post, con su número (desde 1).
    var beforePost: (@Sendable (Int) -> Void)?

    init(feedback: PRFeedback = PRFeedback(headRefName: "feature/7", headRefOid: "abc", isCrossRepository: false,
                                           lastCommitAt: Date(timeIntervalSince1970: 0), threads: [], reviews: [])) {
        self.feedback = feedback
    }

    /// Los posts que se publicaron (sin los que fallaron), en orden.
    var posts: [Post] { lock.withLock { recorded } }
    var tokens: [String] { lock.withLock { recordedTokens } }

    private func post(_ post: Post, token: String) throws -> Int {
        let attempt = lock.withLock { attempts + 1 }
        beforePost?(attempt)
        return try lock.withLock {
            attempts += 1
            recordedTokens.append(token)
            if failPosts.contains(attempts) { throw PRBarError.http(status: 502, message: "Bad Gateway") }
            recorded.append(post)
            return recorded.count
        }
    }

    func openPullRequests(in repo: RepoRef, token: String) async throws -> RepoPRs { throw PRBarError.http(status: 404, message: "no") }
    func viewerRepositories(token: String) async throws -> [RepoRef] { [] }
    func branches(of repo: RepoRef, token: String) async throws -> [String] { [] }
    func defaultBranch(of repo: RepoRef, token: String) async throws -> String { "main" }
    func assignableUsers(of repo: RepoRef, token: String) async throws -> [GitHubUser] { [] }
    func user(login: String, token: String) async throws -> GitHubUser? { nil }
    func pullRequestFiles(repo: RepoRef, number: Int, token: String) async throws -> [PRFile] { [] }
    func pullRequestDetails(repo: RepoRef, number: Int, token: String) async throws -> PRDetails {
        lock.withLock { detailsCalls += 1 }
        if let detailsError { throw detailsError }
        return details
    }
    func submitReview(repo: RepoRef, number: Int, submission: ReviewSubmission, token: String) async throws -> URL {
        throw PRBarError.http(status: 500, message: "no se usa")
    }
    func reviewFeedback(repo: RepoRef, number: Int, token: String) async throws -> PRFeedback {
        if let feedbackError { throw feedbackError }
        return feedback
    }
    func replyToReviewComment(repo: RepoRef, number: Int, commentID: Int, body: String, token: String) async throws -> URL {
        let n = try post(.reply(commentID: commentID, body: body), token: token)
        return URL(string: "https://github.com/\(repo.fullName)/pull/\(number)#discussion_r\(commentID)-\(n)")!
    }
    func addIssueComment(repo: RepoRef, number: Int, body: String, token: String) async throws -> URL {
        let n = try post(.issue(body: body), token: token)
        return URL(string: "https://github.com/\(repo.fullName)/pull/\(number)#issuecomment-\(n)")!
    }
}
