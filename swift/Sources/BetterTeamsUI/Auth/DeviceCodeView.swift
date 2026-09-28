// DeviceCodeView.swift — device-code sign-in (UI-SPEC §5.7): the code
// in large monospaced type, Copy Code, Open Browser, a waiting status.
import OstMacCore
import SwiftUI

struct DeviceCodeView: View {
    let code: AuthCodeInfo
    @ObservedObject var auth: AuthViewModel
    let isEvidence: Bool
    /// Also closes the Sign In Again sheet.
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // The address is a link (opens the default browser).
            Text(Self.instruction(code.verificationURI))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // Exactly as Microsoft issued it; Copy Code copies the same string.
            Text(code.userCode)
                .font(AppFont.deviceCode)
                .textSelection(.enabled)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                // Tertiary fill + hairline: quaternary alone vanished on
                // the light window background.
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 1)
                }
                .accessibilityLabel("Code \(code.userCode.map(String.init).joined(separator: " "))")
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to sign in…").foregroundStyle(.secondary)
            }
            // HIG button order: the auxiliary action (Copy Code) at the
            // leading edge, Cancel just left of the default button.
            HStack(spacing: 10) {
                Button("Copy Code") { if !isEvidence { auth.copyCode() } }
                    .controlSize(.large)
                Spacer(minLength: 20)
                Button("Cancel", role: .cancel) {
                    if !isEvidence { auth.cancel() }
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
                Button("Open Browser") { if !isEvidence { auth.openBrowser() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }

    /// "Open ‹address› in your browser and enter:", the address linked.
    static func instruction(_ uri: String) -> AttributedString {
        var link = AttributedString(uri.replacingOccurrences(of: "https://", with: ""))
        link.link = URL(string: uri)
        return AttributedString("Open ") + link + AttributedString(" in your browser and enter:")
    }
}

/// The one sign-in header (§5.7): app icon over the title. `SignInView`
/// owns it at a fixed top position so it never moves between the start
/// and device-code screens.
struct SignInHeader: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(title)
                .font(.title.weight(.semibold))
        }
    }
}
