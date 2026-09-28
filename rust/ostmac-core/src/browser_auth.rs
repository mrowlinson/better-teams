//! Browser-capture fallback login (om-pwauth lane).
//!
//! Auth-code + PKCE (RFC 7636 / RFC 8252 native-client) for tenants where
//! the device-code flow fails (MFA/SSO/conditional-access). Swift hosts a
//! WKWebView on `authorize_url`, intercepts the nativeclient redirect, and
//! hands the full callback URL to [`authcode_complete_json`], which
//! verifies `state` and exchanges the code for tokens — the same save +
//! derived-token path as the device flow, so refresh/silent re-auth and
//! sign-out behave identically afterwards.
//!
//! No network in `start` (pure URL build); `complete` hits the token
//! endpoint once, then reuses [`ost::auth::oauth::refresh`] best-effort
//! for Skype/Graph/IC3/Recorder. `cancel` is pure session drop.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use ost::auth::{AuthConfig, TokenStore};
use serde_json::json;
use sha2::{Digest, Sha256};

use crate::{err_json, now_secs};

const EXPIRES_IN: u64 = 600;
const VERIFIER_LEN: usize = 64;
const STATE_BYTES: usize = 16;

/// PKCE unreserved set (RFC 7636 §4.1): verifier draws from this only.
const VERIFIER_ALPHABET: &[u8] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";

struct BrowserSession {
    verifier: String,
    state: String,
    token_url: String,
    client_id: String,
    redirect_uri: String,
    created_at: u64,
    expires_in: u64,
    /// Account profile the exchanged tokens land in.
    profile: String,
}

fn browser_sessions() -> &'static Mutex<HashMap<String, BrowserSession>> {
    static S: OnceLock<Mutex<HashMap<String, BrowserSession>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(HashMap::new()))
}

fn lock_browser() -> std::sync::MutexGuard<'static, HashMap<String, BrowserSession>> {
    browser_sessions().lock().unwrap_or_else(|e| e.into_inner())
}

/// Drop pending browser sessions for one account profile only.
pub(crate) fn clear_browser_sessions_for(profile: &str) {
    lock_browser().retain(|_, s| s.profile != profile);
}

fn new_browser_session_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    format!("ba-{}-{:08x}", now_secs(), nanos)
}

fn rand_verifier() -> String {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    (0..VERIFIER_LEN)
        .map(|_| {
            let i = rng.gen_range(0..VERIFIER_ALPHABET.len());
            VERIFIER_ALPHABET[i] as char
        })
        .collect()
}

fn rand_state() -> String {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    (0..STATE_BYTES)
        .map(|_| format!("{:02x}", rng.gen::<u8>()))
        .collect()
}

/// S256 challenge: BASE64URL-NOPAD(SHA256(verifier)).
fn pkce_challenge(verifier: &str) -> String {
    let mut h = Sha256::new();
    h.update(verifier.as_bytes());
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(h.finalize())
}

/// Minimal percent-encoder (unreserved pass-through, rest %XX uppercase).
fn pct(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{:02X}", b));
        }
    }
    out
}

fn pct_decode(s: &str) -> String {
    let mut out = Vec::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (
                hex_val(bytes[i + 1]),
                hex_val(bytes[i + 2]),
            ) {
                out.push(h * 16 + l);
                i += 3;
                continue;
            }
        }
        if bytes[i] == b'+' {
            out.push(b' ');
        } else {
            out.push(bytes[i]);
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Pure authorize-URL build (v2.0 authorize + PKCE S256 + state).
fn build_authorize_url(
    tenant: &str,
    client_id: &str,
    scope: &str,
    redirect_uri: &str,
    challenge: &str,
    state: &str,
) -> String {
    format!(
        "https://login.microsoftonline.com/{}/oauth2/v2.0/authorize\
         ?client_id={}&response_type=code&redirect_uri={}&scope={}\
         &code_challenge={}&code_challenge_method=S256&state={}",
        pct(tenant),
        pct(client_id),
        pct(redirect_uri),
        pct(scope),
        pct(challenge),
        pct(state),
    )
}

fn token_url_for(tenant: &str) -> String {
    format!(
        "https://login.microsoftonline.com/{}/oauth2/v2.0/token",
        tenant
    )
}

#[derive(Debug, PartialEq)]
enum CallbackParse {
    Code { code: String, state: Option<String> },
    Denied { error: String, detail: String },
}

/// Parse the nativeclient callback: `...?code=..&state=..` or
/// `...?error=..&error_description=..`. Fragment (`#`) tolerated.
/// Returns `None` when no code/error param is present.
fn parse_callback(callback: &str) -> Option<CallbackParse> {
    let query = callback
        .find(['?', '#'])
        .map(|i| &callback[i + 1..])
        .unwrap_or(callback);
    let mut code: Option<String> = None;
    let mut state: Option<String> = None;
    let mut error: Option<String> = None;
    let mut error_desc = String::new();
    for pair in query.split('&') {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        match k {
            "code" => code = Some(pct_decode(v)),
            "state" => state = Some(pct_decode(v)),
            "error" => error = Some(pct_decode(v)),
            "error_description" => error_desc = pct_decode(v),
            _ => {}
        }
    }
    if let Some(code) = code {
        if code.is_empty() {
            return None;
        }
        return Some(CallbackParse::Code { code, state });
    }
    if let Some(error) = error {
        let detail = if error_desc.is_empty() {
            error.clone()
        } else {
            format!("{}: {}", error, error_desc)
        };
        return Some(CallbackParse::Denied { error, detail });
    }
    None
}

/// Start browser-capture login. No network. Returns
/// `{ok, session, authorize_url, redirect_uri, expires_in}`.
pub fn authcode_start_json() -> String {
    authcode_start_json_for(&ost::config::active_profile())
}

/// Start browser-capture login for one account profile: the
/// exchanged tokens land in that profile, never the active one.
pub fn authcode_start_json_for(profile: &str) -> String {
    let target = ost::config::normalize_profile(profile);
    let auth = AuthConfig::default();
    let verifier = rand_verifier();
    let state = rand_state();
    let challenge = pkce_challenge(&verifier);
    let authorize_url = build_authorize_url(
        auth.tenant,
        auth.client_id,
        auth.scope,
        auth.redirect_uri,
        &challenge,
        &state,
    );
    let id = new_browser_session_id();
    lock_browser().insert(
        id.clone(),
        BrowserSession {
            verifier,
            state,
            token_url: token_url_for(auth.tenant),
            client_id: auth.client_id.to_string(),
            redirect_uri: auth.redirect_uri.to_string(),
            created_at: now_secs(),
            expires_in: EXPIRES_IN,
            profile: target,
        },
    );
    json!({
        "ok": true,
        "session": id,
        "authorize_url": authorize_url,
        "redirect_uri": auth.redirect_uri,
        "expires_in": EXPIRES_IN,
    })
    .to_string()
}

/// Complete browser-capture login for `session` with the intercepted
/// callback URL (or raw query). Verifies `state`, exchanges the code
/// (PKCE), saves AAD + refresh tokens, derives Skype/Graph/IC3/Recorder
/// best-effort. Returns:
/// - `{ok:true, status:"complete", tokens:{...}}` — signed in
/// - `{ok:false, error:"authcode_denied"|"authcode_no_code"|"authcode_state"|...}`
/// Parse/state failures keep the session (user can retry in the webview);
/// only success drops it. Exchange network failures also keep it.
pub fn authcode_complete_json(session: &str, callback: &str) -> String {
    let (verifier, expect_state, token_url, client_id, redirect_uri, profile) = {
        let map = lock_browser();
        match map.get(session) {
            Some(s) => {
                if now_secs() > s.created_at + s.expires_in {
                    drop(map);
                    lock_browser().remove(session);
                    return err_json("authcode_expired", "browser login expired; start again");
                }
                (
                    s.verifier.clone(),
                    s.state.clone(),
                    s.token_url.clone(),
                    s.client_id.clone(),
                    s.redirect_uri.clone(),
                    s.profile.clone(),
                )
            }
            None => return err_json("no_session", "unknown or finished session"),
        }
    };

    let parsed = match parse_callback(callback.trim()) {
        Some(p) => p,
        None => return err_json("authcode_no_code", "callback carried no code"),
    };
    let code = match parsed {
        CallbackParse::Denied { detail, .. } => {
            return err_json("authcode_denied", detail);
        }
        CallbackParse::Code { code, state } => {
            match state {
                Some(st) if st == expect_state => code,
                _ => return err_json("authcode_state", "state mismatch; restart browser sign-in"),
            }
        }
    };

    let run = || -> Result<(String, String, Option<u64>), String> {
        let r = crate::rt()?;
        r.block_on(async {
            let http = crate::http();
            let resp = http
                .post(&token_url)
                .form(&[
                    ("grant_type", "authorization_code"),
                    ("code", &code),
                    ("redirect_uri", &redirect_uri),
                    ("client_id", &client_id),
                    ("code_verifier", &verifier),
                ])
                .send()
                .await
                .map_err(|e| format!("token request: {}", e))?;
            let status = resp.status();
            let body: serde_json::Value = resp
                .json()
                .await
                .map_err(|e| format!("token parse: {}", e))?;
            if !status.is_success() {
                let err = body
                    .get("error")
                    .and_then(|v| v.as_str())
                    .unwrap_or("exchange_failed");
                let desc = body
                    .get("error_description")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                return Err(format!("{} http {}: {} {}", "token", status, err, desc));
            }
            let access = body
                .get("access_token")
                .and_then(|v| v.as_str())
                .ok_or_else(|| format!("token missing access_token: {}", body))?;
            let refresh = body
                .get("refresh_token")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let expires_in = body.get("expires_in").and_then(|v| v.as_u64());
            Ok((access.to_string(), refresh, expires_in))
        })
    };

    let (access, refresh, expires_in) = match run() {
        Ok(t) => t,
        Err(e) => return err_json("authcode_exchange", e),
    };

    let save = (|| -> Result<serde_json::Value, String> {
        let r = crate::rt()?;
        r.block_on(async {
            let mut cfg = ost::config::Config::load_cached_for(&profile)
                .map_err(|e| e.to_string())?;
            cfg.set_access_token(access, expires_in);
            if !refresh.is_empty() {
                cfg.set_refresh_token(refresh);
            }
            cfg.save_to(&profile).map_err(|e| e.to_string())?;
            let _ = ost::auth::oauth::refresh_for(&profile).await;
            Ok::<(), String>(())
        })?;
        ost::config::Config::load_cached_for(&profile)
            .map(|c| crate::token_summary(&c))
            .map_err(|e| e.to_string())
    })();
    match save {
        Ok(tokens) => {
            lock_browser().remove(session);
            crate::whoami_cache_clear_for_pub(&profile);
            json!({"ok": true, "status": "complete", "tokens": tokens}).to_string()
        }
        Err(e) => err_json("token_save", e),
    }
}

/// Drop one pending browser session. `{ok:true, cancelled:bool}`.
pub fn authcode_cancel_json(session: &str) -> String {
    let dropped = lock_browser().remove(session).is_some();
    json!({"ok": true, "cancelled": dropped}).to_string()
}

// ---------------------------------------------------------------------------
// Tests (deterministic: no network)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_challenge_matches_rfc7636_vector() {
        // RFC 7636 Appendix B.
        let v = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        assert_eq!(pkce_challenge(v), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    }

    #[test]
    fn verifier_charset_and_length() {
        for _ in 0..8 {
            let v = rand_verifier();
            assert_eq!(v.len(), VERIFIER_LEN);
            assert!(v.bytes().all(|b| VERIFIER_ALPHABET.contains(&b)));
            // Challenge is unpadded base64url (43 chars for SHA-256).
            let c = pkce_challenge(&v);
            assert_eq!(c.len(), 43);
            assert!(c.bytes().all(|b| b.is_ascii_alphanumeric()
                || b == b'-'
                || b == b'_'));
        }
    }

    #[test]
    fn states_are_unique_hex() {
        let a = rand_state();
        let b = rand_state();
        assert_eq!(a.len(), 32);
        assert!(a.bytes().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(a, b);
    }

    #[test]
    fn start_envelope_shape_offline() {
        let v: serde_json::Value =
            serde_json::from_str(&authcode_start_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert!(v["session"].as_str().unwrap().starts_with("ba-"));
        let url = v["authorize_url"].as_str().unwrap();
        assert!(url.starts_with(
            "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?"
        ));
        for needle in [
            "client_id=1fec8e78-bce4-4aaf-ab1b-5451cc387264",
            "response_type=code",
            "code_challenge_method=S256",
            "code_challenge=",
            "state=",
            "redirect_uri=https%3A%2F%2Flogin.microsoftonline.com%2Fcommon%2Foauth2%2Fnativeclient",
            "scope=https%3A%2F%2Fapi.spaces.skype.com%2F.default%20offline_access",
        ] {
            assert!(url.contains(needle), "missing {}", needle);
        }
        assert_eq!(
            v["redirect_uri"],
            "https://login.microsoftonline.com/common/oauth2/nativeclient"
        );
        assert_eq!(v["expires_in"], 600);
        // Cleanup: don't leak sessions across tests.
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&authcode_cancel_json(
                v["session"].as_str().unwrap()
            ))
            .unwrap()["cancelled"],
            true
        );
    }

    #[test]
    fn parse_callback_query_and_fragment() {
        assert_eq!(
            parse_callback("https://h/nativeclient?code=ABC&state=ST"),
            Some(CallbackParse::Code {
                code: "ABC".into(),
                state: Some("ST".into())
            })
        );
        // Fragment form tolerated.
        assert_eq!(
            parse_callback("https://h/nativeclient#code=X%20Y&state=S"),
            Some(CallbackParse::Code {
                code: "X Y".into(),
                state: Some("S".into())
            })
        );
        // Raw query only.
        assert_eq!(
            parse_callback("code=Z&state=W"),
            Some(CallbackParse::Code {
                code: "Z".into(),
                state: Some("W".into())
            })
        );
        // Denied with description.
        assert_eq!(
            parse_callback("https://h/n?error=access_denied&error_description=Nope%20guy"),
            Some(CallbackParse::Denied {
                error: "access_denied".into(),
                detail: "access_denied: Nope guy".into()
            })
        );
        // Denied without description keeps the bare code.
        assert_eq!(
            parse_callback("https://h/n?error=login_required"),
            Some(CallbackParse::Denied {
                error: "login_required".into(),
                detail: "login_required".into()
            })
        );
        // Code wins over a stray error param.
        assert!(matches!(
            parse_callback("https://h/n?error=x&code=C&state=S"),
            Some(CallbackParse::Code { .. })
        ));
        // Empty code / nothing useful => None.
        assert_eq!(parse_callback("https://h/n?code=&state=S"), None);
        assert_eq!(parse_callback("https://h/nothing-here"), None);
        assert_eq!(parse_callback(""), None);
    }

    #[test]
    fn complete_unknown_session_is_error() {
        let v: serde_json::Value =
            serde_json::from_str(&authcode_complete_json("ba-nope", "code=C&state=S"))
                .unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "no_session");
    }

    #[test]
    fn complete_denied_and_no_code_keep_session() {
        let start: serde_json::Value =
            serde_json::from_str(&authcode_start_json()).unwrap();
        let sess = start["session"].as_str().unwrap();
        let denied: serde_json::Value = serde_json::from_str(&authcode_complete_json(
            sess,
            "https://h/n?error=access_denied&error_description=No",
        ))
        .unwrap();
        assert_eq!(denied["ok"], false);
        assert_eq!(denied["error"], "authcode_denied");
        let nocode: serde_json::Value =
            serde_json::from_str(&authcode_complete_json(sess, "https://h/nothing")).unwrap();
        assert_eq!(nocode["error"], "authcode_no_code");
        // Session survived both: cancel still finds it.
        let cancel: serde_json::Value =
            serde_json::from_str(&authcode_cancel_json(sess)).unwrap();
        assert_eq!(cancel["cancelled"], true);
    }

    #[test]
    fn complete_state_mismatch_is_error() {
        let start: serde_json::Value =
            serde_json::from_str(&authcode_start_json()).unwrap();
        let sess = start["session"].as_str().unwrap();
        let v: serde_json::Value = serde_json::from_str(&authcode_complete_json(
            sess,
            "https://h/n?code=REALCODE&state=wrong-state",
        ))
        .unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "authcode_state");
        // Missing state is the same failure.
        let v2: serde_json::Value = serde_json::from_str(&authcode_complete_json(
            sess,
            "https://h/n?code=REALCODE",
        ))
        .unwrap();
        assert_eq!(v2["error"], "authcode_state");
        let _ = authcode_cancel_json(sess);
    }

    #[test]
    fn cancel_unknown_session_reports_false() {
        let v: serde_json::Value =
            serde_json::from_str(&authcode_cancel_json("ba-nope")).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["cancelled"], false);
    }

    #[test]
    fn pct_roundtrip() {
        let s = "https://h/a b?x=1&y=2";
        assert_eq!(pct_decode(&pct(s)), s);
        assert_eq!(pct("abc-_.~09AZaz"), "abc-_.~09AZaz");
    }
}
