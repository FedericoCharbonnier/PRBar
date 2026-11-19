import PRBarCore
import SwiftUI

struct AccountsTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        Form {
            if model.ghAccounts.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No GitHub accounts in gh", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.orangeText)
                        if let error = model.accountsError {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Sign in from Terminal, then reload:").foregroundStyle(.secondary)
                        CopyableCommand("gh auth login --hostname github.com")
                        Button("Reload") { Task { await model.reloadAccounts() } }
                    }
                }
            } else {
                Section {
                    ForEach(model.ghAccounts, id: \.login) { account in
                        Toggle(isOn: enabledBinding(for: account.login)) {
                            HStack(spacing: 8) {
                                AvatarView(login: account.login, url: URL(string: "https://github.com/\(account.login).png?size=64"))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(account.login)
                                    Text(account.isActive ? "github.com · active account in gh" : "github.com")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                    }
                } header: {
                    Text("Accounts found in gh")
                } footer: {
                    HStack {
                        Text("Sign in to more accounts with gh auth login, then reload.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reload Accounts") { Task { await model.reloadAccounts() } }
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func enabledBinding(for login: String) -> Binding<Bool> {
        Binding(
            get: { configStore.config.accounts.first { $0.login == login }?.enabled ?? false },
            set: { enabled in model.updateConfig { $0.setAccountEnabled(login, enabled) } }
        )
    }
}
