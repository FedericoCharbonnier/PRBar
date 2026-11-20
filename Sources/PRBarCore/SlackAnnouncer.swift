import Foundation

/// Ejecuta el plan de Slack después de cada refresco y publica los problemas para la UI (spec §15).
@MainActor
public final class SlackAnnouncer: ObservableObject {
    /// Cuenta del Llavero con el User OAuth Token (`xoxp-…`), spec §17.
    public static let tokenKey = "user-token"
    /// Cuenta del token de bot de §15: se borra al migrar.
    public static let legacyTokenKey = "bot-token"

    @Published public private(set) var issues: [RefreshIssue] = []
    @Published public private(set) var hasToken = false
    /// Había un token de bot (§15) que se borró al migrar y todavía no se pegó el token de usuario.
    @Published public private(set) var needsUserToken = false
    /// Sube con cada `saveToken` o cambio de provider: la UI lo usa para recargar lo que depende de la conexión
    /// (p. ej. los canales).
    @Published public private(set) var tokenRevision = 0
    /// Cómo se habla con Slack (spec §17.5). Con el conector de Claude no hay token.
    @Published public private(set) var provider: SlackProvider

    private var api: SlackAPI
    /// Canales de la última carga exitosa: con el conector cada carga es una corrida de Claude, así que las pestañas
    /// de los repos comparten esta lista hasta que se recargue a mano o cambie la conexión.
    private var cachedChannels: SlackChannelList?
    private let secrets: SecretStore
    private let stateStore: SlackStateStore
    private let now: () -> Date
    private var state: SlackState
    private var isRunning = false
    /// Última configuración recibida; se consulta antes de cada post.
    private var latestConfig: AppConfig?
    private var pending: (snapshot: Snapshot, config: AppConfig)?
    /// Último snapshot procesado: `reviewStarted` lo usa como base.
    private var lastSnapshot: Snapshot?
    /// El token se lee del Llavero una sola vez (cada lectura puede pedir permiso al usuario) y se
    /// actualiza al guardarlo. `tokenLoaded == false` significa "todavía no se leyó".
    private var cachedToken: String?
    private var tokenLoaded = false
    /// Último error de cada PR en backoff, para seguir mostrándolo mientras se espera.
    private var backoffErrors: [String: PRBarError] = [:]

    public init(api: SlackAPI, provider: SlackProvider = .userToken, secrets: SecretStore,
                stateStore: SlackStateStore = SlackStateStore(), now: @escaping () -> Date = { Date() }) {
        self.api = api
        self.provider = provider
        self.secrets = secrets
        self.stateStore = stateStore
        self.now = now
        self.state = stateStore.load(now: now())
        // Solo atributos: no lee el secreto, así abrir la app no pide permiso al Llavero.
        self.hasToken = (try? secrets.exists(Self.tokenKey)) ?? false
        migrateLegacyToken()
        self.needsUserToken = state.needsUserToken && !hasToken
    }

    /// PRBar ya no publica como bot (spec §17): el token de bot se borra sin leerlo y, si no hay token de usuario,
    /// la UI lo pide. El estado de anuncios se conserva.
    private func migrateLegacyToken() {
        guard (try? secrets.exists(Self.legacyTokenKey)) == true else { return }
        do {
            try secrets.write(nil, for: Self.legacyTokenKey)
            AppLog.write("Slack: removed the old bot token; PRBar now posts as the user")
        } catch {
            AppLog.write("Slack: couldn't remove the old bot token: \(error)")
        }
        guard !hasToken else { return }
        state.needsUserToken = true
        do {
            try stateStore.save(state)
        } catch {
            AppLog.write("Couldn't save slack-state.json: \(error)")
        }
    }

    public func process(snapshot: Snapshot, config: AppConfig) async {
        latestConfig = config
        guard config.slack.enabled else {
            issues = []
            pending = nil
            return
        }
        // Si ya hay una corrida, este pedido queda pendiente (solo el último) y se corre al terminar.
        guard !isRunning else {
            pending = (snapshot, config)
            return
        }
        isRunning = true
        defer { isRunning = false }

        var next: (snapshot: Snapshot, config: AppConfig)? = (snapshot, config)
        while let current = next {
            pending = nil
            // Los `claude` del conector salen en la ventana Activity como "Slack" (spec I).
            await ProcessActivity.$current.withValue(.slack) {
                await run(snapshot: current.snapshot, config: current.config)
            }
            next = pending
        }
    }

    private func run(snapshot: Snapshot, config: AppConfig) async {
        lastSnapshot = snapshot
        if state.pruneMergedReplies(now: now()) { saveState() }
        var newIssues: [RefreshIssue] = []
        var saveError: PRBarError?
        func persist() {
            do {
                try stateStore.save(state)
            } catch {
                AppLog.write("Couldn't save slack-state.json: \(error)")
                saveError = .stateNotSaved(error.localizedDescription)
            }
        }
        func report(_ error: PRBarError, for action: SlackAction, detail: String? = nil) {
            newIssues.append(RefreshIssue(account: "slack", repo: action.repo, error: error, detail: detail ?? action.channelName))
            AppLog.write("Slack failed for \(action.prID): \(error)")
        }

        let connector = provider == .claudeConnector
        var token: String?
        var tokenChecked = false
        /// Historial por canal dentro de esta corrida: varios PRs del mismo canal hacen una sola búsqueda.
        var histories: [String: Result<[SlackMessage], PRBarError>] = [:]
        var failedHistories: Set<String> = []
        var stopped = false
        /// En la segunda pasada solo se ejecutan las acciones de los PRs cuyo mensaje se acaba de encontrar: lo que
        /// falló en la primera no se reintenta en el mismo ciclo.
        var onlyPRs: Set<String>?
        /// PRs en backoff cuyo último error ya se mostró en este ciclo.
        var reportedBackoff: Set<String> = []

        func channelHistory(_ channelID: String, token: String) async -> Result<[SlackMessage], PRBarError> {
            if let cached = histories[channelID] { return cached }
            let oldest = now().addingTimeInterval(-TimeInterval(config.slack.effectiveSearchDays) * 86_400)
            let history: Result<[SlackMessage], PRBarError>
            do {
                history = .success(try await api.history(channel: channelID, oldest: oldest, token: token))
            } catch {
                history = .failure(Self.prbarError(error))
            }
            histories[channelID] = history
            return history
        }

        /// Mi mensaje raíz con el link del PR, si ya está en el canal (spec §17.5, anti-duplicados).
        func existingAnnouncement(prID: String, channelID: String, token: String) async throws -> String? {
            guard let prURL = snapshot.items.first(where: { $0.pr.id == prID })?.pr.url else { return nil }
            let me = try await selfUserID(token: token)
            let messages = try await channelHistory(channelID, token: token).get()
            return messages
                .filter { $0.user == me && PRLinkMatcher.matches($0, prURL: prURL) }
                .min { (Double($0.ts) ?? .infinity) < (Double($1.ts) ?? .infinity) }?.ts
        }

        /// Mi respuesta con el mismo texto en el hilo, publicada desde el primer intento (con 2 minutos de margen
        /// por relojes): así un "Updated" de una ronda anterior no cuenta.
        func existingReply(channelID: String, threadTS: String, text: String, since: Date, token: String) async throws -> Bool {
            let me = try await selfUserID(token: token)
            let target = SlackText.comparable(text)
            let floor = since.timeIntervalSince1970 - 120
            return try await api.threadReplies(channel: channelID, ts: threadTS, token: token).contains {
                $0.ts != threadTS && $0.user == me && (Double($0.ts) ?? 0) >= floor && SlackText.comparable($0.text) == target
            }
        }

        /// Marca la escritura como empezada (y la guarda) antes de hacerla.
        func begin(_ action: SlackAction) {
            guard let key = SlackState.uncertainKey(for: action) else { return }
            if state.uncertain[key] == nil { state.uncertain[key] = now() }
            persist()
        }

        func succeeded(_ action: SlackAction) {
            if let key = SlackState.uncertainKey(for: action) { state.uncertain[key] = nil }
            state.backoff[action.prID] = nil
            backoffErrors[action.prID] = nil
        }
        // Después de encontrar el mensaje de un PR se vuelve a planificar, así sus reacciones salen en este mismo
        // ciclo. Las búsquedas recién hechas no se repiten (lastSearchAt), así que alcanza con dos pasadas.
        while true {
            var plan = SlackPlanner.plan(snapshot: snapshot, config: config, state: state, now: now())
            if let onlyPRs { plan.actions.removeAll { !onlyPRs.contains($0.prID) } }
            if onlyPRs == nil && !plan.newDrafts.isEmpty {
                let seenAt = now()
                for id in plan.newDrafts { state.seenAsDraft[id] = seenAt }
                persist()
            }

            // El token se toca solo si hay algo que mandar.
            if !tokenChecked && (!isConnected || !plan.actions.isEmpty) {
                tokenChecked = true
                if !isConnected {
                    newIssues.append(RefreshIssue(account: "slack", repo: nil, error: .slack("missing_token")))
                } else {
                    do {
                        token = try requireToken()
                    } catch {
                        newIssues.append(RefreshIssue(account: "slack", repo: nil, error: Self.prbarError(error)))
                    }
                }
            }

            var found: Set<String> = []
            for action in plan.actions {
                // Si Slack se apagó mientras se esperaba un envío anterior, no se manda nada más.
                guard let token, latestConfig?.slack.enabled == true else { stopped = true; break }
                if connector, let backoff = state.backoff[action.prID], backoff.until > now() {
                    if reportedBackoff.insert(action.prID).inserted, let error = backoffErrors[action.prID] { report(error, for: action) }
                    continue
                }
                let uncertainSince = SlackState.uncertainKey(for: action).flatMap { state.uncertain[$0] }
                do {
                    switch action {
                    case .announce(let prID, _, let channelID, _, let text):
                        // Con el conector siempre, y con token si un intento anterior quedó dudoso: primero se mira
                        // si el anuncio ya está en el canal.
                        if connector || uncertainSince != nil,
                           let ts = try await existingAnnouncement(prID: prID, channelID: channelID, token: token) {
                            AppLog.write("Slack: \(prID) is already announced in \(channelID) (\(ts)); not posting it again")
                            state.announcements[prID] = SlackAnnouncement(channelID: channelID, ts: ts, announcedAt: now())
                        } else {
                            begin(action)
                            let ts = try await api.postMessage(channel: channelID, text: text, threadTS: nil, token: token)
                            state.announcements[prID] = SlackAnnouncement(channelID: channelID, ts: ts, announcedAt: now())
                        }
                    case .update(let prID, _, let channelID, _, let threadTS, let text, let handledReviewAt):
                        if let since = uncertainSince,
                           try await existingReply(channelID: channelID, threadTS: threadTS, text: text, since: since, token: token) {
                            AppLog.write("Slack: the “Updated” reply for \(prID) is already in the thread; not posting it again")
                        } else {
                            begin(action)
                            _ = try await api.postMessage(channel: channelID, text: text, threadTS: threadTS, token: token)
                        }
                        state.announcements[prID]?.lastHandledReviewAt = handledReviewAt
                    case .findMessage(let prID, _, let channelID, _, let prURL):
                        let searchedAt = now()
                        let history = await channelHistory(channelID, token: token)
                        // Con o sin resultado, la búsqueda queda registrada: sin mensaje se reintenta en 10 minutos.
                        state.reviewTracking[prID, default: ReviewTracking()].lastSearchAt = searchedAt
                        switch history {
                        case .success(let messages):
                            if let ref = Self.oldestMatch(messages, prURL: prURL, channelID: channelID) {
                                state.reviewTracking[prID]?.message = ref
                                found.insert(prID)
                            }
                        case .failure(let error):
                            // Un solo issue por canal aunque varios PRs lo compartan.
                            guard failedHistories.insert(channelID).inserted else { persist(); continue }
                            throw error
                        }
                    case .react(let prID, _, _, let ref, let emoji, let kind):
                        try await api.addReaction(channel: ref.channelID, ts: ref.ts, name: emoji, token: token)
                        state.reviewTracking[prID, default: ReviewTracking()].reacted.insert(kind.rawValue)
                        state.reviewTracking[prID]?.failedEmoji[kind.rawValue] = nil
                        if kind == .eyes { state.reviewTracking[prID]?.pendingEyes = false }
                    case .reply(let prID, _, _, let ref, let text, let round):
                        if let since = uncertainSince,
                           try await existingReply(channelID: ref.channelID, threadTS: ref.ts, text: text, since: since, token: token) {
                            AppLog.write("Slack: “\(text)” for \(prID) is already in the thread; not posting it again")
                        } else {
                            begin(action)
                            _ = try await api.postMessage(channel: ref.channelID, text: text, threadTS: ref.ts, token: token)
                        }
                        let posted = state.reviewTracking[prID]?.roundsPosted ?? 0
                        state.reviewTracking[prID, default: ReviewTracking()].roundsPosted = max(posted, round)
                    case .merged(let prID, _, let channelID, let threadTS, let text):
                        // Igual que "Updated": si un intento anterior quedó dudoso, primero se mira el hilo.
                        if let since = uncertainSince,
                           try await existingReply(channelID: channelID, threadTS: threadTS, text: text, since: since, token: token) {
                            AppLog.write("Slack: the “Merged” reply for \(prID) is already in the thread; not posting it again")
                        } else {
                            begin(action)
                            _ = try await api.postMessage(channel: channelID, text: text, threadTS: threadTS, token: token)
                        }
                        state.mergedReplies[prID]?.postedAt = now()
                    }
                    succeeded(action)
                    persist()
                } catch {
                    let prbarError = Self.prbarError(error)
                    handleFailure(prbarError, for: action)
                    if let key = SlackState.uncertainKey(for: action), state.uncertain[key] != nil,
                       !Self.keepsUncertainMarker(prbarError, connector: connector) {
                        state.uncertain[key] = nil
                    }
                    if connector && prbarError != .slack("invalid_name") {
                        state.backoff[action.prID] = SlackBackoff.next(after: state.backoff[action.prID], now: now())
                        backoffErrors[action.prID] = prbarError
                        reportedBackoff.insert(action.prID)
                    }
                    persist()
                    // El emoji inexistente queda como issue persistente (abajo), no uno por acción.
                    if case .react(_, _, _, _, _, _) = action, prbarError == .slack("invalid_name") { continue }
                    report(prbarError, for: action, detail: Self.issueDetail(prbarError, for: action))
                    if Self.stopsCycle(prbarError) { stopped = true; break }
                }
            }
            if stopped || found.isEmpty || onlyPRs != nil { break }
            onlyPRs = found
        }
        newIssues += invalidEmojiIssues(config: config)
        if let saveError { newIssues.append(RefreshIssue(account: "slack", repo: nil, error: saveError)) }
        issues = latestConfig?.slack.enabled == true ? newIssues : []
    }

    /// Si después de este error hay que comprobar en Slack antes de reintentar. Con el conector, siempre: el texto
    /// de un error no prueba que no se haya escrito nada. Con token, salvo los errores que Slack contestó.
    static func keepsUncertainMarker(_ error: PRBarError, connector: Bool) -> Bool {
        if connector { return true }
        switch error {
        case .slack(let code): return code.hasPrefix("connector_")
        case .rateLimited: return false
        default: return true
        }
    }

    /// El ID de Slack propio, pedido una vez y guardado.
    private func selfUserID(token: String) async throws -> String {
        if let id = state.selfUserID, !id.isEmpty { return id }
        let identity = try await api.authTest(token: token)
        guard !identity.userID.isEmpty else { throw PRBarError.slack("connector_mismatch") }
        state.selfUserID = identity.userID
        saveState()
        return identity.userID
    }

    private func saveState() {
        do {
            try stateStore.save(state)
        } catch {
            AppLog.write("Couldn't save slack-state.json: \(error)")
        }
    }

    /// Ajusta el estado tras un error de Slack para no reintentar en cada ciclo lo que no va a funcionar.
    private func handleFailure(_ error: PRBarError, for action: SlackAction) {
        switch (action, error) {
        case (.react(let prID, _, _, _, let emoji, let kind), .slack("invalid_name")):
            // No se reintenta hasta que cambie el emoji configurado para esa reacción.
            state.reviewTracking[prID, default: ReviewTracking()].failedEmoji[kind.rawValue] = emoji
        case (.react(let prID, _, _, _, _, _), .slack("message_not_found")),
             (.reply(let prID, _, _, _, _, _), .slack("message_not_found")),
             (.reply(let prID, _, _, _, _, _), .slack("thread_not_found")):
            // El mensaje se borró: se vuelve a buscar (respetando los 10 minutos).
            state.reviewTracking[prID]?.message = nil
        default:
            break
        }
    }

    /// Un issue por emoji inexistente mientras siga configurado y su reacción activa (spec §17.4).
    private func invalidEmojiIssues(config: AppConfig) -> [RefreshIssue] {
        var names: [String] = []
        for kind in ReviewReactionKind.allCases where Self.isEnabled(kind, config.slack) {
            let current = SlackPlanner.emoji(for: kind, config.slack)
            let failed = state.reviewTracking.values.contains { $0.failedEmoji[kind.rawValue] == current }
            if failed && !names.contains(current) { names.append(current) }
        }
        return names.map { RefreshIssue(account: "slack", repo: nil, error: .slack("invalid_name"), detail: $0) }
    }

    private static func isEnabled(_ kind: ReviewReactionKind, _ settings: SlackSettings) -> Bool {
        switch kind {
        case .eyes: settings.reactOnReviewStart
        case .comment: settings.reactOnFirstComment
        case .approved: settings.reactOnApprove
        }
    }

    /// El mensaje raíz más antiguo con el link del PR.
    static func oldestMatch(_ messages: [SlackMessage], prURL: URL, channelID: String) -> SlackMessageRef? {
        messages
            .filter { PRLinkMatcher.matches($0, prURL: prURL) }
            .min { (Double($0.ts) ?? .infinity) < (Double($1.ts) ?? .infinity) }
            .map { SlackMessageRef(channelID: channelID, ts: $0.ts) }
    }

    /// Para `missing_scope`, el `detail` lleva los scopes que necesita la acción en vez del canal.
    private static func issueDetail(_ error: PRBarError, for action: SlackAction) -> String? {
        guard error == .slack("missing_scope") else { return nil }
        return switch action {
        case .announce, .update, .reply, .merged: "chat:write"
        case .findMessage: "channels:history, groups:history"
        case .react: "reactions:write"
        }
    }

    /// Lo llama `AppModel.startReview` al apretar Review en un PR ajeno: marca 👀 como pendiente (persistido) y
    /// corre un ciclo para buscar el mensaje y reaccionar enseguida. No bloquea la review: los errores van a `issues`.
    public func reviewStarted(item: ClassifiedPR, config: AppConfig) async {
        let settings = config.slack
        guard settings.enabled, settings.reactOnReviewStart, settings.reviewReactionsEnabledAt != nil,
              item.pr.author.lowercased() != item.account.lowercased(),
              let account = config.accounts.first(where: { $0.enabled && $0.login == item.account }),
              account.repos.contains(where: { $0.repo == item.pr.repo && $0.slackChannelID != nil })
        else { return }
        if state.reviewTracking[item.pr.id]?.hasReacted(.eyes) == true { return }
        state.reviewTracking[item.pr.id, default: ReviewTracking()].pendingEyes = true
        do {
            try stateStore.save(state)
        } catch {
            AppLog.write("Couldn't save slack-state.json: \(error)")
        }
        // Se agrega el PR al último snapshot (o al pendiente) para no perder los issues ni el resto del ciclo.
        var snapshot = pending?.snapshot ?? lastSnapshot ?? Snapshot(items: [], fetchedAt: now())
        snapshot.items.removeAll { $0.id == item.id && $0.account == item.account }
        snapshot.items.append(item)
        snapshot.fetchedScopes.insert(Snapshot.scope(account: item.account, repo: item.pr.repo))
        await process(snapshot: snapshot, config: config)
    }

    /// Lo llama `AppModel` después de mergear un PR mío desde PRBar (spec F.4): `queueMergedReply` y, si quedó
    /// pendiente, `postQueued`. Los errores van a `issues` y al log: el merge ya está hecho.
    public func prMerged(_ pr: PullRequest, method: MergeMethod, config: AppConfig) async {
        guard queueMergedReply(pr, method: method, config: config) else { return }
        await postQueued(config: config)
    }

    /// Si PRBar había anunciado el PR, deja "Merged" pendiente y lo guarda en el acto (sin esperar a nada): una
    /// actualización o un cierre justo después del merge no lo pierden, y el próximo ciclo lo publica. Devuelve
    /// `false` si no corresponde (sin anuncio, Slack o el interruptor apagados) o si ya estaba pedido.
    @discardableResult
    public func queueMergedReply(_ pr: PullRequest, method: MergeMethod, config: AppConfig) -> Bool {
        let settings = config.slack
        guard settings.enabled, settings.postMerged, let announcement = state.announcements[pr.id],
              state.mergedReplies[pr.id] == nil else { return false }
        state.mergedReplies[pr.id] = MergedReply(
            repo: pr.repo, channelID: announcement.channelID, threadTS: announcement.ts,
            text: SlackTemplate.render(settings.effectiveMergedTemplate, pr: pr, method: method.rawValue),
            requestedAt: now()
        )
        saveState()
        AppLog.write("Slack: “Merged” queued for \(pr.id)")
        return true
    }

    /// Corre un ciclo con el último snapshot para publicar ya lo pendiente (p. ej. un "Merged" recién pedido).
    public func postQueued(config: AppConfig) async {
        await process(snapshot: pending?.snapshot ?? lastSnapshot ?? Snapshot(items: [], fetchedAt: now()), config: config)
    }

    /// Vuelve a correr el plan con el último snapshot después de un cambio de configuración (token, interruptor,
    /// canal o plantillas), sin esperar al próximo refresco. Apagar Slack limpia los issues aunque no haya snapshot.
    public func reprocess(snapshot: Snapshot?, config: AppConfig) async {
        if let snapshot {
            await process(snapshot: snapshot, config: config)
        } else if !config.slack.enabled {
            issues = []
        }
    }

    /// Devuelve `true` si se guardó un token donde no había: quien llama debe marcar
    /// `AppConfig.slackTokenAdded(now:)` para no anunciar lo acumulado.
    /// Solo acepta User OAuth Tokens (`xoxp-…`); `nil` o vacío borra el token.
    @discardableResult
    public func saveToken(_ token: String?) throws -> Bool {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { try Self.validateUserToken(trimmed) }
        let hadToken = hasToken
        try secrets.write(trimmed, for: Self.tokenKey)
        cachedToken = trimmed?.isEmpty == false ? trimmed : nil
        tokenLoaded = true
        hasToken = cachedToken != nil
        cachedChannels = nil
        tokenRevision += 1
        if provider == .userToken { forgetIdentity() }
        if hasToken && state.needsUserToken {
            state.needsUserToken = false
            do {
                try stateStore.save(state)
            } catch {
                AppLog.write("Couldn't save slack-state.json: \(error)")
            }
        }
        needsUserToken = state.needsUserToken && !hasToken
        return hasToken && !hadToken
    }

    static func validateUserToken(_ token: String) throws {
        if token.hasPrefix("xoxp-") { return }
        throw PRBarError.slack(token.hasPrefix("xoxb-") ? "bot_token_rejected" : "invalid_user_token")
    }

    /// Cambia la API (y el provider) con la que se habla con Slack. Los canales cacheados se descartan.
    public func use(_ api: SlackAPI, provider: SlackProvider) {
        self.api = api
        let changed = self.provider != provider
        self.provider = provider
        cachedChannels = nil
        if changed {
            tokenRevision += 1
            forgetIdentity()
        }
    }

    /// Otra conexión puede ser otra cuenta de Slack: el ID propio se vuelve a pedir.
    private func forgetIdentity() {
        guard state.selfUserID != nil else { return }
        state.selfUserID = nil
        saveState()
    }

    /// Hay con qué hablar con Slack: el token guardado o, con el conector de Claude, siempre (si el conector no
    /// está conectado, lo dice el primer intento).
    public var isConnected: Bool { provider == .claudeConnector || hasToken }

    /// "Send test to my DM" (spec §17.5): lo lanza el usuario. Sin token (en modo token) falla el primer paso sin
    /// tocar Slack.
    public func sendSelfTest(logURL: URL?) async -> [SlackSelfTestStep] {
        let token: String
        do {
            token = try requireToken()
        } catch {
            var steps = SlackSelfTest.titles.enumerated().map {
                SlackSelfTestStep(id: $0.offset, title: $0.element, status: .skipped, detail: "Not run")
            }
            steps[0].status = .failed
            steps[0].detail = Self.prbarError(error).localizedDescription
            return steps
        }
        return await SlackSelfTest.run(api: api, token: token, logURL: logURL)
    }

    public func testConnection() async throws -> SlackIdentity {
        try await api.authTest(token: try requireToken())
    }

    /// Los canales del usuario; sin `reload`, la última lista cargada.
    public func channels(reload: Bool = false) async throws -> SlackChannelList {
        if !reload, let cachedChannels { return cachedChannels }
        let list = try await api.channels(token: try requireToken())
        cachedChannels = list
        return list
    }

    private func requireToken() throws -> String {
        if provider == .claudeConnector { return "" }
        if !tokenLoaded {
            cachedToken = try secrets.read(Self.tokenKey)
            tokenLoaded = true
        }
        guard let token = cachedToken, !token.isEmpty else { throw PRBarError.slack("missing_token") }
        return token
    }

    private static func prbarError(_ error: Error) -> PRBarError {
        (error as? PRBarError) ?? .network(error.localizedDescription)
    }

    private static func stopsCycle(_ error: PRBarError) -> Bool {
        switch error {
        case .rateLimited: true
        case .slack(let code):
            ["invalid_auth", "token_revoked", "not_authed", "account_inactive", "connector_unavailable", "connector_mismatch"].contains(code)
        case .commandFailed(let command, _, _), .timedOut(let command): command == "claude"
        case .toolNotFound: true
        default: false
        }
    }
}
