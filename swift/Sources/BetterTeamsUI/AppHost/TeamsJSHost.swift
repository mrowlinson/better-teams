// TeamsJSHost.swift — hosts a Teams app page (manifest static tab
// contentUrl) in a WKWebView without the Teams web shell, by speaking
// the TeamsJS host protocol ourselves (github.com/OfficeDev/
// microsoft-teams-library-js, internal/communication.ts). Hardened from
// the APPHOST spike (tmp/APPHOST-SPIKE.md).
//
// Wire format (messageObjects.ts): request {id, uuidAsString, func,
// args, timestamp, apiVersionTag}; response {id, uuidAsString, args};
// host event {func, args}. Transports: see `TeamsJSTransport`.
//
// Hardening over the spike: frameless messages are only accepted from
// the main frame while it shows an app origin; the iframe host page
// relays only its own child's messages and replies to the app origin
// (never '*', except the demo's srcdoc page); getAuthToken mints only
// for the manifest resource (`TeamsJSPolicy.authResource`); NAA tokens
// only for the app's own origin; navigation follows validDomains.
// Tokens go to the page only; nothing here logs a token or a URL.
import AppKit
import Foundation
import OstMacCore
import WebKit

public enum TeamsJSTokenResult: Sendable, Equatable {
    case token(String, expiresIn: Int?, idToken: String? = nil)
    /// `transient`: offline/network; do not fall back to the Teams shell.
    case failure(String, transient: Bool)
}

/// Mints tokens for hosted apps (core broker live, fixed fakes in demo).
@MainActor
public protocol TeamsJSTokenBroker: AnyObject {
    func authToken(resource: String) async -> TeamsJSTokenResult
    func naaToken(clientID: String, scopes: String, origin: String) async -> TeamsJSTokenResult
}

/// One observed protocol message (unknown-API table, diagnostics).
/// `detail` is shape only (types/lengths), never values.
public struct TeamsJSEvent: Sendable, Equatable {
    public let function: String
    public let detail: String
    public let answered: Bool
}

@MainActor
public final class TeamsJSHost: NSObject {
    public static let handlerName = "btTeamsJS"
    /// Paint report of the app's page (text/element counts only).
    public static let probeHandlerName = "btTeamsJSProbe"
    /// Host SDK level reported to the app.
    public static let clientSDKVersion = "2.56.0"
    /// Largest message accepted from a page (bytes of JSON).
    static let maxMessage = 1 << 20

    public let transport: TeamsJSTransport
    public let launch: TeamsAppLaunch
    public private(set) var context: TeamsJSAppContext
    public private(set) weak var web: WKWebView?
    public weak var broker: TeamsJSTokenBroker?
    /// Advertise nested app auth (MSAL.js apps then ask the host).
    public var advertiseNAA = true
    /// Demo sample page (about:blank origin): accept messages from it.
    public var trustsBlankOrigin = false
    public var onEvent: ((TeamsJSEvent) -> Void)?
    /// The app cannot work in the native host (auth failed for good):
    /// the frame should switch this app to its Teams-shell page.
    public var onFallback: ((String) -> Void)?
    /// Automatic host mode (APPHOST-B3): app-reported failures also fall
    /// back. Off when the user forced the native host.
    public var watchesFailures = false
    /// Last paint report from the app's own frame: nil = none yet.
    public private(set) var paint: TeamsJSPaintReport?
    /// getAuthToken needs the user's consent (AADSTS65001): show the
    /// Microsoft consent page; true = the user finished it (retry).
    public var onConsent: ((String) async -> Bool)?
    /// `authentication.authenticate`: the app's auth page in a sheet;
    /// resolves to (success, result or reason).
    public var onAuthenticate: ((URL) async -> (Bool, String))?
    /// Auth window host (frameContext "authentication"): the page
    /// called notifySuccess / notifyFailure.
    public var onAuthResult: ((Bool, String) -> Void)?
    private var consentAsked = false
    /// A Teams deep link (`/l/...`) the app opened: true when the window
    /// routed it natively (APPHOST-B2). Nil or false → default browser.
    public var onDeepLink: ((URL) -> Bool)?
    public private(set) var appSDKVersion: String?
    public private(set) var initialized = false
    /// APIs the app called that the host does not implement yet.
    public private(set) var unhandled: [String: Int] = [:]
    private var appearanceObservation: NSKeyValueObservation?
    private var fellBack = false

    public init(transport: TeamsJSTransport, launch: TeamsAppLaunch, context: TeamsJSAppContext) {
        self.transport = transport
        self.launch = launch
        self.context = context
    }

    /// Registers the message handler (and, frameless, the shim).
    public func install(into controller: WKUserContentController) {
        controller.add(WeakScriptHandler(self), name: Self.handlerName)
        controller.add(WeakScriptHandler(self, probe: true), name: Self.probeHandlerName)
        controller.addUserScript(WKUserScript(source: Self.paintProbe, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: false))
        if transport == .frameless {
            controller.addUserScript(WKUserScript(source: Self.framelessShim, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true))
        }
    }

    public static func uninstall(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: handlerName)
        controller.removeScriptMessageHandler(forName: probeHandlerName)
    }

    /// Binds the view; follows its appearance (themeChange events).
    public func attach(_ web: WKWebView) {
        self.web = web
        appearanceObservation = web.observe(\.effectiveAppearance, options: [.new]) { [weak self] w, _ in
            MainActor.assumeIsolated { self?.setTheme(TeamsJSPolicy.theme(for: w.effectiveAppearance)) }
        }
    }

    public func detach() {
        appearanceObservation = nil
        web = nil
    }

    /// The URL to load (frameless) or embed (iframe).
    public var contentURL: URL? {
        URL(string: TeamsJSPolicy.expand(launch.contentTemplate, context))
    }

    // MARK: page scripts

    /// Every frame: 12 s after the DOM is ready, report visible text
    /// length and sized content elements (counts only, never content);
    /// a blank frame looks again 8 s later and reports either way.
    static let paintProbe = """
    (function () {
      var m = window.webkit && window.webkit.messageHandlers;
      var h = m && m.\(probeHandlerName);
      if (!h) { return; }
      function report(last) {
        var b = document.body, text = b ? (b.innerText || '').trim().length : 0, items = 0;
        var els = document.querySelectorAll('img,canvas,video,svg,embed,object,input,button,textarea,select');
        for (var i = 0; i < els.length && items < 50; i++) {
          var r = els[i].getBoundingClientRect();
          if (r.width * r.height >= 256) { items++; }
        }
        if (text > 0 || items > 0 || last) { h.postMessage(JSON.stringify({text: text, items: items})); return true; }
        return false;
      }
      function start() { setTimeout(function () { if (!report(false)) { setTimeout(function () { report(true); }, 8000); } }, 12000); }
      if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', start); } else { start(); }
    })();
    """

    /// Frameless: TeamsJS transport plus a native nested-app-auth bridge
    /// (TeamsJS does not polyfill `nestedAppAuthBridge` when frameless;
    /// MSAL.js looks for it on window).
    static let framelessShim = """
    (function () {
      if (window.nativeInterface || window.parent !== window) { return; }
      var h = window.webkit.messageHandlers.\(handlerName);
      window.nativeInterface = {
        framelessPostMessage: function (msg) { h.postMessage(String(msg)); }
      };
      var naa = [];
      window.nestedAppAuthBridge = {
        postMessage: function (m) { h.postMessage(JSON.stringify({func: 'nestedAppAuth.execute', data: String(m)})); },
        addEventListener: function (t, cb) { if (t === 'message') { naa.push(cb); } },
        removeEventListener: function (t, cb) { var i = naa.indexOf(cb); if (i >= 0) { naa.splice(i, 1); } }
      };
      Object.defineProperty(window, '__btNAAReply', { value: function (s) {
        naa.slice().forEach(function (cb) { try { cb(s); } catch (e) {} });
      } });
    })();
    """

    /// Host page for the iframe transport, loaded with baseURL
    /// https://teams.microsoft.com/ (TeamsJS validOrigins and the app's
    /// frame-ancestors accept it). Relays only its child's messages,
    /// only from `appOrigin`, and replies only to `appOrigin`. `srcdoc`
    /// (demo) inherits the host origin, so it uses '*' / any origin.
    public static func iframeHostHTML(src: URL?, srcdoc: String? = nil) -> String {
        let attr: String
        let origin: String
        if let srcdoc {
            attr = "srcdoc=\"\(htmlAttr(srcdoc))\""
            origin = "*"
        } else {
            attr = "src=\"\(htmlAttr(src?.absoluteString ?? "about:blank"))\""
            origin = src.flatMap(Self.origin(of:)) ?? "null"
        }
        let originLit = jsString(origin) ?? "\"null\""
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>:root{color-scheme:light dark}html,body{margin:0;height:100%;overflow:hidden}
        iframe{border:0;width:100%;height:100%;display:block}</style>
        </head><body>
        <iframe id="app" \(attr) allow="clipboard-read; clipboard-write; fullscreen; autoplay; microphone; camera"></iframe>
        <script>
        (function () {
          var f = document.getElementById('app'), o = \(originLit);
          window.addEventListener('message', function (e) {
            if (e.source !== f.contentWindow) { return; }
            if (o !== '*' && e.origin !== o) { return; }
            try { window.webkit.messageHandlers.\(handlerName).postMessage(JSON.stringify(e.data)); } catch (x) {}
          });
          Object.defineProperty(window, 'btReply', { value: function (r) { f.contentWindow.postMessage(r, o); } });
        })();
        </script></body></html>
        """
    }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    static func htmlAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: runtime + context

    func runtimeConfigJSON() -> String {
        let empty: [String: Any] = [:]
        var supports: [String: Any] = [
            "authentication": empty,
            "pages": ["appButton": empty, "tabs": empty, "config": empty, "backStack": empty],
            "teamsCore": empty,
            "appInitialization": empty,
        ]
        if advertiseNAA { supports["nestedAppAuth"] = empty }
        let runtime: [String: Any] = [
            "apiVersion": 4,
            "hostVersionsInfo": ["adaptiveCardSchemaVersion": ["majorVersion": 1, "minorVersion": 5]],
            "isLegacyTeams": false,
            "isNAAChannelRecommended": advertiseNAA,
            "supports": supports,
        ]
        return Self.json(runtime) ?? "{}"
    }

    func legacyContext() -> [String: Any] {
        let c = context
        var d: [String: Any] = [
            "locale": c.locale, "theme": c.theme, "entityId": c.entityId, "subEntityId": c.subEntityId,
            "frameContext": c.frameContext, "hostClientType": c.hostClientType, "hostName": c.hostName,
            "sessionId": c.sessionId, "appSessionId": c.appSessionId, "appLaunchId": c.appSessionId,
            "ringId": "general", "tid": c.tenantId, "userObjectId": c.userObjectId,
            "userPrincipalName": c.userPrincipalName, "loginHint": c.userPrincipalName,
            "userDisplayName": c.userDisplayName,
            "userLicenseType": "Unknown", "tenantSKU": "enterprise", "isFullScreen": false,
            "isMultiWindow": false, "isCallingAllowed": false, "isPSTNCallingAllowed": false,
            "appId": c.appId, "userClickTime": Int(Date().timeIntervalSince1970 * 1000),
            "osLocaleInfo": ["platform": "macos", "regionalFormat": c.locale],
        ]
        if let v = c.teamId { d["teamId"] = v }
        if let v = c.channelId { d["channelId"] = v }
        if let v = c.groupId { d["groupId"] = v }
        if let v = c.teamName { d["teamName"] = v }
        if let v = c.channelName { d["channelName"] = v; d["channelType"] = "Regular" }
        return d
    }

    /// NAA account (MSAL `AccountInfo`).
    func naaAccount() -> [String: Any] {
        let c = context
        return ["homeAccountId": "\(c.userObjectId).\(c.tenantId)", "environment": "login.microsoftonline.com",
                "tenantId": c.tenantId, "username": c.userPrincipalName, "localAccountId": c.userObjectId,
                "name": c.userDisplayName]
    }

    /// Theme follows the frame's appearance (`themeChange` event).
    public func setTheme(_ theme: String) {
        guard theme != context.theme else { return }
        context.theme = theme
        sendEvent("themeChange", [theme])
    }

    // MARK: dispatch

    /// Accepts a page message. Frameless: main frame only, and only
    /// while it shows the app (or the demo's about:blank). Iframe: the
    /// host page (main frame) relays its child's messages.
    func receive(_ body: Any, isMainFrame: Bool, origin: URL?) {
        guard isMainFrame, let s = body as? String, s.utf8.count <= Self.maxMessage,
              let data = s.data(using: .utf8),
              let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let fn = req["func"] as? String else { return }
        if transport == .frameless, !pageIsApp(origin) {
            emit(fn, "refused: not an app origin", false)
            return
        }
        let args = req["args"] as? [Any] ?? []
        switch fn {
        case "initialize":
            appSDKVersion = args.first as? String ?? "1.0.0"
            initialized = true
            // [frameContext, clientType, sdkVersion, runtimeJSON]: v1 reads
            // args[2] as the SDK version; v2 accepts either order and its
            // NAA polyfill parses args[3] as the runtime.
            respond(req, [context.frameContext, context.hostClientType, Self.clientSDKVersion, runtimeConfigJSON()])
            emit(fn, "sdk", true)
        case "getContext":
            respond(req, [legacyContext()])
            emit(fn, "", true)
        case "authentication.getAuthToken":
            let resources = (args.first as? [Any])?.compactMap { $0 as? String } ?? []
            emit(fn, "resources=\(resources.count)", true)
            getAuthToken(req, requested: resources)
        case "authentication.getUser":
            respond(req, [false, "getUser is not supported"])
            emit(fn, "", true)
        case "appInitialization.failure", "appInitialization.expectedFailure":
            let reason = (args.first as? String) ?? ""
            emit(fn, "reason=\(reason.prefix(40))", false)
            if reason == "AuthFailed" || reason == "Unauthorized" {
                fallBack("app reported \(reason)")
            } else if TeamsJSPolicy.isFailure(fn, reason: reason) {
                failed("app reported \(reason.isEmpty ? "a failure" : String(reason.prefix(24)))")
            }
        case "authentication.authenticate":
            emit(fn, "", true)
            authenticate(req, args)
        case "authentication.authenticate.success", "authentication.notifySuccess":
            emit(fn, "", false)
            onAuthResult?(true, (args.first as? String) ?? "")
        case "authentication.authenticate.failure", "authentication.notifyFailure":
            emit(fn, "", false)
            // Only an auth window may report; the content page doing so
            // means its own sign-in failed.
            if context.frameContext == "authentication" {
                onAuthResult?(false, (args.first as? String) ?? "")
            } else {
                failed("app sign-in failed")
            }
        case "appInitialization.appLoaded", "appInitialization.success":
            emit(fn, "", false)
        case "nestedAppAuth.execute":
            handleNAA(req["data"] as? String ?? (args.first as? String) ?? "")
        case "registerHandler":
            emit(fn, (args.first as? String).map { String($0.prefix(40)) } ?? "?", false)
        case "executeDeepLink", "openLink", "pages.navigateToApp", "navigateToApp":
            openLink(req, raw: Self.linkArg(fn, args))
        case "navigateCrossDomain":
            navigateCrossDomain(req, raw: args.first as? String)
        case "navigateBack", "pages.backStack.navigateBack":
            let back = web?.canGoBack ?? false
            if back { web?.goBack() }
            respond(req, [back])
            emit(fn, "", true)
        default:
            // Unadvertised/private API: count it, do not answer (TeamsJS
            // gates public APIs on runtime.supports before sending).
            unhandled[fn, default: 0] += 1
            emit(fn, Self.shape(args), false)
        }
    }

    private func pageIsApp(_ origin: URL?) -> Bool {
        guard let origin, let scheme = origin.scheme?.lowercased(), scheme != "about" else {
            return trustsBlankOrigin
        }
        return TeamsJSPolicy.isAppOrigin(origin, launch: launch)
    }

    private func getAuthToken(_ req: [String: Any], requested: [String]) {
        guard let resource = TeamsJSPolicy.authResource(requested: requested, launch: launch) else {
            respond(req, [false, "The app manifest has no webApplicationInfo resource."])
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.broker?.authToken(resource: resource)
                ?? .failure("No token broker.", transient: false)
            switch result {
            case .token(let t, _, _): self.respond(req, [true, t])
            case .failure(let why, _):
                // Teams shows a consent prompt here; once, then retry.
                if TeamsJSPolicy.needsConsent(why), !self.consentAsked, let ask = self.onConsent {
                    self.consentAsked = true
                    self.emit("consent", "asked", true)
                    if await ask(resource),
                       case .token(let t, _, _)? = await self.broker?.authToken(resource: resource) {
                        self.respond(req, [true, t])
                        return
                    }
                    self.respond(req, [false, "resourceRequiresConsent"])
                    return
                }
                self.respond(req, [false, why])
            }
        }
    }

    /// `authentication.authenticate([url, width, height, isExternal])`:
    /// only the app's own https pages (or Microsoft sign-in) open.
    private func authenticate(_ req: [String: Any], _ args: [Any]) {
        guard let raw = args.first as? String,
              let url = URL(string: raw, relativeTo: web?.url)?.absoluteURL,
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              TeamsJSPolicy.isAppOrigin(url, launch: launch) || FramePolicy.hostMatches(host, TeamsJSPolicy.authHosts),
              let open = onAuthenticate
        else {
            respond(req, [false, "Authentication is limited to the app's own pages."])
            return
        }
        Task { @MainActor [weak self] in
            let (ok, result) = await open(url)
            self?.respond(req, [ok, result])
        }
    }

    private func openLink(_ req: [String: Any], raw: String?) {
        guard let raw, let url = URL(string: raw), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
        else {
            respond(req, [false, "Invalid link."])
            return
        }
        if TeamsDeepLink.parse(url) != nil {
            // Teams deep links route to native sections (APPHOST-B2).
            let routed = onDeepLink?(url) ?? false
            if !routed, !trustsBlankOrigin { NSWorkspace.shared.open(url) }
            respond(req, [true])
            emit("deepLink.teams", routed ? "native" : "browser", true)
            return
        }
        if !trustsBlankOrigin { NSWorkspace.shared.open(url) }
        respond(req, [true])
        emit("openLink", "external", true)
    }

    /// The link a navigation call carries: a URL string (openLink,
    /// executeDeepLink) or `navigateToApp` params `{appId, pageId,
    /// subPageId, channelId}` turned into an `/l/entity/` link.
    static func linkArg(_ fn: String, _ args: [Any]) -> String? {
        if let s = args.first as? String { return s }
        guard let p = args.first as? [String: Any], let app = p["appId"] as? String, !app.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        c.host = "teams.microsoft.com"
        c.path = "/l/entity/\(app)/\((p["pageId"] as? String) ?? "")"
        var ctx: [String: Any] = [:]
        if let s = p["subPageId"] as? String { ctx["subEntityId"] = s }
        if let ch = p["channelId"] as? String { ctx["channelId"] = ch }
        if !ctx.isEmpty, let j = json(ctx) { c.queryItems = [URLQueryItem(name: "context", value: j)] }
        return c.url?.absoluteString
    }

    private func navigateCrossDomain(_ req: [String: Any], raw: String?) {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https",
              TeamsJSPolicy.allowsNavigation(url, launch: launch), let web
        else {
            respond(req, [false, "Navigation is limited to the app's valid domains."])
            return
        }
        web.load(URLRequest(url: url))
        respond(req, [true])
    }

    // MARK: nested app auth (MSAL.js bridge)

    /// MSAL.js NAA bridge request (`BridgeRequest`): GetInitContext,
    /// GetActiveAccount, GetToken, GetTokenPopup.
    private func handleNAA(_ data: String) {
        guard data.utf8.count <= Self.maxMessage, let d = data.data(using: .utf8),
              let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            emit("nestedAppAuth.execute", "unparsed", false)
            return
        }
        let method = m["method"] as? String ?? "?"
        let requestID = m["requestId"] ?? ""
        emit("naa.\(method)", "", true)
        switch method {
        case "GetInitContext":
            naaReply(requestID, ["success": true, "initContext": [
                "sdkName": "BetterTeamsHost", "sdkVersion": "1.0.0",
                "capabilities": ["queryAccount": false],
                "accountContext": ["homeAccountId": naaAccount()["homeAccountId"] ?? "",
                                   "environment": "login.microsoftonline.com", "tenantId": context.tenantId],
            ] as [String: Any]])
        case "GetActiveAccount":
            if context.userObjectId.isEmpty {
                naaReply(requestID, naaError("ACCOUNT_UNAVAILABLE", "no_account", "No signed-in account."))
            } else {
                naaReply(requestID, ["success": true, "account": naaAccount()])
            }
        case "GetToken", "GetTokenPopup":
            let tp = m["tokenParams"] as? [String: Any] ?? [:]
            let client = (tp["clientId"] as? String) ?? ""
            let scope = (tp["scope"] as? String) ?? (tp["scopes"] as? [String])?.joined(separator: " ") ?? ""
            naaToken(requestID, client: client, scope: scope)
        default:
            naaReply(requestID, naaError("PERSISTENT_ERROR", "unsupported_method", "\(method.prefix(40)) is not supported."))
        }
    }

    private func naaToken(_ requestID: Any, client: String, scope: String) {
        // The page origin is ours to observe, never the app's to claim.
        // Demo (about:blank) and iframe pages stand for the content URL.
        let pageOrigin: URL? = transport == .frameless && !trustsBlankOrigin ? web?.url : contentURL
        guard let pageOrigin, let origin = Self.origin(of: pageOrigin),
              TeamsJSPolicy.isAppOrigin(pageOrigin, launch: launch),
              !client.isEmpty, !scope.isEmpty
        else {
            naaReply(requestID, naaError("PERSISTENT_ERROR", "invalid_request", "Token request refused by host."))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.broker?.naaToken(clientID: client, scopes: scope, origin: origin)
                ?? .failure("No token broker.", transient: false)
            switch result {
            case .token(let t, let expires, let idToken):
                // MSAL.js rejects a reply without an id token (nullOrEmptyToken).
                self.naaReply(requestID, ["success": true, "account": self.naaAccount(), "token": [
                    "access_token": t, "expires_in": expires ?? 3600, "id_token": idToken ?? "", "scope": scope,
                    "token_type": "Bearer", "properties": NSNull(),
                ] as [String: Any]])
            case .failure(let why, let transient):
                self.naaReply(requestID, self.naaError(transient ? "NO_NETWORK" : "ACCOUNT_UNAVAILABLE",
                                                        transient ? "no_network" : "broker_failed", why))
                if !transient { self.fallBack("nested app auth failed") }
            }
        }
    }

    private func naaError(_ status: String, _ code: String, _ description: String) -> [String: Any] {
        ["success": false, "error": ["status": status, "code": code, "description": description]]
    }

    private func naaReply(_ requestID: Any, _ body: [String: Any]) {
        var resp = body
        resp["messageType"] = "NestedAppAuthResponse"
        resp["requestId"] = requestID
        guard let web, let json = Self.json(resp), let lit = Self.jsString(json) else { return }
        let js = transport == .frameless
            ? "window.__btNAAReply && window.__btNAAReply(\(lit));"
            : "window.btReply && window.btReply({args: [null, \(lit)]});"
        web.evaluateJavaScript(js, completionHandler: nil)
    }

    private func fallBack(_ why: String) {
        guard !fellBack else { return }
        fellBack = true
        onFallback?(why)
    }

    /// A failure the app or page reported: falls back in Automatic mode.
    func failed(_ why: String) {
        guard watchesFailures else { return }
        fallBack(why)
    }

    /// A paint report from a frame: only the app's own frame counts
    /// (frameless: the main frame; iframe: the embedded app frame).
    func receiveProbe(_ body: Any, isMainFrame: Bool, origin: URL?) {
        guard let s = body as? String, s.utf8.count < 256, let d = s.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        let appFrame = transport == .frameless ? isMainFrame : !isMainFrame
        guard appFrame, pageIsApp(origin) else { return }
        paint = TeamsJSPaintReport(text: o["text"] as? Int ?? 0, items: o["items"] as? Int ?? 0)
    }

    // MARK: delivery

    /// Host → app event (e.g. `themeChange`, `["dark"]`).
    public func sendEvent(_ fn: String, _ args: [Any]) {
        guard initialized else { return }
        deliver(["func": fn, "args": args])
    }

    private func respond(_ req: [String: Any], _ args: [Any]) {
        var r: [String: Any] = ["id": req["id"] ?? 0, "args": args]
        if let u = req["uuidAsString"] { r["uuidAsString"] = u }
        deliver(r)
    }

    private func deliver(_ message: [String: Any]) {
        guard let web, let json = Self.json(message) else { return }
        let js = transport == .frameless
            ? "window.onNativeMessage && window.onNativeMessage({data: \(json)});"
            : "window.btReply && window.btReply(\(json));"
        web.evaluateJavaScript(js, completionHandler: nil)
    }

    private func emit(_ fn: String, _ detail: String, _ answered: Bool) {
        onEvent?(TeamsJSEvent(function: fn, detail: detail, answered: answered))
    }

    static func json(_ o: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func jsString(_ s: String) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return nil }
        return String(data: d, encoding: .utf8)?.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// Argument shape only (types/lengths), never values.
    static func shape(_ args: [Any]) -> String {
        args.map { a -> String in
            switch a {
            case let s as String: return "str\(s.count)"
            case is NSNumber: return "num"
            case let arr as [Any]: return "arr\(arr.count)"
            case let d as [String: Any]: return "obj\(d.count)"
            case is NSNull: return "null"
            default: return "?"
            }
        }.joined(separator: " ")
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
@MainActor
/// What the app's frame painted (counts only).
public struct TeamsJSPaintReport: Sendable, Equatable {
    public let text: Int
    public let items: Int
    public var isBlank: Bool { text == 0 && items == 0 }
}

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var host: TeamsJSHost?
    let probe: Bool
    init(_ host: TeamsJSHost, probe: Bool = false) {
        self.host = host
        self.probe = probe
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let o = message.frameInfo.securityOrigin
        let origin = o.host.isEmpty
            ? URL(string: "about:blank")
            : URL(string: o.port > 0 ? "\(o.`protocol`)://\(o.host):\(o.port)" : "\(o.`protocol`)://\(o.host)")
        if probe {
            host?.receiveProbe(message.body, isMainFrame: message.frameInfo.isMainFrame, origin: origin)
        } else {
            host?.receive(message.body, isMainFrame: message.frameInfo.isMainFrame, origin: origin)
        }
    }
}
