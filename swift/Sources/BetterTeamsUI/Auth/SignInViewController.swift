// SignInViewController.swift — signed-out window content (UI-SPEC
// §5.7): centered, no rail, no split view. "Sign In with Microsoft"
// opens the in-app browser sheet (§7.4); "Use a Device Code" shows the
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
}

@MainActor
final class SignInViewController: NSViewController {
    private let model: WindowModel
    private let evidence: SignInPresentation?
    private let asSheet: Bool
    /// Add Account: the new profile's VM (nil = the window's own auth).
    private let adding: AuthViewModel?
    private let added: AddOnce?
    private var cancellables = Set<AnyCancellable>()
    private var webSheetOpen = false

    /// Content width (HIG windows: sized to the content, not the shell).
    static let contentWidth: CGFloat = 540
    /// Smallest content size (the start screen fits well inside it).
    static let contentSize = NSSize(width: contentWidth, height: 300)
    private var host: NSViewController?

    init(model: WindowModel, evidence: SignInPresentation?, asSheet: Bool = false,
         adding: AuthViewModel? = nil, onAdded: ((AuthViewModel) -> Void)? = nil) {
        self.model = model
        self.evidence = evidence
        self.asSheet = asSheet
        self.adding = adding
        added = onAdded.map(AddOnce.init)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func loadView() {
        let auth = adding ?? model.app?.auth ?? AuthViewModel()
        let root = SignInView(auth: auth, evidence: evidence, asSheet: asSheet) { [weak self] in
            self?.model.dismissSheet()
        }
        // Content-sized host (`preferredContentSize` tracks the SwiftUI
        // fitting size), so the window can follow each screen's height.
        let host = Hosting.controller(root, role: .sheet, model: model)
        self.host = host
        addChild(host)
        view = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        if asSheet { preferredContentSize = NSSize(width: 480, height: 420) }
        guard evidence == nil, !model.options.demo else { return }
        auth.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.authChanged(state, auth: auth) }
            .store(in: &cancellables)
    }

    /// The content's fitting size at the window width.
    var fittingContentSize: NSSize {
        _ = view
        guard let h = host as? NSHostingController<HostedRoot<SignInView>> else { return Self.contentSize }
        let s = h.sizeThatFits(in: NSSize(width: Self.contentWidth, height: 2000))
        return NSSize(width: Self.contentWidth, height: max(Self.contentSize.height, s.height.rounded(.up)))
    }

    /// Start ↔ code screen: resize the window to the new content,
    /// keeping its top edge (and so the header) in place.
    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard !asSheet, viewController === host, let window = view.window,
              window.contentViewController === self else { return }
        let size = fittingContentSize
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        guard abs(frame.height - window.frame.height) >= 1 || abs(frame.width - window.frame.width) >= 1 else { return }
        window.minSize = frame.size
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height,
                               width: frame.width, height: frame.height), display: true)
    }

    /// Browser sign-in: present the web sheet once per attempt.
    private func authChanged(_ state: AuthState, auth: AuthViewModel) {
        // Sign In Again (sheet): success closes the sheet (§5.7).
        if asSheet, state == .signedIn {
            if let adding { added?.fire(adding) }
            model.dismissSheet()
            return
        }
        guard case .browser(let info) = state, !webSheetOpen, let url = URL(string: info.authorizeURL) else { return }
        webSheetOpen = true
        // One sheet at a time (R17): as a sheet, sign-in makes way for the
        // web sheet. The completion captures the model and auth, not self,
        // because dismissing this sheet releases this controller.
        if asSheet { model.dismissSheet() }
        let model = self.model
        let added = self.added
        let sheet = WebAuthSheet(web: model.frameHost.makeSignInWebView(ephemeral: adding != nil), start: url,
                                 redirectURI: info.redirectURI) { [weak self] callback in
            self?.webSheetOpen = false
            model.dismissSheet()
            if let callback {
                Task {
                    await auth.completeBrowserSignIn(callbackURL: callback)
                    // This controller is gone (its sheet made way), so
                    // the add completes here.
                    if auth.state == .signedIn { added?.fire(auth) }
                }
            } else {
                auth.cancelBrowser()
            }
        }
        let shown = model.presenter?.present(sheet, request: SheetRequest("webSignIn", in: model.nav.section)) ?? false
        if !shown {
            webSheetOpen = false
            auth.cancelBrowser()
        }
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
