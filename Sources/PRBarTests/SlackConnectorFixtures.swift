import Foundation

/// Resultados de las herramientas del conector de Slack de Claude, tal cual llegan en el `tool_result` del
/// `stream-json` (spec §17.5).
enum SlackConnectorFixtures {
    /// `slack_read_channel` (`channel_id` de un canal propio, `limit` 5), grabado en vivo el 2026-11-19 con una
    /// llamada de solo lectura. Formato real: JSON con `messages` (texto, no lista) y `pagination_info`; cada
    /// mensaje es un bloque `=== Message from Nombre <email> (Uxxx) at fecha === ` seguido de `Message TS:`, el
    /// texto (links como `<url|label>`) y las líneas `Thread:` / `Reactions:`. Los nombres, emails, IDs y repos de
    /// otras personas están anonimizados; la estructura, los escapes (`\/`) y el espacio después de `===` son
    /// los originales.
    static let readChannel = #"""
        {"messages":"Channel: #code-review (C0000000001)\n\n=== Message from Ana <ana@example.com> (U0000000002) at 2026-11-09 15:36:59 -03 === \nMessage TS: 1794249419.368099\n<https:\/\/github.com\/acme\/posts-api\/pull\/37|github.com\/acme\/posts-api\/pull\/37> <@U0000000004|lucia>\nThread: 1 replies (latest: 2026-11-19 08:53:49 -03)\nReactions: eyes (1), speech_balloon (1)\n\n=== Message from Bruno <bruno@example.com> (U0000000003) at 2026-10-30 15:12:21 -03 === \nMessage TS: 1793383941.847189\n<https:\/\/github.com\/acme\/docs-site\/pull\/64|github.com\/acme\/docs-site\/pull\/64> <@U0000000005|Tomas> <@U0000000006|Nico>\n*Sent using* <@U0000000009|Claude>\nThread: 3 replies (latest: 2026-10-30 16:07:07 -03)\nReactions: clap::skin-tone-3 (1)\n\n=== Message from Sam <sam@example.com> (U0000000001) at 2026-10-23 11:22:54 -03 === \nMessage TS: 1792765374.117489\n<https:\/\/github.com\/acme\/orders\/pull\/66|github.com\/acme\/orders\/pull\/66> <@U0000000007|Vale> <@U0000000006|Nico>\nThread: 6 replies (latest: 2026-10-30 10:21:27 -03)\nReactions: approved (1)\n\n=== Message from Ana <ana@example.com> (U0000000002) at 2026-10-21 15:01:01 -03 === \nMessage TS: 1792605661.455269\n<https:\/\/github.com\/acme\/posts-api\/pull\/29|github.com\/acme\/posts-api\/pull\/29> <@U0000000004|lucia>\nThread: 1 replies (latest: 2026-11-02 09:13:03 -03)\nReactions: speech_balloon (1), approved (1)\n\n=== Message from Bruno <bruno@example.com> (U0000000003) at 2026-10-13 16:27:08 -03 === \nMessage TS: 1791919628.815159\n<https:\/\/github.com\/acme\/web-app\/pull\/544|github.com\/acme\/web-app\/pull\/544> <@U0000000008|marta>\n*Sent using* <@U0000000009|Claude>\nThread: 4 replies (latest: 2026-10-13 16:51:20 -03)\nReactions: approved (1)","pagination_info":"There are more messages available. To view the next page, use cursor: `bmV4dF90czoxNzkxOTE4MzA3Njg2NDU5`\n"}
        """#

    /// `slack_read_user_profile` sin argumentos, grabado en vivo el 2026-11-19 (solo lectura). Datos de contacto
    /// recortados.
    static let readProfile = #"""
        {"result":"User ID: U0000000001\nUsername: dev-sam\nDisplay Name: Sam\nReal Name: Sam Doe\nPronouns: \nTitle: \nEmail: sam@example.com\nOrganization Name: Acme\nPhone: \nStatus:  \nTimezone: America\/New_York\nAdmin: No\nOwner: No\nBot: No\nRestricted: No\n"}
        """#

    /// `slack_list_user_channels` (`limit` 10), grabado en vivo el 2026-11-19 (solo lectura), recortado a dos
    /// canales.
    static let listChannels = #"""
        {"result":"## My Channels (showing 2, more results available)\n\n### #general\n- **ID:** C0000000002\n- **Type:** Public Channel\n- **Topic:** Updates.\n- **Archived:** No\n\n### #code-review\n- **ID:** C0000000001\n- **Type:** Public Channel\n- **Archived:** No\n\n---\nPagination: More results available. Use cursor: \"aWQ6MTAwMzkxMzcyMjQzNQ==\"\n"}
        """#

    // MARK: - Formatos posibles de las escrituras (no verificados en vivo: PRBar no escribe en Slack en los tests)

    /// `slack_send_message`: lo que podría devolver el conector. Todos tienen que dar el `ts` (y el canal cuando lo
    /// hay) o un error; nunca un éxito sin `ts`.
    static let sendJSONts = #"{"ok":true,"channel":"D0123ABCD","ts":"1700000000.123456"}"#
    static let sendJSONmessageTS = #"{"ok":true,"message_ts":"1700000000.123456"}"#
    static let sendJSONpermalink = #"{"permalink":"https:\/\/acme.slack.com\/archives\/D0123ABCD\/p1700000000123456"}"#
    static let sendResultPermalink = #"{"result":"Message sent successfully: https:\/\/acme.slack.com\/archives\/C1\/p1700000000123456"}"#
    static let sendThreadPermalink = "Reply posted: https://acme.slack.com/archives/C1/p1700000001000200?thread_ts=1700000000.000100&cid=C1"
    static let sendPlainTS = "Message sent. ts: 1700000000.123456"
    static let sendMessageTSLabel = "Channel: C1\nMessage TS: 1700000000.123456"
    static let sendNestedResultJSON = #"{"result":"{\"ok\":true,\"ts\":\"1700000000.123456\",\"channel\":\"C1\"}"}"#
    static let sendErrorJSON = #"{"ok":false,"error":"not_in_channel"}"#
    static let sendErrorText = "Failed to send message: channel_not_found"
    static let sendOkWithoutTS = #"{"ok":true}"#
    static let sendUnknown = "Message sent successfully"
    static let sendEmpty = ""

    /// `slack_add_reaction`.
    static let reactJSONok = #"{"ok":true}"#
    static let reactResultText = #"{"result":"Reaction added successfully"}"#
    static let reactAlready = #"{"ok":false,"error":"already_reacted"}"#
    static let reactErrorText = "Error adding reaction: invalid_name"
    static let reactUnknown = "Done."
}
