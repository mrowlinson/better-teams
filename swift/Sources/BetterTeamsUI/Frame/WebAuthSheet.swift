// WebAuthSheet.swift — Microsoft sign-in in a sheet (UI-SPEC §7.4):
// the Teams OAuth redirect can't be captured by ASWebAuthenticationSession
// without a custom scheme, so this is a permitted "not otherwise
// possible" web view. Cancel only, no custom chrome. The web view comes
// from FrameHost (R16).
import AppKit
import OstMacCore
import WebKit

@MainActor
final class WebAuthSheet: NSViewController, WKNavigationDelegate {
    private let web: WKWebView
    /// Nil for a web app's auth popup: WebKit loads the child itself.
    private let start: URL?
    private let redirectURI: String
    private let onFinish: (String?) -> Void
    private var finished = false

    /// `onFinish(callbackURL)`; nil = cancelled. An empty
    /// `redirectURI` never finishes on navigation (web-app popups close
    /// through `webViewDidClose`).
    init(web: WKWebView, start: URL?, redirectURI: String, onFinish: @escaping (String?) -> Void) {
        self.web = web
        self.start = start
        self.redirectURI = redirectURI
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 660))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .push
        web.translatesAutoresizingMaskIntoConstraints = false
        cancel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(web)
        root.addSubview(cancel)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            web.topAnchor.constraint(equalTo: root.topAnchor),
            web.bottomAnchor.constraint(equalTo: cancel.topAnchor, constant: -12),
            cancel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            cancel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        preferredContentSize = root.frame.size
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let start else { return }
        web.navigationDelegate = self
        web.load(URLRequest(url: start))
    }

    @objc private func cancelSheet(_ sender: Any?) { finish(nil) }

    private func finish(_ url: String?) {
        guard !finished else { return }
        finished = true
        web.stopLoading()
        onFinish(url)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url?.absoluteString, isBrowserRedirect(url, redirectURI: redirectURI) {
            decisionHandler(.cancel)
            finish(url)
            return
        }
        decisionHandler(.allow)
    }
}
