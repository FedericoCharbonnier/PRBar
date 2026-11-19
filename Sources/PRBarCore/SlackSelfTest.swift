import Foundation

/// Un paso de "Send test to my DM" (spec §17.5).
public struct SlackSelfTestStep: Equatable, Sendable, Identifiable {
    public enum Status: Equatable, Sendable { case ok, failed, skipped }

    public let id: Int
    public let title: String
    public var status: Status
    /// El `ts` interpretado o el error.
    public var detail: String

    public init(id: Int, title: String, status: Status, detail: String) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
    }
}

/// Prueba de escritura que el usuario lanza a mano desde Ajustes → Slack, por el mismo camino que usa PRBar (la
/// `SlackAPI` actual, con el conector o con el token): lee el perfil propio, publica UN mensaje en el DM propio,
/// reacciona 👀, publica UNA respuesta en su hilo y lo vuelve a leer. Nunca reintenta: el primer paso que falla
/// corta el resto. Cada paso queda en el log del conector (y, con el conector, el `tool_result` crudo también).
public enum SlackSelfTest {
    public static let rootText = "PRBar connector test (you can delete this)"
    public static let replyText = "PRBar connector test reply"
    public static let confirmation =
        "PRBar will post a test message in your own DM, react 👀, reply in its thread, then read it back."
    public static let titles = [
        "Read your Slack profile", "Post a test message in your DM", "React 👀", "Reply in its thread", "Read it back",
    ]

    public static func run(api: SlackAPI, token: String, logURL: URL?) async -> [SlackSelfTestStep] {
        let log = logURL.map { ClaudeLogWriter(url: $0) }
        log?.append("=== self-test: started ===\n")
        var steps = titles.enumerated().map { SlackSelfTestStep(id: $0.offset, title: $0.element, status: .skipped, detail: "Not run") }

        func record(_ index: Int, _ status: SlackSelfTestStep.Status, _ detail: String) {
            steps[index].status = status
            steps[index].detail = detail
            log?.append("=== self-test: \(titles[index]): \(status == .ok ? "✓" : "✗") \(detail) ===\n")
        }

        func describe(_ error: Error) -> String {
            let prbar = (error as? PRBarError) ?? .network(error.localizedDescription)
            if case .slack(let code) = prbar { return "\(prbar.localizedDescription) (\(code))" }
            return prbar.localizedDescription
        }

        // 1. El ID propio: el DM propio es el canal con ese ID.
        let me: String
        do {
            let identity = try await api.authTest(token: token)
            guard !identity.userID.isEmpty else {
                record(0, .failed, "Slack didn't return your user ID")
                return steps
            }
            me = identity.userID
            record(0, .ok, "@\(identity.user) (\(identity.userID))")
        } catch {
            record(0, .failed, describe(error))
            return steps
        }

        // 2. Un solo mensaje raíz.
        let root: SlackPostResult
        do {
            root = try await api.postMessageResult(channel: me, text: rootText, threadTS: nil, token: token)
            record(1, .ok, "ts \(root.ts)" + (root.channel.map { " in \($0)" } ?? ""))
        } catch {
            record(1, .failed, describe(error) + " Not retried: check your DM before trying again.")
            return steps
        }
        let channel = root.channel ?? me

        // 3. 👀 en ese mensaje.
        do {
            try await api.addReaction(channel: channel, ts: root.ts, name: "eyes", token: token)
            record(2, .ok, ":eyes: on \(root.ts)")
        } catch {
            record(2, .failed, describe(error))
            return steps
        }

        // 4. Una sola respuesta en el hilo.
        let reply: SlackPostResult
        do {
            reply = try await api.postMessageResult(channel: channel, text: replyText, threadTS: root.ts, token: token)
            record(3, .ok, "ts \(reply.ts)")
        } catch {
            record(3, .failed, describe(error) + " Not retried: check your DM before trying again.")
            return steps
        }

        // 5. Se lee el hilo y se confirman los dos mensajes.
        do {
            let messages = try await api.threadReplies(channel: channel, ts: root.ts, token: token)
            let hasRoot = messages.contains { $0.ts == root.ts && SlackText.comparable($0.text) == rootText }
            let hasReply = messages.contains {
                $0.ts != root.ts && SlackText.comparable($0.text) == replyText && ($0.user == nil || $0.user == me)
            }
            switch (hasRoot, hasReply) {
            case (true, true): record(4, .ok, "Found the message and the reply (\(messages.count) in the thread)")
            case (false, _): record(4, .failed, "The test message wasn't found in the thread (\(messages.count) read)")
            case (true, false): record(4, .failed, "The reply wasn't found in the thread (\(messages.count) read)")
            }
        } catch {
            record(4, .failed, describe(error))
        }
        return steps
    }
}
