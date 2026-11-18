//! File + people search (Graph drive search + `/users` `$search`).
//!
//! OstMac (om-jb-filesearch): free-text search over the signed-in user's
//! OneDrive files and the directory. No auth scope change: the existing
//! Graph token (`/.default`) carries delegated Files + User scopes; a 403
//! surfaces as the call's detail. Shapes per
//! `learn.microsoft.com/graph/api/driveitem-search` and
//! `learn.microsoft.com/graph/search-query-parameter`.
//!
//! Both searches are single-window (`$top`, capped at 25): no paging
//! cursors, so the Swift store is search/retry/clear with no loadMore.
//! Rows reuse [`SharedFile`] and [`TeamMemberInfo`] — the palette renders
//! the same shapes as the Shared tab and the roster.

use anyhow::{bail, Context, Result};
use serde::Deserialize;

use super::client::TeamsClient;
use super::files::SharedFile;
use super::teams::TeamMemberInfo;

/// Per-request result cap for both searches.
pub const FIND_MAX_LIMIT: usize = 25;

/// Clamp a result limit into Graph's `1..=25` window.
pub fn clamp_limit(limit: usize) -> usize {
    limit.clamp(1, FIND_MAX_LIMIT)
}

/// Minimal query encoder: keeps unreserved chars, percent-encodes the
/// rest (spaces -> %20, etc). Graph single-quote escaping (`''`) is
/// applied by the drive path builder before this runs.
fn encode_query(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

// ---------------------------------------------------------------------------
// File search: GET /me/drive/root/search(q='{q}')?$top=N
// ---------------------------------------------------------------------------

/// Graph path for one OneDrive filename/content search window.
/// Single quotes in the query double up (Graph escaping) before URL
/// encoding. Pure so tests pin it.
pub fn drive_search_path(query: &str, limit: usize) -> String {
    let escaped = query.trim().replace('\'', "''");
    format!(
        "/me/drive/root/search(q='{}')?$top={}",
        encode_query(&escaped),
        clamp_limit(limit)
    )
}

#[derive(Debug, Deserialize, Default)]
struct DriveSearchResponse {
    #[serde(default)]
    value: Vec<DriveSearchItem>,
}

#[derive(Debug, Deserialize, Default)]
struct DriveSearchItem {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    size: Option<u64>,
    #[serde(rename = "webUrl", default)]
    web_url: Option<String>,
    #[serde(rename = "@microsoft.graph.downloadUrl", default)]
    download_url: Option<String>,
    #[serde(rename = "createdDateTime", default)]
    created: Option<String>,
    #[serde(rename = "lastModifiedDateTime", default)]
    modified: Option<String>,
    #[serde(default)]
    file: Option<SearchFileFacet>,
    #[serde(default)]
    folder: Option<serde_json::Value>,
    #[serde(rename = "parentReference", default)]
    parent: Option<SearchParentRef>,
}

#[derive(Debug, Deserialize, Default)]
struct SearchFileFacet {
    #[serde(rename = "mimeType", default)]
    mime_type: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
struct SearchParentRef {
    #[serde(rename = "driveId", default)]
    drive_id: Option<String>,
}

fn shared_from_hit(item: DriveSearchItem) -> Option<SharedFile> {
    let id = item.id.filter(|s| !s.trim().is_empty())?;
    Some(SharedFile {
        id,
        name: item.name.unwrap_or_else(|| "[unnamed]".to_string()),
        size: item.size.unwrap_or(0),
        mime: item.file.and_then(|f| f.mime_type),
        web_url: item.web_url,
        download_url: item.download_url,
        drive_id: item.parent.and_then(|p| p.drive_id),
        created: item.created,
        modified: item.modified,
        sender: None,
        is_folder: item.folder.is_some(),
        // Search hits skip the eTag GUID: the Shared-tab bubble-match
        // key needs the list-path eTag, which search does not project.
        attachment_id: None,
        share_url: None,
    })
}

/// Parse one drive-search response into shared files. Unknown shapes
/// yield no files (never fatal); items without an id are skipped.
pub fn parse_drive_search_response(value: &serde_json::Value) -> Vec<SharedFile> {
    let resp: DriveSearchResponse =
        serde_json::from_value(value.clone()).unwrap_or_default();
    resp.value.into_iter().filter_map(shared_from_hit).collect()
}

/// Search the signed-in user's OneDrive, one `$top` window. Empty
/// queries are rejected before any network.
pub async fn search_files_data(
    client: &TeamsClient,
    query: &str,
    limit: usize,
) -> Result<Vec<SharedFile>> {
    if query.trim().is_empty() {
        bail!("empty query");
    }
    let resp = client.graph_get(&drive_search_path(query, limit)).await?;
    let value: serde_json::Value = resp
        .json()
        .await
        .context("Failed to parse drive search response")?;
    Ok(parse_drive_search_response(&value))
}

/// Search OneDrive files (prints one window to stdout).
pub async fn search_files(query: &str, limit: usize) -> Result<()> {
    let client = TeamsClient::new().await?;
    let files = search_files_data(&client, query, limit).await?;

    println!("\nFile results for {:?}:", query);
    println!("{:-<60}", "");
    if files.is_empty() {
        println!("  (no files found)");
        return Ok(());
    }
    for f in &files {
        println!("{}{}", f.name, if f.is_folder { "/" } else { "" });
        if let Some(url) = f.web_url.as_deref() {
            println!("  {}", url);
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// People search: GET /users?$search="displayName:{q}" (+ ConsistencyLevel)
// ---------------------------------------------------------------------------

/// Graph `$select` for directory people rows (externchat adds
/// `userType` so guests badge + federated create works).
const PEOPLE_SELECT: &str = "id,displayName,mail,userPrincipalName,userType";

/// Graph path for one directory search window. Double quotes in the
/// query are dropped (they would break the `$search` phrase); the rest
/// is URL-encoded. Pure so tests pin it.
pub fn people_search_path(query: &str, limit: usize) -> String {
    let phrase: String = query.trim().replace('"', "");
    format!(
        "/users?$search=\"displayName:{}\"&$select={}&$top={}",
        encode_query(&phrase),
        PEOPLE_SELECT,
        clamp_limit(limit)
    )
}

/// Graph path for an exact-email lookup (externchat: guests whose
/// display name doesn't match still resolve by mail). Single quotes in
/// the mail are doubled per the Graph `$filter` string rule, then the
/// whole literal is URL-encoded. Pure so tests pin it.
pub fn people_mail_path(email: &str) -> String {
    let lit = email.trim().replace('\'', "''");
    format!(
        "/users?$filter=mail eq '{}'&$select={}&$top=25",
        encode_query(&lit),
        PEOPLE_SELECT
    )
}

/// True when the query looks like a complete email address (has `@`
/// plus a dot after it, no spaces): the only shape worth an exact
/// mail / federated lookup. Pure so tests pin it.
pub fn looks_like_email(query: &str) -> bool {
    let q = query.trim();
    if q.contains(' ') || !q.contains('@') {
        return false;
    }
    match q.rfind('@') {
        Some(i) => q[i + 1..].contains('.'),
        None => false,
    }
}

#[derive(Debug, Deserialize, Default)]
struct PeopleSearchResponse {
    #[serde(default)]
    value: Vec<PeopleSearchUser>,
}

#[derive(Debug, Deserialize, Default)]
struct PeopleSearchUser {
    #[serde(default)]
    id: Option<String>,
    #[serde(rename = "displayName", default)]
    display_name: Option<String>,
    #[serde(default)]
    mail: Option<String>,
    #[serde(rename = "userPrincipalName", default)]
    upn: Option<String>,
    #[serde(rename = "userType", default)]
    user_type: Option<String>,
}

fn member_from_user(u: PeopleSearchUser) -> Option<TeamMemberInfo> {
    let id = u.id.filter(|s| !s.trim().is_empty())?;
    let email = u.mail.filter(|s| !s.trim().is_empty()).or(u.upn);
    let user_type = u
        .user_type
        .filter(|s| !s.trim().is_empty());
    Some(TeamMemberInfo {
        display_name: u.display_name.unwrap_or_else(|| id.clone()),
        user_id: Some(id.clone()),
        id,
        email,
        roles: Vec::new(),
        is_owner: false,
        user_type,
    })
}

/// Parse one `/users` `$search` response into member rows (roles empty:
/// directory hits carry no team role). Unknown shapes yield no rows
/// (never fatal); users without an id are skipped.
pub fn parse_people_search_response(value: &serde_json::Value) -> Vec<TeamMemberInfo> {
    let resp: PeopleSearchResponse =
        serde_json::from_value(value.clone()).unwrap_or_default();
    resp.value.into_iter().filter_map(member_from_user).collect()
}

/// Search the directory, one `$top` window. Empty queries are rejected
/// before any network. `$search` requires `ConsistencyLevel: eventual`
/// (see `graph_get_consistent`); without it Graph 400s.
///
/// Externchat: when the query looks like a complete email, an exact
/// mail lookup (catches guests by address) and the Teams federated
/// lookup (`externalsearchv3`, catches non-directory externals) run
/// best-effort after the directory window and merge behind it; either
/// may 404/403 (unknown address, federation blocked) without failing
/// the directory hits.
pub async fn search_people_data(
    client: &TeamsClient,
    query: &str,
    limit: usize,
) -> Result<Vec<TeamMemberInfo>> {
    if query.trim().is_empty() {
        bail!("empty query");
    }
    let resp = client
        .graph_get_consistent(&people_search_path(query, limit))
        .await?;
    let value: serde_json::Value = resp
        .json()
        .await
        .context("Failed to parse people search response")?;
    let mut out = parse_people_search_response(&value);
    if looks_like_email(query) {
        if let Ok(resp) = client.graph_get(&people_mail_path(query)).await {
            if let Ok(value) = resp.json::<serde_json::Value>().await {
                merge_people(&mut out, parse_people_search_response(&value));
            }
        }
        if let Ok(Some(ext)) = search_external_data(client, query.trim()).await {
            merge_people(&mut out, vec![ext]);
        }
    }
    Ok(out)
}

/// Append `extra` rows missing from `base`. Identity is the user ref
/// first (AAD id else email, the `PersonChat.userRef` rule restated),
/// falling back to the row id; federated MRIs (`8:...`) never collide
/// with directory ids. Pure so tests pin it.
pub fn merge_people(base: &mut Vec<TeamMemberInfo>, extra: Vec<TeamMemberInfo>) {
    fn key(m: &TeamMemberInfo) -> String {
        if let Some(u) = m.user_id.as_deref().filter(|s| !s.trim().is_empty()) {
            return u.to_ascii_lowercase();
        }
        if let Some(e) = m.email.as_deref().filter(|s| !s.trim().is_empty()) {
            return e.to_ascii_lowercase();
        }
        m.id.clone()
    }
    let mut seen: std::collections::HashSet<String> = base.iter().map(key).collect();
    for m in extra {
        if seen.insert(key(&m)) {
            base.push(m);
        }
    }
}

// ---------------------------------------------------------------------------
// Federated (external) lookup: GET {mt}/beta/users/{email}/
// externalsearchv3?includeTFLUsers=true — the same endpoint the Teams
// web client calls when a new-chat query leaves the directory. Bearer
// is the Teams AAD token with X-Skypetoken (see `mt_request`); the
// response carries the peer's chat MRI (`8:orgid:` work, `8:live:`
// personal, `8:sfb:` on-prem), display name and `type`
// (Federated/SkypeConsumer/…, TFL personal included via the flag).
// Unknown addresses 404 (never fatal); anything else propagates.
// ---------------------------------------------------------------------------

/// Middle-tier path for one federated lookup. The email is a path
/// segment, so the whole address is URL-encoded. Pure so tests pin it.
pub fn external_search_path(mt_base: &str, email: &str) -> String {
    format!(
        "{}/beta/users/{}/externalsearchv3?includeTFLUsers=true",
        mt_base.trim_end_matches('/'),
        encode_query(email.trim())
    )
}

#[derive(Debug, Deserialize, Default)]
struct ExternalSearchUser {
    #[serde(rename = "displayName", default)]
    display_name: Option<String>,
    #[serde(default)]
    email: Option<String>,
    #[serde(rename = "type", default)]
    kind: Option<String>,
    #[serde(default)]
    mri: Option<String>,
    #[serde(rename = "objectId", default)]
    object_id: Option<String>,
}

fn member_from_external(u: ExternalSearchUser) -> Option<TeamMemberInfo> {
    let mri = u.mri.filter(|s| !s.trim().is_empty())?;
    let email = u.email.filter(|s| !s.trim().is_empty());
    let display_name = u
        .display_name
        .filter(|s| !s.trim().is_empty())
        .or_else(|| email.clone())
        .unwrap_or_else(|| mri.clone());
    let id = u
        .object_id
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| mri.clone());
    Some(TeamMemberInfo {
        display_name,
        user_id: Some(mri),
        id,
        email,
        roles: Vec::new(),
        is_owner: false,
        user_type: u.kind.filter(|s| !s.trim().is_empty()),
    })
}

/// Parse one `externalsearchv3` response into a member row, or `None`
/// when it carries no chat MRI (blocked/unknown address). The row's
/// `user_id` is the full federated MRI (`8:...`): `PersonChat.userRef`
/// passes it through and the 1:1 create uses it verbatim. Unknown
/// shapes yield `None` (never fatal).
pub fn parse_external_search_response(value: &serde_json::Value) -> Option<TeamMemberInfo> {
    let u: ExternalSearchUser =
        serde_json::from_value(value.clone()).unwrap_or_default();
    member_from_external(u)
}

/// Federated lookup for one email address. A 404 (unknown address,
/// federation blocked) yields `Ok(None)`; transport/auth errors
/// propagate so callers can tell outage from absence.
pub async fn search_external_data(
    client: &TeamsClient,
    email: &str,
) -> Result<Option<TeamMemberInfo>> {
    let url = external_search_path(&client.middle_tier_url(), email);
    let resp = match client.mt_get(&url).await {
        Ok(r) => r,
        Err(e) if format!("{:#}", e).contains("HTTP 404") => return Ok(None),
        Err(e) => return Err(e),
    };
    let value: serde_json::Value = resp
        .json()
        .await
        .context("Failed to parse external search response")?;
    Ok(parse_external_search_response(&value))
}

/// Search the directory (prints one window to stdout).
pub async fn search_people(query: &str, limit: usize) -> Result<()> {
    let client = TeamsClient::new().await?;
    let people = search_people_data(&client, query, limit).await?;

    println!("\nPeople results for {:?}:", query);
    println!("{:-<60}", "");
    if people.is_empty() {
        println!("  (no people found)");
        return Ok(());
    }
    for p in &people {
        println!(
            "{} — {}",
            p.display_name,
            p.email.as_deref().unwrap_or("(no email)")
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn limit_clamps_to_graph_window() {
        assert_eq!(clamp_limit(0), 1);
        assert_eq!(clamp_limit(10), 10);
        assert_eq!(clamp_limit(25), 25);
        assert_eq!(clamp_limit(500), 25);
    }

    #[test]
    fn drive_path_shape_matches_graph_contract() {
        assert_eq!(
            drive_search_path("quarterly plan", 50),
            "/me/drive/root/search(q='quarterly%20plan')?$top=25"
        );
    }

    #[test]
    fn drive_path_escapes_single_quotes() {
        assert_eq!(
            drive_search_path("tom's", 10),
            "/me/drive/root/search(q='tom%27%27s')?$top=10"
        );
    }

    #[test]
    fn people_path_shape_matches_graph_contract() {
        assert_eq!(
            people_search_path("ava", 50),
            "/users?$search=\"displayName:ava\"&$select=id,displayName,mail,userPrincipalName,userType&$top=25"
        );
    }

    #[test]
    fn people_path_drops_embedded_quotes() {
        assert_eq!(
            people_search_path("a\"b", 10),
            "/users?$search=\"displayName:ab\"&$select=id,displayName,mail,userPrincipalName,userType&$top=10"
        );
    }

    #[test]
    fn mail_path_shape_matches_graph_contract() {
        assert_eq!(
            people_mail_path("ava@x.example"),
            "/users?$filter=mail eq 'ava%40x.example'&$select=id,displayName,mail,userPrincipalName,userType&$top=25"
        );
    }

    #[test]
    fn mail_path_escapes_single_quotes() {
        assert_eq!(
            people_mail_path("o'brien@x.example"),
            "/users?$filter=mail eq 'o%27%27brien%40x.example'&$select=id,displayName,mail,userPrincipalName,userType&$top=25"
        );
    }

    #[test]
    fn email_gate_matches_complete_addresses_only() {
        assert!(looks_like_email("test.user@example.com"));
        assert!(looks_like_email("  a@b.co  "));
        assert!(!looks_like_email("ava"));
        assert!(!looks_like_email("a@b"));
        assert!(!looks_like_email("a b@c.de"));
        assert!(!looks_like_email(""));
    }

    #[test]
    fn external_path_shape_matches_teams_contract() {
        assert_eq!(
            external_search_path("https://teams.microsoft.com/api/mt/amer", "a@b.co"),
            "https://teams.microsoft.com/api/mt/amer/beta/users/a%40b.co/externalsearchv3?includeTFLUsers=true"
        );
    }

    #[test]
    fn parse_drive_hits_files_and_folders() {
        let value = json!({
            "value": [
                {"id": "f1", "name": "plan.md", "size": 48211,
                 "webUrl": "https://x/plan",
                 "file": {"mimeType": "text/markdown"},
                 "parentReference": {"driveId": "d1"}},
                {"id": "d9", "name": "Design", "folder": {}},
                {"name": "no-id-skipped"},
            ]
        });
        let files = parse_drive_search_response(&value);
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].name, "plan.md");
        assert_eq!(files[0].size, 48211);
        assert_eq!(files[0].drive_id.as_deref(), Some("d1"));
        assert!(!files[0].is_folder);
        assert!(files[1].is_folder);
    }

    #[test]
    fn parse_drive_tolerates_unknown_shapes() {
        for raw in [
            json!({}),
            json!({"value": []}),
            json!(null),
            json!("bogus"),
        ] {
            assert!(parse_drive_search_response(&raw).is_empty());
        }
    }

    #[test]
    fn parse_people_prefers_mail_over_upn() {
        let value = json!({
            "value": [
                {"id": "u1", "displayName": "Ava Lindqvist",
                 "mail": "ava@x", "userPrincipalName": "ava.upn@x"},
                {"id": "u2", "displayName": "Tom Becker",
                 "mail": null, "userPrincipalName": "tom@x"},
                {"displayName": "no-id-skipped"},
            ]
        });
        let people = parse_people_search_response(&value);
        assert_eq!(people.len(), 2);
        assert_eq!(people[0].email.as_deref(), Some("ava@x"));
        assert_eq!(people[0].user_id.as_deref(), Some("u1"));
        assert!(people[0].roles.is_empty());
        assert!(!people[0].is_owner);
        assert_eq!(people[1].email.as_deref(), Some("tom@x"));
    }

    #[test]
    fn parse_people_tolerates_unknown_shapes() {
        for raw in [
            json!({}),
            json!({"value": []}),
            json!(null),
            json!("bogus"),
        ] {
            assert!(parse_people_search_response(&raw).is_empty());
        }
    }

    #[test]
    fn parse_people_carries_user_type() {
        let value = json!({
            "value": [
                {"id": "u1", "displayName": "Ava Lindqvist",
                 "mail": "ava@x", "userPrincipalName": "ava@x",
                 "userType": "Member"},
                {"id": "g9", "displayName": "Guest User",
                 "mail": null, "userPrincipalName": "guest_x#EXT#@t",
                 "userType": "Guest"},
            ]
        });
        let people = parse_people_search_response(&value);
        assert_eq!(people.len(), 2);
        assert_eq!(people[0].user_type.as_deref(), Some("Member"));
        assert_eq!(people[1].user_type.as_deref(), Some("Guest"));
    }

    #[test]
    fn parse_external_federated_uses_verbatim_mri() {
        let value = json!({
            "tenantId": "ceffd5d3-edcb-482e-a7ed-3ecedfe5519c",
            "accountEnabled": true,
            "userPrincipalName": "freddiem@snoopcore.com",
            "displayName": "Freddie Mercury",
            "email": "freddiem@snoopcore.com",
            "type": "Federated",
            "mri": "8:orgid:87da1b0b-e2a5-4964-9fcc-70bf0a186fe0",
            "objectId": "87da1b0b-e2a5-4964-9fcc-70bf0a186fe0",
        });
        let m = parse_external_search_response(&value).expect("federated hit");
        assert_eq!(m.user_id.as_deref(), Some("8:orgid:87da1b0b-e2a5-4964-9fcc-70bf0a186fe0"));
        assert_eq!(m.id, "87da1b0b-e2a5-4964-9fcc-70bf0a186fe0");
        assert_eq!(m.display_name, "Freddie Mercury");
        assert_eq!(m.user_type.as_deref(), Some("Federated"));
    }

    #[test]
    fn parse_external_skype_falls_back_to_email_name() {
        let value = json!({
            "skypeId": "live:consumertest",
            "userPrincipalName": "consumer.test@example.com",
            "email": "consumer.test@example.com",
            "displayName": " ",
            "type": "SkypeConsumer",
            "mri": "8:live:consumertest",
        });
        let m = parse_external_search_response(&value).expect("skype hit");
        assert_eq!(m.display_name, "consumer.test@example.com");
        assert_eq!(m.id, "8:live:consumertest");
    }

    #[test]
    fn parse_external_without_mri_is_none() {
        for raw in [
            json!({}),
            json!({"type": "Federated"}),
            json!(null),
            json!("bogus"),
        ] {
            assert!(parse_external_search_response(&raw).is_none());
        }
    }

    fn row(id: &str, user_id: &str, email: &str) -> TeamMemberInfo {
        TeamMemberInfo {
            id: id.to_string(),
            display_name: id.to_string(),
            user_id: Some(user_id.to_string()),
            email: Some(email.to_string()),
            roles: Vec::new(),
            is_owner: false,
            user_type: None,
        }
    }

    #[test]
    fn merge_people_dedupes_by_ref_and_appends_new() {
        let mut base = vec![row("u1", "oid-1", "ava@x")];
        merge_people(&mut base, vec![
            row("u1-dup", "OID-1", "other@x"),
            row("g9", "oid-9", "guest@x"),
        ]);
        assert_eq!(base.len(), 2);
        assert_eq!(base[1].id, "g9");
    }

    #[test]
    fn merge_people_never_collides_mri_with_directory_ids() {
        let mut base = vec![row("u1", "oid-1", "ava@x")];
        merge_people(&mut base, vec![row(
            "oid-1",
            "8:orgid:87da1b0b-e2a5-4964-9fcc-70bf0a186fe0",
            "freddiem@snoopcore.com",
        )]);
        assert_eq!(base.len(), 2);
    }
}
