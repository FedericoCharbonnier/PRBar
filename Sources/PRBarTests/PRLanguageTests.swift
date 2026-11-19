import Foundation
import PRBarCore

private let spanishDescription = """
## Descripción
Este PR agrega la validación del email en el formulario de registro y muestra un mensaje de error
cuando el usuario escribe una dirección inválida. También se corrige el texto del botón.
"""

private let englishDescription = """
This PR adds email validation to the signup form and shows an error message when the user types
an invalid address. It also fixes the button label.
"""

private let portugueseDescription = """
Este PR adiciona a validação do e-mail no formulário de cadastro e mostra uma mensagem de erro
quando o usuário digita um endereço inválido. Também corrige o texto do botão.
"""

/// A typical PR template left unfilled: headings, HTML comments, checklists, a link and a code block.
private let templateOnly = """
<!-- Please describe your changes in detail. Explain why this change is required and what problem it solves. -->
## Checklist
- [ ] I have added tests that prove my fix is effective or that my feature works
- [x] I have updated the documentation accordingly
- [ ] My changes generate no new warnings

https://example.com/contributing/guidelines/for/pull/requests
```swift
let message = "This code block should never be used to detect the language of the PR"
```
"""

enum PRLanguageTests {
    static let cases: [TestCase] = [
        TestCase("language: a Spanish description is detected as Spanish") {
            let language = PRLanguage.detect(description: spanishDescription, title: "Add email validation")
            try expectEqual(language.code, "es")
            try expectEqual(language.displayName, "Spanish")
        },
        TestCase("language: an English description is detected as English") {
            let language = PRLanguage.detect(description: englishDescription, title: "Validación de email")
            try expectEqual(language, .english)
            try expectEqual(language.displayName, "English")
        },
        TestCase("language: a Portuguese description is detected as Portuguese") {
            let language = PRLanguage.detect(description: portugueseDescription, title: "Validação de e-mail")
            try expectEqual(language.code, "pt")
            try expectEqual(language.displayName, "Portuguese")
        },
        TestCase("language: a template-only description falls back to the title") {
            let language = PRLanguage.detect(
                description: templateOnly, title: "Agrega la validación del correo electrónico en el formulario de registro")
            try expectEqual(language.code, "es")
        },
        TestCase("language: an empty description and a short title fall back to English") {
            try expectEqual(PRLanguage.detect(description: "", title: "WIP"), .english)
            try expectEqual(PRLanguage.detect(description: nil, title: ""), .english)
        },
        TestCase("language: low confidence falls back to English") {
            // Too short to be confident about anything.
            try expectEqual(PRLanguage.detect(description: "ok", title: "fix"), .english)
        },
        TestCase("language: code, URLs and inline code are ignored in mixed text") {
            let mixed = """
            Cambia `UserValidator.validate(email:)` para que acepte dominios nuevos y agrega los tests que faltaban.
            Ver https://github.com/o/r/issues/12 para más contexto sobre el problema.
            ```ruby
            def validate(email)
              raise ArgumentError, "the email address is not valid for this account" unless email.include?("@")
            end
            ```
            """
            try expectEqual(PRLanguage.detect(description: mixed, title: "Validate email").code, "es")
        },
        TestCase("language: stripping removes comments, code, URLs, checklists and Markdown syntax") {
            let stripped = PRLanguage.strip("""
            <!-- template
            comment -->
            ## Título
            Texto con **negrita**, `code` y [un link](https://x.y/z) y https://a.b/c.
            - [ ] tarea
            ~~~
            hidden()
            ~~~
            """)
            try expect(!stripped.contains("template"), stripped)
            try expect(!stripped.contains("code"), stripped)
            try expect(!stripped.contains("https"), stripped)
            try expect(!stripped.contains("tarea"), stripped)
            try expect(!stripped.contains("hidden"), stripped)
            try expect(!stripped.contains("Título"), stripped)
            try expect(stripped.contains("un link"), stripped)
            try expect(stripped.contains("negrita"), stripped)
            try expect(!stripped.contains("*"), stripped)
        },
        TestCase("language: codes round-trip through Codable as a plain string") {
            let data = try JSONEncoder().encode(PRLanguage(code: "es"))
            try expectEqual(String(decoding: data, as: UTF8.self), #""es""#)
            try expectEqual(try JSONDecoder().decode(PRLanguage.self, from: data), PRLanguage(code: "es"))
        },
        TestCase("language: an unknown code still has a display name") {
            try expectEqual(PRLanguage(code: "fr").displayName, "French")
            try expectEqual(PRLanguage(code: "zz-unknown").displayName, "zz-unknown")
        },

        // MARK: Phrase table

        TestCase("phrases: 'fixed in' is localized for the common languages") {
            let link = "https://github.com/o/r/commit/abc"
            try expectEqual(PublishedPhrases.fixedIn(link, language: PRLanguage(code: "es")), "Arreglado en \(link).")
            try expectEqual(PublishedPhrases.fixedIn(link, language: PRLanguage(code: "pt")), "Corrigido em \(link).")
            try expectEqual(PublishedPhrases.fixedIn(link, language: PRLanguage(code: "fr")), "Corrigé dans \(link).")
            try expectEqual(PublishedPhrases.fixedIn(link, language: PRLanguage(code: "de")), "Behoben in \(link).")
            try expectEqual(PublishedPhrases.fixedIn(link, language: PRLanguage(code: "it")), "Corretto in \(link).")
            try expectEqual(PublishedPhrases.fixedIn(link, language: .english), "Fixed in \(link).")
        },
        TestCase("phrases: other languages fall back to English") {
            try expectEqual(PublishedPhrases.fixedIn("L", language: PRLanguage(code: "ja")), "Fixed in L.")
            try expectEqual(PublishedPhrases.fixedIn("L", language: PRLanguage(code: "pt-BR")), "Corrigido em L.")
        },
        TestCase("phrases: unanchored findings and review-body replies are language-neutral") {
            try expectEqual(PublishedPhrases.unanchoredFinding(location: "a.rb:3", text: "Ojo"), "**a.rb:3** — Ojo")
            try expectEqual(PublishedPhrases.reviewBodyReply(reviewer: "ana", quote: "Falta", text: "Listo"),
                            "@ana\n\n> Falta\n\nListo")
            try expectEqual(PublishedPhrases.reviewBodyReply(reviewer: "ana", quote: "", text: "Listo"), "@ana\n\nListo")
        },
    ]
}
