// AppHostBrokers.swift — token sources for the native TeamsJS host:
// the core broker (live: refresh-token grants in Rust via
// TeamsAppService, off the main thread) and the demo broker (fixed fake strings, no network), plus
// the demo sample TeamsJS app (a local page that exercises the host so
// it can be seen and screenshotted without an account).
import Foundation
import OstMacCore

/// Live broker: `ostmac_token_for_scope_for` / `ostmac_naa_token_for`.
@MainActor
final class CoreTokenBroker: TeamsJSTokenBroker {
    let profile: String?

    init(profile: String?) { self.profile = profile }

    func authToken(resource: String) async -> TeamsJSTokenResult {
        let profile = profile
        return Self.map(await TeamsAppService.token(profile: profile, scopes: resource))
    }

    func naaToken(clientID: String, scopes: String, origin: String) async -> TeamsJSTokenResult {
        let profile = profile
        return Self.map(await TeamsAppService.naaToken(profile: profile, clientID: clientID, scopes: scopes,
                                                       origin: origin))
    }

    private static func map(_ result: Result<TeamsAppToken, any Error>) -> TeamsJSTokenResult {
        switch result {
        case .success(let t):
            return .token(t.token, expiresIn: t.expiresIn, idToken: t.idToken)
        case .failure(let e):
            let msg: String
            if case CoreCallError.failed(let m) = e { msg = m } else { msg = e.localizedDescription }
            return .failure(Self.userMessage(msg), transient: Self.isTransient(msg))
        }
    }

    /// Network trouble (retry later) vs. a refused grant (fall back).
    static func isTransient(_ detail: String) -> Bool {
        let d = detail.lowercased()
        return ["unreachable", "error sending request", "timed out", "connection", "dns"].contains { d.contains($0) }
    }

    /// First line, no request detail (core errors never carry tokens).
    static func userMessage(_ detail: String) -> String {
        String(detail.split(separator: "\n").first ?? "Token request failed.").prefix(200).description
    }
}

/// Demo broker: fixed fake tokens (not credentials), no network.
@MainActor
final class DemoTokenBroker: TeamsJSTokenBroker {
    static let fakeToken = "demo-token-not-a-real-credential"

    func authToken(resource: String) async -> TeamsJSTokenResult {
        .token(Self.fakeToken, expiresIn: 3600)
    }

    func naaToken(clientID: String, scopes: String, origin: String) async -> TeamsJSTokenResult {
        .token(Self.fakeToken, expiresIn: 3600)
    }
}

/// The demo sample TeamsJS app: route `app/demo-teamsjs` (frameless)
/// and `app/demo-teamsjs-iframe` (iframe transport).
public enum DemoTeamsJSApp {
    public static let appID = "demo-teamsjs"
    public static let iframeAppID = "demo-teamsjs-iframe"

    public static let identity = TeamsAppIdentity(
        tenantId: "00000000-0000-0000-0000-00000000c0de", userObjectId: "00000000-0000-0000-0000-0000000a1e70",
        upn: "alex.morgan@contoso.example", name: "Alex Morgan")

    static func launch(_ transport: TeamsJSTransport) -> TeamsAppLaunch {
        TeamsAppLaunch(
            appID: transport == .iframe ? iframeAppID : appID, entityID: "home",
            contentTemplate: "https://sample.contoso.example/tab?locale={locale}&theme={theme}&tid={tid}",
            fallback: TeamsAppLaunch.teamsEntityURL(appID: appID, entityID: "home"),
            resource: "api://sample.contoso.example/00000000-0000-0000-0000-00000000a99e",
            webAppID: "00000000-0000-0000-0000-00000000a99e",
            validDomains: ["sample.contoso.example"], transport: transport, demoHTML: html)
    }

    public static let apps: [FrameApp] = [
        FrameApp(id: appID, label: "Sample Tab App", symbol: "square.grid.2x2", source: .personal,
                 launch: .teamsApp(launch(.frameless))),
        FrameApp(id: iframeAppID, label: "Sample Tab App (Framed)", symbol: "square.grid.2x2", source: .personal,
                 launch: .teamsApp(launch(.iframe))),
    ]

    /// The sample page titled for one demo app.
    public static func html(title: String) -> String {
        let safe = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return html.replacingOccurrences(of: "Sample Tab App", with: safe)
    }

    /// A self-contained TeamsJS client (public sample content only): the
    /// frameless wire protocol inline, since no SDK can be fetched in demo.
    /// In the iframe transport it posts to its parent instead.
    public static let html = #"""
    <!doctype html><html><head><meta charset="utf-8"><title>Sample Tab App</title>
    <style>
    :root{color-scheme:light;--fg:#1d1d1f;--sub:#6e6e73;--bg:#fff;--card:#f5f5f7;--ok:#248a3d;--bad:#d70015}
    body.dark{color-scheme:dark;--fg:#f5f5f7;--sub:#98989d;--bg:#1e1e1e;--card:#2c2c2e;--ok:#30d158;--bad:#ff453a}
    body.contrast{color-scheme:dark;--fg:#fff;--sub:#fff;--bg:#000;--card:#000;--ok:#0f0;--bad:#f66}
    body{font:13px -apple-system,system-ui;margin:0;padding:24px 28px;background:var(--bg);color:var(--fg)}
    h1{font:600 22px -apple-system,system-ui;margin:0 0 4px}p.sub{color:var(--sub);margin:0 0 18px}
    .card{background:var(--card);border-radius:10px;padding:12px 14px;margin:0 0 10px;max-width:560px}
    .row{display:flex;justify-content:space-between;gap:16px;padding:3px 0}
    .k{color:var(--sub)}.v{font-variant-numeric:tabular-nums;text-align:right}
    .ok{color:var(--ok)}.bad{color:var(--bad)}
    </style></head><body>
    <h1>Sample Tab App</h1>
    <p class="sub">A TeamsJS app running in the native Teams host.</p>
    <div class="card" id="host"><div class="row"><span class="k">Host</span><span class="v">Connecting…</span></div></div>
    <div class="card" id="ctx"></div>
    <div class="card" id="auth"></div>
    <script>
    (function () {
      var framed = window.parent !== window, seq = 0, pending = {}, handlers = {}, naa = {};
      function onMessage(m) {
        if (!m) { return; }
        if (m.id !== undefined && pending[m.id]) { var cb = pending[m.id]; delete pending[m.id]; cb(m.args || []); return; }
        if (m.func && handlers[m.func]) { handlers[m.func].apply(null, m.args || []); return; }
        var a = m.args; if (a && a[1] && typeof a[1] === 'string') { naaReply(a[1]); }
      }
      if (framed) { window.addEventListener('message', function (e) { if (e.source === window.parent) { onMessage(e.data); } }); }
      else { window.onNativeMessage = function (e) { onMessage(e.data); }; }
      function send(func, args, cb) {
        var id = ++seq; if (cb) { pending[id] = cb; }
        var msg = {id: id, uuidAsString: 'sample-' + id, func: func, args: args || [], timestamp: Date.now(), apiVersionTag: 'sample'};
        if (framed) { window.parent.postMessage(msg, '*'); } else { window.nativeInterface.framelessPostMessage(JSON.stringify(msg)); }
      }
      function naaReply(s) { try { var r = JSON.parse(s); if (naa[r.requestId]) { naa[r.requestId](r); delete naa[r.requestId]; } } catch (e) {} }
      if (!framed && window.nestedAppAuthBridge) { window.nestedAppAuthBridge.addEventListener('message', naaReply); }
      function naaSend(req, cb) {
        naa[req.requestId] = cb; var s = JSON.stringify(req);
        if (framed) { send('nestedAppAuth.execute', [s]); } else { window.nestedAppAuthBridge.postMessage(s); }
      }
      function rows(el, list) {
        el.innerHTML = '';
        list.forEach(function (r) {
          var d = document.createElement('div'); d.className = 'row';
          var k = document.createElement('span'); k.className = 'k'; k.textContent = r[0];
          var v = document.createElement('span'); v.className = 'v' + (r[2] ? ' ' + r[2] : ''); v.textContent = r[1];
          d.appendChild(k); d.appendChild(v); el.appendChild(d);
        });
      }
      function theme(t) { document.body.className = t === 'dark' ? 'dark' : (t === 'contrast' ? 'contrast' : ''); }
      var auth = [['getAuthToken', 'Waiting…'], ['Nested app auth', 'Waiting…']];
      function showAuth() { rows(document.getElementById('auth'), auth); }
      showAuth();
      handlers.themeChange = function (t) { theme(t); ctxRows.theme = t; showCtx(); };
      var ctxRows = {};
      function showCtx() {
        var list = [['Theme', ctxRows.theme || ''], ['Locale', ctxRows.locale || ''],
          ['User', ctxRows.user || ''], ['Tenant', ctxRows.tid || ''], ['Tab', ctxRows.entity || '']];
        if (ctxRows.team) { list.push(['Team', ctxRows.team]); list.push(['Channel', ctxRows.channel || '']); }
        rows(document.getElementById('ctx'), list);
      }
      send('initialize', ['2.56.0'], function (a) {
        var rt = {}; try { rt = JSON.parse(a[3] || '{}'); } catch (e) {}
        var caps = Object.keys(rt.supports || {}).sort().join(', ');
        rows(document.getElementById('host'), [['Host', 'Connected', 'ok'], ['Client', a[1] + ' · ' + a[0]],
          ['Runtime', 'v' + rt.apiVersion], ['Capabilities', caps]]);
        send('registerHandler', ['themeChange']);
        send('getContext', [], function (c) {
          c = c[0] || {}; theme(c.theme);
          ctxRows = {theme: c.theme, locale: c.locale, user: c.userPrincipalName, tid: c.tid, entity: c.entityId,
                     team: c.teamName, channel: c.channelName};
          showCtx();
          send('authentication.getAuthToken', [[], [], true], function (r) {
            auth[0] = r[0] ? ['getAuthToken', 'Token received (' + String(r[1]).length + ' chars)', 'ok'] : ['getAuthToken', String(r[1]), 'bad'];
            showAuth();
          });
          naaSend({messageType: 'NestedAppAuthRequest', method: 'GetToken', requestId: 'sample-naa-1',
                   tokenParams: {clientId: '00000000-0000-0000-0000-00000000a99e', scope: 'User.Read'}}, function (r) {
            auth[1] = r.success ? ['Nested app auth', 'Token received for ' + (r.account && r.account.username), 'ok']
                                : ['Nested app auth', (r.error && r.error.description) || 'Failed', 'bad'];
            showAuth();
          });
          send('appInitialization.success', []);
        });
      });
    })();
    </script></body></html>
    """#
}
