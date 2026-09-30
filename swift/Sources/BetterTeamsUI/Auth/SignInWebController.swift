// SignInWebController.swift — Microsoft sign-in embedded in place
// (SIGNIN lane): the web view fills the main window's content when no
// account is signed in, and the Add Account / Sign In Again sheets. The
// chrome around it is native: a footer with a progress indicator,
// "Use a Code Instead" and Cancel, and a short problem line with an (i)
// button when the page can't finish here. The core's native-client
// redirect is caught in `decidePolicyFor` and handed back as the callback
// URL; this path never opens the system browser.
import AppKit
import OstMacCore
import SwiftUI
import WebKit

/// Why the embedded page can't finish on its own.
enum SignInWebProblem: Equatable {
    /// The page didn't load (offline, DNS, TLS, web process crash).
    case loadFailed
    /// The organization asks for something a web view can't provide
    /// (passkey / security key, certificate, managed or compliant device).
    case needsBrowser

    var title: String {
        switch self {
        case .loadFailed: return "Can't connect"
        case .needsBrowser: return "Finish signing in with a code"
        }
    }

    var detail: String {
        switch self {
        case .loadFailed:
            return "Check your internet connection, then try again. You can also sign in with a code in your web browser."
        case .needsBrowser:
            return "Your organization asks for a check this window can't do, such as a passkey, a security key, a certificate or a managed device. Sign in with a code instead: your web browser handles the check, then Better Teams finishes signing in."
        }
    }
}

/// Page checks for sign-in steps a web view can't satisfy. Pure, so
/// the rules are unit-tested without a page.
enum SignInPageCheck {
    /// Entra error codes for device / conditional-access checks that
    /// need the system browser or a managed device.
    static let browserOnlyCodes = [
        "AADSTS50097", // device authentication required
        "AADSTS53000", // device must be compliant / managed
        "AADSTS53001", // device must be domain joined
        "AADSTS53002", // app not approved for this device
        "AADSTS53003", // blocked by conditional access
    ]

    /// True when the page at `url` (with visible text `pageText`) is a
    /// step the embedded view can't complete.
    static func needsBrowser(url: URL?, pageText: String) -> Bool {
        if let url {
            let host = url.host?.lowercased() ?? ""
            // Certificate-based auth runs on a certauth.* host.
            if host.hasPrefix("certauth.") { return true }
            // Passkey / FIDO2 security-key step.
            if host.hasSuffix("login.microsoft.com") || host.hasSuffix("login.microsoftonline.com"),
               url.path.lowercased().contains("/fido/") { return true }
        }
        let text = pageText.uppercased()
        return browserOnlyCodes.contains { text.contains($0) }
    }

    /// Navigation errors that are ours (redirect cancel, superseded
    /// load), not a failure to show.
    static func isBenign(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSURLErrorDomain, e.code == NSURLErrorCancelled { return true }
        // WebKitErrorDomain 102: frame load interrupted (policy cancel).
        if e.domain == "WebKitErrorDomain", e.code == 102 { return true }
        return false
    }
}

/// Footer state the SwiftUI chrome observes.
@MainActor
final class SignInWebChrome: ObservableObject {
    @Published var loading = true
    @Published var problem: SignInWebProblem?
    /// The current page finished loading and was checked (or failed).
    /// Evidence captures wait for it.
    var pageChecked = false
}

@MainActor
final class SignInWebController: NSViewController, WKNavigationDelegate {
    /// Embedded content size (web view + footer).
    static let contentSize = NSSize(width: 560, height: 680)

    let web: WKWebView
    let chrome = SignInWebChrome()
    private let start: URL
    private let redirectURI: String
    private let onFinish: (String?) -> Void
    private let onUseCode: () -> Void
    private var finished = false
    private var observations: [NSKeyValueObservation] = []

    /// `onFinish(callbackURL)`; nil = cancelled. `onUseCode`: switch to
    /// the device-code flow (the caller drops this browser session).
    init(web: WKWebView, start: URL, redirectURI: String,
         onFinish: @escaping (String?) -> Void, onUseCode: @escaping () -> Void) {
        self.web = web
        self.start = start
        self.redirectURI = redirectURI
        self.onFinish = onFinish
        self.onUseCode = onUseCode
        super.init(nibName: nil, bundle: nil)
        web.navigationDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        let footer = NSHostingView(rootView: SignInWebFooter(
            chrome: chrome,
            useCode: { [weak self] in self?.useCode() },
            retry: { [weak self] in self?.retry() },
            cancel: { [weak self] in self?.finish(nil) }))
        web.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(web)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // Below the title bar (the window's content runs under it).
            web.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        observations = [web.observe(\.isLoading, options: [.initial, .new]) { [weak self] web, _ in
            let loading = web.isLoading
            MainActor.assumeIsolated { self?.chrome.loading = loading }
        }]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        web.load(URLRequest(url: start))
    }

    /// Leave for the device-code flow.
    func useCode() {
        guard !finished else { return }
        finished = true
        web.stopLoading()
        onUseCode()
    }

    private func retry() {
        chrome.problem = nil
        chrome.pageChecked = false
        web.load(URLRequest(url: start))
    }

    func finish(_ url: String?) {
        guard !finished else { return }
        finished = true
        web.stopLoading()
        onFinish(url)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url?.absoluteString, isBrowserRedirect(url, redirectURI: redirectURI) {
            decisionHandler(.cancel)
            finish(url)
            return
        }
        if let url = action.request.url {
            if TeamsWebGuard.refuses(url, mainFrame: action.targetFrame?.isMainFrame ?? true, iframeHostDocument: false) {
                return decisionHandler(.cancel)
            }
            if action.targetFrame?.isMainFrame ?? true, SignInPageCheck.needsBrowser(url: url, pageText: "") {
                chrome.problem = .needsBrowser
            }
        }
        if action.shouldPerformDownload { return decisionHandler(.cancel) }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Visible text only (never logged): Entra error pages carry
        // their AADSTS code in the page body.
        let url = webView.url
        webView.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 20000) : ''") { [weak self] result, _ in
            let text = result as? String ?? ""
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                self.chrome.pageChecked = true
                if SignInPageCheck.needsBrowser(url: url, pageText: text) { self.chrome.problem = .needsBrowser }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !finished else { return }
        chrome.problem = .loadFailed
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // A client certificate (certificate-based auth, device identity)
        // can't be picked in an embedded view: offer the code flow.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            chrome.problem = .needsBrowser
        }
        completionHandler(.performDefaultHandling, nil)
    }

    private func failed(_ error: Error) {
        guard !finished, !SignInPageCheck.isBenign(error) else { return }
        chrome.problem = .loadFailed
        chrome.pageChecked = true
    }
}

/// Native footer: progress, the code fallback, Cancel; on a problem, a
/// short line with its (i) explanation.
struct SignInWebFooter: View {
    @ObservedObject var chrome: SignInWebChrome
    let useCode: () -> Void
    let retry: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if let problem = chrome.problem {
                    Label {
                        Text(problem.title)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    }
                    .lineLimit(1)
                    InfoButton(subject: problem.title, text: problem.detail)
                } else {
                    Button("Use a Code Instead", action: useCode)
                    if chrome.loading {
                        ProgressView().controlSize(.small).accessibilityLabel("Loading")
                    }
                }
                Spacer(minLength: 12)
                if let problem = chrome.problem {
                    if problem == .loadFailed {
                        Button("Use a Code Instead", action: useCode)
                        Button("Try Again", action: retry).keyboardShortcut(.defaultAction)
                    } else {
                        Button("Use a Code Instead", action: useCode).keyboardShortcut(.defaultAction)
                    }
                }
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }
}
