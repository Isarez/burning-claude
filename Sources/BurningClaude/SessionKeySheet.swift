import SwiftUI
import AppKit

/// Collects a claude.ai session key and validates it before anything is stored.
///
/// A view of its own rather than a section of `SettingsView`: none of this
/// state — the pasted key, the in-flight request, the error — means anything to
/// the rest of Settings, and keeping it here means each presentation starts
/// from a genuinely empty field rather than whatever the last attempt left
/// behind.
struct SessionKeySheet: View {
    @ObservedObject var store: UsageStore
    /// Called once the account is stored, so Settings can pick up the new row.
    var onSignedIn: () -> Void
    var onCancel: () -> Void

    @State private var input = ""
    @State private var error: String?
    @State private var isSigningIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in with a claude.ai session key")
                .font(.system(size: 13, weight: .semibold))
            Text("This reads your 5-hour and 7-day figures directly from "
                 + "claude.ai, on demand, for the whole account — not just what "
                 + "Claude Code did on this Mac.")
                .helpText()

            instructions

            HStack(spacing: 6) {
                SecureField("sk-ant-sid01-…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSigningIn)
                // A session key is ~100 opaque characters: pasting is the only
                // realistic way in, so it gets a button of its own rather than
                // depending solely on ⌘V finding a first responder.
                Button {
                    if let clipboard = NSPasteboard.general.string(forType: .string) {
                        input = clipboard
                        error = nil
                    } else {
                        error = "The clipboard has no text on it."
                    }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .disabled(isSigningIn)
                .help("Paste the session key from the clipboard")
            }

            if !input.isEmpty {
                Text(pastedKeySummary)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text("The key is stored in your login keychain and sent only to "
                 + "claude.ai. Note that it grants full access to the account, "
                 + "and that this endpoint is a private API — ClaudeMeter, which "
                 + "pioneered the approach, notes that using it may be at odds "
                 + "with the claude.ai Terms of Service.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isSigningIn {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("Checking with claude.ai…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .disabled(isSigningIn)
                Button("Sign in") { signIn() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSigningIn || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("In your browser, signed in to claude.ai:").helpText()
            Text("""
                 1.  Open DevTools  (⌥⌘I)
                 2.  Application → Storage → Cookies → https://claude.ai
                 3.  Copy the value of  sessionKey
                 """)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    /// Confirmation that the paste actually landed. A `SecureField` renders
    /// only dots, so a truncated or empty paste is otherwise indistinguishable
    /// from a good one until sign-in fails.
    private var pastedKeySummary: String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = try? SessionKey(input) else {
            return "\(trimmed.count) characters — not a session key yet"
        }
        return "\(key.redacted) · looks right"
    }

    /// Validates the key against claude.ai *before* storing it, so a typo or an
    /// expired cookie fails here rather than becoming a permanently broken row.
    private func signIn() {
        let raw = input
        isSigningIn = true
        error = nil

        Task { @MainActor in
            defer { isSigningIn = false }
            do {
                let key = try SessionKey(raw)
                let organizations = try await ClaudeWebClient.organizations(key: key)
                guard let organization = organizations.first else {
                    throw ClaudeWebClient.Failure.noOrganizations
                }
                guard !Preferences.shared.sessionAccounts.contains(where: {
                    $0.id == organization.uuid
                }) else {
                    error = "That account is already signed in. Remove it "
                          + "first to replace its key."
                    return
                }
                // Confirms the key reaches the endpoint that actually matters,
                // not just the organisation list.
                _ = try await ClaudeWebClient.usage(organization: organization.uuid, key: key)

                let email = await ClaudeWebClient.email(key: key)
                try store.addSessionAccount(
                    SessionAccount(
                        organizationUUID: organization.uuid,
                        organizationName: organization.name,
                        label: email ?? organization.name,
                        addedAt: Date()
                    ),
                    key: key
                )

                onSignedIn()
                await store.refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
