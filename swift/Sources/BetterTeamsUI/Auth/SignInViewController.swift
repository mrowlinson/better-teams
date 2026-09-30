// SignInViewController.swift — signed-out window content (UI-SPEC
// §5.7): centered, no rail, no split view. Microsoft sign-in starts by
// itself and shows embedded in the window (SIGNIN); "Sign In with
// Microsoft" restarts it after Cancel, "Use a Device Code" shows the
// code. `--demo` skips sign-in; evidence can force either state. The
// window is sized to each screen's content, growing and shrinking from
// a fixed top edge so the header never moves.
import AppKit
import Combine
import OstMacCore
import SwiftUI

/// Evidence-forced sign-in presentation (demo only).
public enum SignInPresentation: Equatable, Sendable {
    case start
    case code(String)
    /// Embedded Microsoft sign-in showing a local fake login page
    /// (`--route "signin?state=web&port=N"`, demo only; SIGNIN R6).
    case web(URL)

    /// The fake page's native-client redirect (same origin).
    static func fakeRedirect(for url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.path = "/nativeclient"
        c?.query = nil
        return c?.string ?? ""
    }
}

@MainActor
final class SignInViewController: NSViewController {
    private let model: WindowModel
    private let evidence: SignInPresentation?
    private let asSheet: Bool
    /// Add Account: the new profile's VM (nil = the window's own auth).
    private let adding: AuthViewModel?
    private let added: AddOnce?
    /// Test injection: the auth VM to drive (nil = adding / window's own).
    private let injectedAuth: AuthViewModel?
    private var cancellables = Set<AnyCancellable>()
    /// Microsoft sign-in, embedded in place of the start screen while
    /// the auth is in `.browser` (SIGNIN R1/R2).
    private(set) var webSignIn: SignInWebController?
    /// Start Microsoft sign-in by itself once, as soon as the auth is
    /// signed out (SIGNIN R1). Cancel returns to the start screen.
    private var autoStartPending: Bool

    /// Production default: auto-start. Off under XCTest, so no test ever
    /// loads the live Microsoft page; tests opt in with a fake server.
    nonisolated static let defaultAutoStart = NSClassFromString("XCTestCase") == nil

    /// Content width (HIG windows: sized to the content, not the shell).
    static let contentWidth: CGFloat = 540
    /// Smallest content size (the start screen fits well inside it).
    static let contentSize = NSSize(width: contentWidth, height: 300)
    /// Sheet size for the start and code screens.
    static let sheetSize = NSSize(width: 480, height: 420)
    private var host: NSViewController?

    init(model: WindowModel, evidence: SignInPresentation?, asSheet: Bool = false,
         adding: AuthViewModel? = nil, auth: AuthViewModel? = nil,
         autoStart: Bool = SignInViewController.defaultAutoStart,
         onAdded: ((AuthViewModel) -> Void)? = nil) {
        self.model = model
        self.evidence = evidence
        self.asSheet = asSheet
        self.adding = adding
        injectedAuth = auth
        autoStartPending = autoStart && evidence == nil && !model.options.demo
        added = onAdded.map(AddOnce.init)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    private var auth: AuthViewModel { injectedAuth ?? adding ?? model.app?.auth ?? AuthViewModel() }

    override func loadView() {
        let auth = self.auth
        let root = SignInView(auth: auth, evidence: evidence, asSheet: asSheet) { [weak self] in
            self?.model.dismissSheet()
        }
        // Content-sized host (`preferredContentSize` tracks the SwiftUI
        // fitting size), so the window can follow each screen's height.
        let host = Hosting.controller(root, role: .sheet, model: model)
        self.host = host
        addChild(host)
        view = NSView(frame: NSRect(origin: .zero, size: autoStartPending ? SignInWebController.contentSize : Self.contentSize))
        pin(host.view)
        if asSheet { preferredContentSize = autoStartPending ? SignInWebController.contentSize : Self.sheetSize }
        if case .web(let url)? = evidence {
            showWeb(url, redirectURI: SignInPresentation.fakeRedirect(for: url), auth: auth)
        }
        guard evidence == nil, !model.options.demo else { return }
        // A never-checked auth (launch race): read its status (no
        // network) so auto-start sees signed-out. Add Account's fresh
        // profile has nothing to read and starts from unknown.
        if autoStartPending, adding == nil, auth.state == .unknown {
            Task { await auth.refreshStatus() }
        }
        auth.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.authChanged(state, auth: auth) }
            .store(in: &cancellables)
    }

    private func pin(_ sub: NSView) {
        sub.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sub)
        NSLayoutConstraint.activate([
            sub.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sub.topAnchor.constraint(equalTo: view.topAnchor),
            sub.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// The content's fitting size at the window width (the embedded
    /// sign-in's size while it shows, or is about to).
    var fittingContentSize: NSSize {
        _ = view
        if webSignIn != nil || autoStartPending { return SignInWebController.contentSize }
        guard let h = host as? NSHostingController<HostedRoot<SignInView>> else { return Self.contentSize }
        let s = h.sizeThatFits(in: NSSize(width: Self.contentWidth, height: 2000))
        return NSSize(width: Self.contentWidth, height: max(Self.contentSize.height, s.height.rounded(.up)))
    }

    /// Start ↔ code screen: resize the window to the new content,
    /// keeping its top edge (and so the header) in place.
    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard !asSheet, webSignIn == nil, viewController === host else { return }
        resizeWindow(to: fittingContentSize)
    }

    /// Main window: follow `size` from the top edge. Sheet: resize the
    /// sheet in place.
    private func resizeWindow(to size: NSSize) {
        guard let window = view.window else { return }
        if asSheet {
            preferredContentSize = size
            window.setContentSize(size)
            return
        }
        guard window.contentViewController === self else { return }
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        guard abs(frame.height - window.frame.height) >= 1 || abs(frame.width - window.frame.width) >= 1 else { return }
        window.minSize = frame.size
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height,
                               width: frame.width, height: frame.height), display: true)
    }

    private func authChanged(_ state: AuthState, auth: AuthViewModel) {
        // Sign In Again / Add Account (sheet): success closes the sheet (§5.7).
        if asSheet, state == .signedIn {
            if let adding { added?.fire(adding) }
            model.dismissSheet()
            return
        }
        if autoStartPending {
            switch state {
            case .signedOut, .expired:
                autoStartPending = false
                Task { await auth.startBrowserSignIn() }
            case .unknown where adding != nil:
                autoStartPending = false
                Task { await auth.startBrowserSignIn() }
            case .unknown, .starting, .browser:
                break
            default:
                // Anything else (error, code): the start screen, sized to it.
                autoStartPending = false
                if !asSheet { resizeWindow(to: fittingContentSize) }
            }
        }
        if case .browser(let info) = state, webSignIn == nil, let url = URL(string: info.authorizeURL) {
            showWeb(url, redirectURI: info.redirectURI, auth: auth)
        }
    }

    /// Embed Microsoft sign-in over the start screen: same store as the
    /// sheet used (the account's, so web apps share the session).
    private func showWeb(_ url: URL, redirectURI: String, auth: AuthViewModel) {
        let web = model.frameHost.makeSignInWebView(addingProfile: adding?.profile)
        let vc = SignInWebController(web: web, start: url, redirectURI: redirectURI, onFinish: { [weak self] callback in
            guard let self else { return }
            self.hideWeb()
            if let callback {
                let added = self.added
                Task {
                    await auth.completeBrowserSignIn(callbackURL: callback)
                    if self.asSheet, auth.state == .signedIn { added?.fire(auth) }
                }
            } else {
                auth.cancelBrowser()
                // Sheets: Cancel ends Add Account / Sign In Again.
                if self.asSheet { self.model.dismissSheet() }
            }
        }, onUseCode: { [weak self] in
            guard let self else { return }
            self.hideWeb()
            auth.cancelBrowser()
            Task { await auth.signIn() }
        })
        webSignIn = vc
        addChild(vc)
        // Out of the hierarchy, not hidden: a hidden hosting view still
        // pins the window to the start screen's fitting size.
        host?.view.removeFromSuperview()
        pin(vc.view)
        resizeWindow(to: SignInWebController.contentSize)
    }

    private func hideWeb() {
        guard let vc = webSignIn else { return }
        webSignIn = nil
        vc.view.removeFromSuperview()
        vc.removeFromParent()
        if let hosted = host?.view { pin(hosted) }
        resizeWindow(to: asSheet ? Self.sheetSize : fittingContentSize)
    }
}

/// Add Account's completion, run once whichever path signs in first.
@MainActor
final class AddOnce {
    private var action: ((AuthViewModel) -> Void)?
    init(_ action: @escaping (AuthViewModel) -> Void) { self.action = action }

    func fire(_ vm: AuthViewModel) {
        let a = action
        action = nil
        a?(vm)
    }
}

struct SignInView: View {
    @ObservedObject var auth: AuthViewModel
    let evidence: SignInPresentation?
    let asSheet: Bool
    let close: () -> Void

    private var code: AuthCodeInfo? {
        if case .code(let c)? = evidence {
            return AuthCodeInfo(session: "demo", verificationURI: "https://microsoft.com/devicelogin",
                                userCode: c, message: "", expiresIn: 900, interval: 5)
        }
        guard evidence == nil else { return nil }
        switch auth.state {
        case .code(let info), .polling(let info, _): return info
        default: return nil
        }
    }

    private var busy: Bool {
        guard evidence == nil else { return false }
        switch auth.state {
        case .starting, .browser, .browserWorking, .refreshing: return true
        default: return false
        }
    }

    private var errorText: String? {
        guard evidence == nil else { return nil }
        switch auth.state {
        case .error(let m), .refreshFailed(let m): return m
        case .expired: return "Your session expired. Sign in again."
        default: return nil
        }
    }

    /// Header top inset: fixed, so the icon and title sit at the same
    /// place on both screens; the content hangs below (never re-centered)
    /// and the window ends `contentBottom` under it.
    /// The app icon's artwork sits inside a transparent margin (100 of
    /// 1024 px on the macOS icon grid, 6.25 pt at 64 pt), so the visible
    /// top gap is `headerTop` + that margin: equal to `contentBottom`
    /// keeps both sign-in screens vertically centered.
    static let contentBottom: CGFloat = 40
    static let headerTop: CGFloat = contentBottom - 64 * 100 / 1024

    var body: some View {
        VStack(spacing: 16) {
            SignInHeader(title: code == nil ? "Sign In to Better Teams" : "Enter This Code")
            if let code {
                DeviceCodeView(code: code, auth: auth, isEvidence: evidence != nil) {
                    if asSheet { close() }
                }
            } else {
                start
            }
            if asSheet, code == nil {
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, Self.headerTop)
        .padding(.bottom, Self.contentBottom)
        .frame(minWidth: SignInViewController.contentWidth, maxWidth: .infinity,
               maxHeight: .infinity, alignment: .top)
    }

    private var start: some View {
        VStack(spacing: 16) {
            Text("Use your work or school Microsoft account.")
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                Button {
                    // Evidence: enabled look, no-op action.
                    if evidence == nil { Task { await auth.startBrowserSignIn() } }
                } label: {
                    Text("Sign In with Microsoft").frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Button {
                    if evidence == nil { Task { await auth.signIn() } }
                } label: {
                    Text("Use a Device Code").frame(minWidth: 220)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .disabled(busy)
            .padding(.top, 8)
            if busy { ProgressView().controlSize(.small) }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
