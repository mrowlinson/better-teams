//! Native Teams app hosting (APPHOST phase 1): the app catalog
//! (installed/pinned apps + manifests from the apps-platform middle
//! tier) and the token broker a TeamsJS host needs (`getAuthToken` for
//! any resource, nested-app-auth tokens for an app's own client id).
//!
//! Every call is read-only against Microsoft services. Tokens cross the
//! FFI only inside the returned JSON (for the requesting app frame) and
//! are never logged.

use std::os::raw::c_char;

use serde_json::json;

use crate::{err_json, opt_cstr_to_string, rt, string_to_c};

/// Null/blank profile = the active profile.
fn profile_or_active(p: Option<String>) -> String {
    match p {
        Some(s) if !s.trim().is_empty() => s,
        _ => ost::config::active_profile(),
    }
}

fn manifest_json(m: &ost::api::AppManifest) -> serde_json::Value {
    serde_json::to_value(m).unwrap_or(serde_json::Value::Null)
}

/// Installed apps, pinned (app bar) order and manifests:
/// `{ok, pinned:[id], entitlements:[{app_id,state,pinned}], apps:[manifest]}`.
pub fn app_catalog_json(profile: &str) -> String {
    let run = || -> Result<String, String> {
        rt()?.block_on(async {
            let client = ost::api::client::TeamsClient::new_for_profile(profile)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let c = ost::api::app_catalog_data(&client).await.map_err(|e| format!("{:#}", e))?;
            Ok(json!({
                "ok": true,
                "pinned": c.pinned,
                "entitlements": c.entitlements,
                "apps": c.apps.iter().map(manifest_json).collect::<Vec<_>>(),
            })
            .to_string())
        })
    };
    run().unwrap_or_else(|e| err_json("app_catalog", e))
}

/// Store home: `{ok, sections:[{title, app_ids}], apps:[manifest]}` (read-only).
pub fn app_store_json(profile: &str) -> String {
    let run = || -> Result<String, String> {
        rt()?.block_on(async {
            let client = ost::api::client::TeamsClient::new_for_profile(profile)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let s = ost::api::app_store_data(&client).await.map_err(|e| format!("{:#}", e))?;
            Ok(json!({
                "ok": true,
                "sections": s.sections,
                "apps": s.apps.iter().map(manifest_json).collect::<Vec<_>>(),
            })
            .to_string())
        })
    };
    run().unwrap_or_else(|e| err_json("app_store", e))
}

/// Store search: `{ok, apps:[manifest]}` (read-only). Blank query is
/// rejected before any network.
pub fn app_search_json(profile: &str, query: &str) -> String {
    if query.trim().is_empty() {
        return err_json("arg", "empty query");
    }
    let run = || -> Result<String, String> {
        rt()?.block_on(async {
            let client = ost::api::client::TeamsClient::new_for_profile(profile)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let apps = ost::api::app_search_data(&client, query).await.map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "apps": apps.iter().map(manifest_json).collect::<Vec<_>>()}).to_string())
        })
    };
    run().unwrap_or_else(|e| err_json("app_search", e))
}

/// Installs an app for the user (REMOTE WRITE; the UI confirms first):
/// `{ok}`. Blank id is rejected before any network.
pub fn app_install_json(profile: &str, app_id: &str) -> String {
    if app_id.trim().is_empty() {
        return err_json("arg", "empty app id");
    }
    let run = || -> Result<String, String> {
        rt()?.block_on(async {
            let client = ost::api::client::TeamsClient::new_for_profile(profile)
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::install_app_for_user(&client, app_id).await.map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true}).to_string())
        })
    };
    run().unwrap_or_else(|e| err_json("app_install", e))
}

/// Manifests for a team's installed apps plus `ids_json` (a JSON array
/// of catalog ids): `{ok, apps:[manifest]}` (read-only).
pub fn team_app_definitions_json(profile: &str, team_id: &str, ids_json: &str) -> String {
    let extra: Vec<String> = match serde_json::from_str(ids_json) {
        Ok(v) => v,
        Err(e) => return err_json("arg", format!("ids: {}", e)),
    };
    let run = || -> Result<String, String> {
        rt()?.block_on(async {
            let client = ost::api::client::TeamsClient::new_for_profile(profile)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let team = Some(team_id).filter(|t| !t.trim().is_empty());
            let apps = ost::api::team_app_definitions_data(&client, team, &extra)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "apps": apps.iter().map(manifest_json).collect::<Vec<_>>()}).to_string())
        })
    };
    run().unwrap_or_else(|e| err_json("team_apps", e))
}

/// SharePoint site URLs for tab placeholders:
/// `{ok, root?, my_site?, team_site?}` (read-only).
pub fn app_sites_json(profile: &str, group_id: &str) -> String {
    let run = || -> Result<String, String> {
        rt()?.block_on(async {
            let client = ost::api::client::TeamsClient::new_for_profile(profile)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let group = Some(group_id).filter(|g| !g.trim().is_empty());
            let s = ost::api::sharepoint_sites_data(&client, group).await.map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "root": s.root, "my_site": s.my_site, "team_site": s.team_site}).to_string())
        })
    };
    run().unwrap_or_else(|e| err_json("app_sites", e))
}

fn grant_json(g: ost::auth::oauth::TokenGrant) -> String {
    json!({"ok": true, "token": g.access_token, "expires_in": g.expires_in, "scope": g.scope, "id_token": g.id_token})
        .to_string()
}

/// `{ok, token, expires_in, scope}` for a resource or scope list.
pub fn token_for_scope_json(profile: &str, scopes: &str) -> String {
    if scopes.trim().is_empty() {
        return err_json("arg", "empty scope");
    }
    let run = || -> Result<String, String> {
        rt()?.block_on(async {
            ost::auth::oauth::token_for_scope_for(profile, scopes)
                .await
                .map(grant_json)
                .map_err(|e| format!("{:#}", e))
        })
    };
    run().unwrap_or_else(|e| err_json("token", e))
}

/// Nested app auth token for `client_id` + `scopes`, requested by a
/// page at `origin`. Same envelope as [`token_for_scope_json`].
pub fn naa_token_json(profile: &str, client_id: &str, scopes: &str, origin: &str) -> String {
    if client_id.trim().is_empty() || scopes.trim().is_empty() || origin.trim().is_empty() {
        return err_json("arg", "client_id, scopes and origin are required");
    }
    let run = || -> Result<String, String> {
        rt()?.block_on(async {
            ost::auth::oauth::naa_token_for(profile, client_id, scopes, origin)
                .await
                .map(grant_json)
                .map_err(|e| format!("{:#}", e))
        })
    };
    run().unwrap_or_else(|e| err_json("naa_token", e))
}

/// Identity claims (`tid`, `oid`, `upn`/`preferred_username`, `name`)
/// from a JWT payload. Claims only; the token itself is not kept.
pub fn identity_from_jwt(token: &str) -> Option<serde_json::Value> {
    use base64::Engine;
    let payload = token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .ok()?;
    let c: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    let s = |k: &str| c.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
    let upn = [s("upn"), s("preferred_username"), s("unique_name")]
        .into_iter()
        .find(|v| !v.is_empty())
        .unwrap_or_default();
    Some(json!({"tenant_id": s("tid"), "user_object_id": s("oid"), "upn": upn, "name": s("name")}))
}

/// Host identity for TeamsJS `getContext` from the stored Teams AAD
/// token (no network): `{ok, tenant_id, user_object_id, upn, name}`.
pub fn app_identity_json(profile: &str) -> String {
    use ost::auth::TokenStore;
    let cfg = match ost::config::Config::load_cached_for(profile) {
        Ok(c) => c,
        Err(e) => return err_json("identity", format!("{:#}", e)),
    };
    match cfg.get_access_token().and_then(|t| identity_from_jwt(&t.token)) {
        Some(mut v) => {
            v["ok"] = json!(true);
            v.to_string()
        }
        None => err_json("identity", "not signed in"),
    }
}

/// Host identity claims. See [`app_identity_json`].
#[no_mangle]
pub extern "C" fn ostmac_app_identity_for(profile: *const c_char) -> *mut c_char {
    match opt_cstr_to_string(profile) {
        Ok(p) => string_to_c(app_identity_json(&profile_or_active(p))),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

fn arg(p: *const c_char) -> Result<String, String> {
    opt_cstr_to_string(p).map(|o| o.unwrap_or_default())
}

/// App catalog for a profile (null = active). See [`app_catalog_json`].
#[no_mangle]
pub extern "C" fn ostmac_app_catalog_for(profile: *const c_char) -> *mut c_char {
    match opt_cstr_to_string(profile) {
        Ok(p) => string_to_c(app_catalog_json(&profile_or_active(p))),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Team app manifests (read-only). See [`team_app_definitions_json`].
#[no_mangle]
pub extern "C" fn ostmac_team_app_definitions_for(
    profile: *const c_char,
    team_id: *const c_char,
    ids_json: *const c_char,
) -> *mut c_char {
    match (opt_cstr_to_string(profile), opt_cstr_to_string(team_id), arg(ids_json)) {
        (Ok(p), Ok(t), Ok(ids)) => {
            string_to_c(team_app_definitions_json(&profile_or_active(p), &t.unwrap_or_default(), &ids))
        }
        (Err(e), _, _) | (_, Err(e), _) | (_, _, Err(e)) => string_to_c(err_json("arg", e)),
    }
}

/// SharePoint site URLs (read-only). See [`app_sites_json`].
#[no_mangle]
pub extern "C" fn ostmac_app_sites_for(profile: *const c_char, group_id: *const c_char) -> *mut c_char {
    match (opt_cstr_to_string(profile), opt_cstr_to_string(group_id)) {
        (Ok(p), Ok(g)) => string_to_c(app_sites_json(&profile_or_active(p), &g.unwrap_or_default())),
        (Err(e), _) | (_, Err(e)) => string_to_c(err_json("arg", e)),
    }
}

/// Store home for a profile (null = active). See [`app_store_json`].
#[no_mangle]
pub extern "C" fn ostmac_app_store_for(profile: *const c_char) -> *mut c_char {
    match opt_cstr_to_string(profile) {
        Ok(p) => string_to_c(app_store_json(&profile_or_active(p))),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Store search. See [`app_search_json`].
#[no_mangle]
pub extern "C" fn ostmac_app_search_for(profile: *const c_char, query: *const c_char) -> *mut c_char {
    match (opt_cstr_to_string(profile), arg(query)) {
        (Ok(p), Ok(q)) => string_to_c(app_search_json(&profile_or_active(p), &q)),
        (Err(e), _) | (_, Err(e)) => string_to_c(err_json("arg", e)),
    }
}

/// Personal install (REMOTE WRITE). See [`app_install_json`].
#[no_mangle]
pub extern "C" fn ostmac_app_install_for(profile: *const c_char, app_id: *const c_char) -> *mut c_char {
    match (opt_cstr_to_string(profile), arg(app_id)) {
        (Ok(p), Ok(a)) => string_to_c(app_install_json(&profile_or_active(p), &a)),
        (Err(e), _) | (_, Err(e)) => string_to_c(err_json("arg", e)),
    }
}

/// Access token for any resource/scope. See [`token_for_scope_json`].
#[no_mangle]
pub extern "C" fn ostmac_token_for_scope_for(profile: *const c_char, scopes: *const c_char) -> *mut c_char {
    match (opt_cstr_to_string(profile), arg(scopes)) {
        (Ok(p), Ok(s)) => string_to_c(token_for_scope_json(&profile_or_active(p), &s)),
        (Err(e), _) | (_, Err(e)) => string_to_c(err_json("arg", e)),
    }
}

/// Nested app auth token. See [`naa_token_json`].
#[no_mangle]
pub extern "C" fn ostmac_naa_token_for(
    profile: *const c_char,
    client_id: *const c_char,
    scopes: *const c_char,
    origin: *const c_char,
) -> *mut c_char {
    match (opt_cstr_to_string(profile), arg(client_id), arg(scopes), arg(origin)) {
        (Ok(p), Ok(c), Ok(s), Ok(o)) => string_to_c(naa_token_json(&profile_or_active(p), &c, &s, &o)),
        (Err(e), ..) | (_, Err(e), ..) | (_, _, Err(e), _) | (.., Err(e)) => string_to_c(err_json("arg", e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn store_args_rejected_before_network() {
        assert!(app_search_json("nobody", "  ").contains("empty query"));
        assert!(app_install_json("nobody", "").contains("empty app id"));
    }

    #[test]
    fn broker_args_rejected_before_network() {
        let v: serde_json::Value = serde_json::from_str(&token_for_scope_json("p", " ")).unwrap();
        assert_eq!(v["error"], "arg");
        let v: serde_json::Value = serde_json::from_str(&naa_token_json("p", "c", "User.Read", "")).unwrap();
        assert_eq!(v["error"], "arg");
    }

    #[test]
    fn identity_claims_from_jwt_payload() {
        use base64::Engine;
        let body = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(r#"{"tid":"t-1","oid":"o-2","preferred_username":"ada@example.com","name":"Ada"}"#);
        let v = identity_from_jwt(&format!("h.{}.sig", body)).expect("claims");
        assert_eq!(v["tenant_id"], "t-1");
        assert_eq!(v["user_object_id"], "o-2");
        assert_eq!(v["upn"], "ada@example.com");
        assert!(identity_from_jwt("nope").is_none());
    }

    #[test]
    fn manifest_serializes_snake_case_fields() {
        let m = ost::api::apps::parse_definitions(&json!([{
            "id": "x",
            "staticTabs": [{"entityId": "home", "contentUrl": "https://x.example.com/t"}],
            "webApplicationInfo": {"id": "w", "resource": "api://x.example.com/app"},
            "validDomains": ["x.example.com"]
        }]));
        let v = manifest_json(&m[0]);
        assert_eq!(v["static_tabs"][0]["entity_id"], "home");
        assert_eq!(v["web_application_info"]["resource"], "api://x.example.com/app");
        assert_eq!(v["valid_domains"][0], "x.example.com");
    }
}
