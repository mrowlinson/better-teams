//! Loop/Fluid component surface (lanes/loopbuild, OstMac §126).
//!
//! Pure request builders + transports for the RE-mapped private
//! surface (reloop/REPORT.md §4: C1–C5, E1–E2, S1–S6). Every builder
//! is verbatim-pinned by the tests below; every transport is real
//! but LIVE-UNPROVEN (phase-2 plan in reloop/REPORT.md §5).
//!
//! Capture-time pins (hosts, auth, sync bytes) are flagged `P2`
//! inline: exact chat-send bytes (E1), the C1 snapshot body
//! template, socket-wire details (S4), and token grants under our
//! client id (P2-1 gates everything).

use std::collections::HashMap;

use anyhow::Result;
use base64::Engine;

use super::chat::SentMessage;
use super::client::TeamsClient;

/// Loop page service base (mined `loopServiceEndpoint`, config-prod).
pub const LOOP_PAGE_API: &str = "https://prod.api.loop.cloud.microsoft/v0.1";
/// Loop page service token audience (mined const `ydr`).
/// P2: grant under OUR client id must be proven (P2-1).
pub const LOOP_AUDIENCE: &str = "https://api.loop.cloud.microsoft/";
/// MCPS notes/collab audience (mined, C5 transport).
pub const MCPS_RESOURCE: &str = "6bc3b958-689b-49f5-9006-36d165f30e00";
/// Live-sync socket token audience (mined prefetch module, S4).
pub const PUSHCHANNEL_RESOURCE: &str = "https://pushchannel.1drv.ms/pushchannel.readwrite.all";
/// Embed-mode card content type (mined read path §2.6).
pub const FLUID_EMBED_CARD_CT: &str = "application/vnd.microsoft.card.fluidEmbedCard";
/// Legacy Collaborate-mode card content type (mined §2.6).
pub const FLUID_CARD_CT: &str = "application/vnd.microsoft.card.fluid";
/// Default chat-component folder in the creator's OneDrive (mined §2.4).
pub const LOOP_FOLDER: &str = "Loop";
/// Component types Teams' composer offers (mined `composeEnabledComponents`).
pub const COMPOSE_COMPONENTS: [&str; 11] = [
    "bulletedList",
    "checklist",
    "FFX-KanbanBoard",
    "numberedList",
    "paragraph",
    "FFX-ProgressTracker",
    "questionAnswer",
    "FFX-RetroBoard",
    "table",
    "votingTable",
    "actionItems",
];

/// `encodeURIComponent` for one path segment (C1 drive/folder/file):
/// RFC 3986 unreserved + `!'()*-._~` stay bare, the rest %XX
/// (uppercase hex, matching JS). Pure.
fn encode_segment(s: &str) -> String {
    const BARE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()";
    let mut out = String::with_capacity(s.len());
    for b in s.as_bytes() {
        if BARE.contains(b) {
            out.push(*b as char);
        } else {
            out.push_str(&format!("%{:02X}", b));
        }
    }
    out
}

// -- C1: create Fluid file + container -------------------------------------

/// C1 snapshot-create URL (mined `Ge`/`y7r`, SDK `/snapshot API`):
/// `POST {site}/_api/v2.1/drives/{drive}/items/root:/{folder}/{file}:/opStream/snapshots/snapshot[?{share}]`.
/// `share_query` is the single-request share-link params
/// (`createLinkScope=…&createLinkRole=…`), if any. Pure.
pub fn snapshot_create_url(
    site: &str,
    drive_id: &str,
    folder: &str,
    file_name: &str,
    share_query: Option<&str>,
) -> String {
    let base = format!(
        "{}/_api/v2.1/drives/{}/items/root:/{}/{}:/opStream/snapshots/snapshot",
        site.trim_end_matches('/'),
        encode_segment(drive_id),
        encode_segment(folder),
        encode_segment(file_name)
    );
    match share_query.filter(|q| !q.trim().is_empty()) {
        Some(q) => format!("{}?{}", base, q.trim()),
        None => base,
    }
}

/// Created-snapshot fields the response transform `Qe` requires
/// (plus optional sharing block). Pure parse target.
#[derive(Debug, Clone, PartialEq, Eq, Default, serde::Serialize)]
pub struct SnapshotCreated {
    pub item_id: String,
    pub drive_id: String,
    pub item_url: String,
    pub list_item_unique_id: String,
    pub share_id: Option<String>,
    pub share_link: Option<String>,
}

/// C1 answer → [`SnapshotCreated`] (mined `Qe` required keys:
/// `itemId, driveId, itemUrl, listItemUniqueId`; optional
/// `sharing.shareId` + `sharing.sharingLink.webUrl`). Pure.
pub fn parse_snapshot_answer(v: &serde_json::Value) -> Option<SnapshotCreated> {
    Some(SnapshotCreated {
        item_id: v["itemId"].as_str().filter(|s| !s.is_empty())?.to_string(),
        drive_id: v["driveId"].as_str().filter(|s| !s.is_empty())?.to_string(),
        item_url: v["itemUrl"].as_str().filter(|s| !s.is_empty())?.to_string(),
        list_item_unique_id: v["listItemUniqueId"].as_str().filter(|s| !s.is_empty())?.to_string(),
        share_id: v["sharing"]["shareId"].as_str().map(str::to_string),
        share_link: v["sharing"]["sharingLink"]["webUrl"].as_str().map(str::to_string),
    })
}

// -- C2: share URL for the new file -----------------------------------------

/// C2 GetSharingInformation URL (mined `Me` + SDK table):
/// `POST {site}/_api/web/GetFileById(@a1)/ListItemAllFields/GetSharingInformation?@a1=guid'{uid}'`.
/// Callers add the odata-verbose headers. Pure.
pub fn sharing_info_url(site: &str, list_item_unique_id: &str) -> String {
    format!(
        "{}/_api/web/GetFileById(@a1)/ListItemAllFields/GetSharingInformation?@a1=guid'{}'",
        site.trim_end_matches('/'),
        list_item_unique_id.trim()
    )
}

/// C2 answer → direct URL (`{d:{directUrl,…}}`). Pure.
pub fn sharing_direct_url(v: &serde_json::Value) -> Option<String> {
    v["d"]["directUrl"]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

// -- C3: componentUrl (the embed URL) ---------------------------------------

/// C3 embed URL (mined `ce`, byte-exact): `directUrl` plus
/// `?nav=b64("s={sitePath}&d={driveId}&f={itemId}&c=@fluidx/loop-page-container&fluid=1&a=Teams&p=@fluidx/loop-page-container")`.
/// Base64 is STANDARD with padding (Node `Buffer.toString("base64")`). Pure.
pub fn component_url(direct_url: &str, site_path: &str, drive_id: &str, item_id: &str) -> String {
    let inner = format!(
        "s={}&d={}&f={}&c={}&fluid=1&a={}&p={}",
        url_encode_query(site_path),
        url_encode_query(drive_id),
        url_encode_query(item_id),
        url_encode_query("@fluidx/loop-page-container"),
        url_encode_query("Teams"),
        url_encode_query("@fluidx/loop-page-container")
    );
    let nav = base64::engine::general_purpose::STANDARD.encode(inner.as_bytes());
    let sep = if direct_url.contains('?') { '&' } else { '?' };
    format!("{}{}nav={}", direct_url, sep, nav)
}

/// Query-value encoding for the C3 nav payload (`encodeURIComponent`
/// semantics — same table as [`encode_segment`]). Pure.
fn url_encode_query(s: &str) -> String {
    encode_segment(s)
}

// -- C4: create Loop page (storage API) ---------------------------------------

/// C4 storage id: STANDARD base64 of `siteUrl,driveId` (mined `h4e`
/// call in `createResourceCollabObject`). Pure.
pub fn storage_id(site_url: &str, drive_id: &str) -> String {
    base64::engine::general_purpose::STANDARD.encode(format!("{},{}", site_url, drive_id))
}

/// C4 create URL (mined `kur`): `POST {LOOP_PAGE_API}/storage/{storage_id}/pages`. Pure.
pub fn storage_pages_url(site_url: &str, drive_id: &str) -> String {
    format!("{}/storage/{}/pages", LOOP_PAGE_API, storage_id(site_url, drive_id))
}

/// C4 body (mined `Sur`): `{title, content:{type,value}, path,
/// shareLinkOptions?}`. Pure.
pub fn page_create_body(
    title: &str,
    content_type: &str,
    content_value: &str,
    path: &str,
    share_link_options: Option<serde_json::Value>,
) -> serde_json::Value {
    let mut body = serde_json::json!({
        "title": title,
        "content": {"type": content_type, "value": content_value},
        "path": path,
    });
    if let Some(opts) = share_link_options {
        body["shareLinkOptions"] = opts;
    }
    body
}

/// C4 answer → page link (`{page:{link,…}}`). Pure.
pub fn created_page_link(v: &serde_json::Value) -> Option<String> {
    v["page"]["link"]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

// -- C5: get-or-create meeting notes ------------------------------------------

/// C5 URL (mined `yur` op `getOrCreateMeetingNotes`, +recap2).
/// P2: full host path must be confirmed by capture.
pub fn meeting_notes_url() -> String {
    "https://teams.microsoft.com/api/mcps/prod/notes/getOrCreateMeetingNotes".to_string()
}

// -- E2: share link for recipients ----------------------------------------------

/// E2 Graph createLink path (mined `Re`):
/// `POST /v1.0/drives/{drive}/items/{item}/createLink`. Pure.
pub fn graph_createlink_path(drive_id: &str, item_id: &str) -> String {
    format!("/v1.0/drives/{}/items/{}/createLink", drive_id.trim(), item_id.trim())
}

/// E2 Vroom createLink URL (mined `ge`):
/// `POST {site}/_api/v2.1/drives/{drive}/items/{item}/createLink`. Pure.
pub fn vroom_createlink_url(site: &str, drive_id: &str, item_id: &str) -> String {
    format!(
        "{}/_api/v2.1/drives/{}/items/{}/createLink",
        site.trim_end_matches('/'),
        drive_id.trim(),
        item_id.trim()
    )
}

/// E2 body (mined `ge`): `{role|type (+variant), scope?, recipients?}`.
/// `role_or_type` is `("role", value)` or `("type", value)`; mirrors
/// `l&&d?(C.role=l,C.variant=d):C.type=a`. Pure.
pub fn createlink_body(
    role_or_type: (&str, &str),
    variant: Option<&str>,
    scope: Option<&str>,
    recipients: Vec<String>,
) -> serde_json::Value {
    let mut body = serde_json::Map::new();
    body.insert(role_or_type.0.to_string(), serde_json::Value::String(role_or_type.1.to_string()));
    if let Some(v) = variant {
        body.insert("variant".to_string(), serde_json::Value::String(v.to_string()));
    }
    if let Some(s) = scope.filter(|s| !s.trim().is_empty()) {
        body.insert("scope".to_string(), serde_json::Value::String(s.to_string()));
    }
    if !recipients.is_empty() {
        body.insert("recipients".to_string(), serde_json::Value::Array(
            recipients.into_iter().map(serde_json::Value::String).collect(),
        ));
    }
    serde_json::Value::Object(body)
}

// -- E1: embed (send message with component) ------------------------------------

/// E1 `cards` value (mined read path §2.6 + send builder `LAn`): a
/// JSON STRING of one `fluidEmbedCard` card carrying `componentUrl`.
/// P2: exact POST bytes must be confirmed by capture (cards-first).
pub fn embed_cards_json(component_url: &str) -> String {
    serde_json::json!([{
        "contentType": FLUID_EMBED_CARD_CT,
        "content": {"componentUrl": component_url},
    }])
    .to_string()
}

/// E1 message body: the chat-service send shape
/// (`content`/`messagetype`/`contenttype`) plus the `cards` string.
/// P2: field-by-field confirm against §2.6.
pub fn embed_message_body(text: &str, cards_json: &str) -> serde_json::Value {
    let html = format!("<p>{}</p>", html_escape(text));
    serde_json::json!({
        "content": html,
        "messagetype": "RichText/Html",
        "contenttype": "text",
        "cards": cards_json,
    })
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

// -- S1: read page HTML snapshot --------------------------------------------------

/// S1 page id: STANDARD base64 of `host,driveId,driveItemId`
/// (mined `h4e` call in `readPageContent`; byte-identical scheme to
/// `ostmac-core recap::loop_page_url`, which stays the S1 transport
/// there — this builder serves the ost/CLI path). Pure.
pub fn page_id(host: &str, drive_id: &str, item_id: &str) -> String {
    base64::engine::general_purpose::STANDARD
        .encode(format!("{},{},{}", host, drive_id, item_id))
}

/// S1 read URL (mined `Fur`): `POST {LOOP_PAGE_API}/pages/{page_id}`. Pure.
pub fn page_read_url(host: &str, drive_id: &str, item_id: &str) -> String {
    format!("{}/pages/{}", LOOP_PAGE_API, page_id(host, drive_id, item_id))
}

/// S1 body (mined `_ur`): `{options:{type:"html"(,commentFormat)},
/// sharingLinkToRedeem?}`. Pure.
pub fn page_read_body(comment_format: Option<&str>, sharing_link_to_redeem: Option<&str>) -> serde_json::Value {
    let mut options = serde_json::json!({"type": "html"});
    if let Some(cf) = comment_format.filter(|s| !s.trim().is_empty()) {
        options["commentFormat"] = serde_json::Value::String(cf.to_string());
    }
    let mut body = serde_json::json!({"options": options});
    if let Some(sl) = sharing_link_to_redeem.filter(|s| !s.trim().is_empty()) {
        body["sharingLinkToRedeem"] = serde_json::Value::String(sl.to_string());
    }
    body
}

/// S1 answer → HTML (`content`, PROVEN field). Pure.
pub fn page_content_of(v: &serde_json::Value) -> Option<String> {
    v["content"].as_str().map(str::to_string)
}

// -- S2–S6: ODSP sync reads (SDK table; Teams driver path P2-confirm) -------------

/// S2 snapshot load (SDK): `GET
/// {site}/_api/v2.1/drives/{d}/items/{i}/opStream/snapshots/trees/latest?ump=1[&sl={shareLink}]`.
pub fn snapshot_load_url(site: &str, drive_id: &str, item_id: &str, share_link: Option<&str>) -> String {
    let base = format!(
        "{}/_api/v2.1/drives/{}/items/{}/opStream/snapshots/trees/latest?ump=1",
        site.trim_end_matches('/'),
        drive_id.trim(),
        item_id.trim()
    );
    match share_link.filter(|s| !s.trim().is_empty()) {
        Some(sl) => format!("{}&sl={}", base, encode_segment(sl.trim())),
        None => base,
    }
}

/// S3 ops catch-up (SDK): `GET
/// {site}/_api/v2.1/drives/{d}/items/{i}/opStream?ump=1&filter=sequenceNumber
/// ge {start} and sequenceNumber le {end}`.
pub fn ops_fetch_url(site: &str, drive_id: &str, item_id: &str, start: u64, end: u64) -> String {
    format!(
        "{}/_api/v2.1/drives/{}/items/{}/opStream?ump=1&filter=sequenceNumber ge {} and sequenceNumber le {}",
        site.trim_end_matches('/'),
        drive_id.trim(),
        item_id.trim(),
        start,
        end
    )
}

/// S4 join session (SDK): `{site}/_api/v2.1/drives/{d}/items/{i}/opStream/joinSession?ump=1`.
/// Renew ~15 min; socket URL arrives in the response (P2).
pub fn join_session_url(site: &str, drive_id: &str, item_id: &str) -> String {
    format!(
        "{}/_api/v2.1/drives/{}/items/{}/opStream/joinSession?ump=1",
        site.trim_end_matches('/'),
        drive_id.trim(),
        item_id.trim()
    )
}

/// S5 summary upload (SDK): `POST
/// {site}/_api/v2.1/drives/{d}/items/{i}/opStream/snapshots/snapshot`.
pub fn summary_upload_url(site: &str, drive_id: &str, item_id: &str) -> String {
    format!(
        "{}/_api/v2.1/drives/{}/items/{}/opStream/snapshots/snapshot",
        site.trim_end_matches('/'),
        drive_id.trim(),
        item_id.trim()
    )
}

/// S6 attachment blob content (SDK): `{site}/_api/v2.1/drives/{d}/items/{i}/opStream/{attachment(s)…}/content`.
/// `rel` is the SDK's attachment sub-path (verbatim passthrough).
pub fn blob_content_url(site: &str, drive_id: &str, item_id: &str, rel: &str) -> String {
    format!(
        "{}/_api/v2.1/drives/{}/items/{}/opStream/{}/content",
        site.trim_end_matches('/'),
        drive_id.trim(),
        item_id.trim(),
        rel.trim().trim_matches('/')
    )
}

// -- Read path: keep-gate + mining (mined §2.6) -------------------------------------

/// Skype content markers official clients sniff for Loop content
/// (mined enum @8288252; forward/quote flows).
pub const FLUID_CONTENT_MARKERS: [&str; 5] = [
    "http://schema.skype.com/FluidLink",
    "http://schema.skype.com/FluidEmbedLink",
    "http://schema.skype.com/FluidEmbedCard",
    "http://schema.skype.com/FluidAutoEmbedLink",
    "http://schema.skype.com/FluidRecapChiclet",
];

/// True when HTML carries a Loop content marker. Pure.
pub fn contains_fluid_marker(html: &str) -> bool {
    FLUID_CONTENT_MARKERS.iter().any(|m| html.contains(m))
}

/// Render mode for one mined card: Embed (`fluidEmbedCard`) or
/// legacy Collaborate (`card.fluid`). Pure.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub enum EmbedMode {
    Embed,
    Collaborate,
}

/// One mined Loop card: its component URL + mode. Pure.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct FluidEmbed {
    pub component_url: String,
    pub mode: EmbedMode,
}

/// Mine Loop cards from a message's `cards` JSON (mined §2.6: parse
/// the array → `contentType` match → `content.componentUrl`).
/// Accepts the wire string form or a bare array/object. Pure.
pub fn fluid_embeds_in(cards_json: &str) -> Vec<FluidEmbed> {
    let v: serde_json::Value = match serde_json::from_str(cards_json) {
        Ok(v) => v,
        Err(_) => return vec![],
    };
    let arr = match &v {
        serde_json::Value::Array(a) => a.clone(),
        serde_json::Value::Object(_) => vec![v],
        _ => return vec![],
    };
    arr.iter()
        .filter_map(|c| {
            let ct = c["contentType"].as_str().unwrap_or("");
            let mode = if ct.eq_ignore_ascii_case(FLUID_EMBED_CARD_CT) {
                EmbedMode::Embed
            } else if ct.eq_ignore_ascii_case(FLUID_CARD_CT) {
                EmbedMode::Collaborate
            } else {
                return None;
            };
            let url = c["content"]["componentUrl"].as_str().filter(|s| !s.is_empty())?;
            Some(FluidEmbed { component_url: url.to_string(), mode })
        })
        .collect()
}

/// True when `cards` JSON carries at least one Loop card. Pure.
pub fn has_fluid_cards(cards_json: &str) -> bool {
    !fluid_embeds_in(cards_json).is_empty()
}

/// Keep-gate: retain the server's `cards` field (case-insensitive)
/// as a compact JSON string. String form passes through; array /
/// object forms are re-serialized; anything else is dropped. Pure.
pub fn cards_json_of(extra: &HashMap<String, serde_json::Value>) -> Option<String> {
    let v = extra.iter().find(|(k, _)| k.eq_ignore_ascii_case("cards")).map(|(_, v)| v)?;
    match v {
        serde_json::Value::String(s) if !s.trim().is_empty() => Some(s.clone()),
        serde_json::Value::Array(_) | serde_json::Value::Object(_) => Some(v.to_string()),
        _ => None,
    }
}

// -- Transports (real, LIVE-UNPROVEN — phase-2 plan reloop/REPORT.md §5) -------------

/// User-delegated bearer for `resource` (`{resource}/.default`,
/// same pattern as `ostmac-core recap::bearer`). P2-1 gates grants.
async fn bearer_for(resource: &str) -> Result<String> {
    let profile = crate::config::active_profile();
    let scope = format!("{}/.default", resource.trim_end_matches('/'));
    let grant = crate::auth::oauth::token_for_scope_for(&profile, &scope).await?;
    Ok(grant.access_token)
}

async fn bearer_post(url: &str, token: &str, body: &str, what: &str) -> Result<serde_json::Value> {
    let resp = super::client::shared_http()
        .post(url)
        .bearer_auth(token)
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .body(body.to_string())
        .send()
        .await?;
    let status = resp.status();
    if !status.is_success() {
        anyhow::bail!("{}: HTTP {}", what, status.as_u16());
    }
    Ok(resp.json::<serde_json::Value>().await?)
}

async fn bearer_get(url: &str, token: &str, what: &str) -> Result<serde_json::Value> {
    let resp = super::client::shared_http()
        .get(url)
        .bearer_auth(token)
        .header("Accept", "application/json")
        .send()
        .await?;
    let status = resp.status();
    if !status.is_success() {
        anyhow::bail!("{}: HTTP {}", what, status.as_u16());
    }
    Ok(resp.json::<serde_json::Value>().await?)
}

/// C1 transport: create the Fluid file + container. `snapshot_body`
/// is the detached-container summary string (P2 captures the chat
/// template); site token audience. LIVE-UNPROVEN.
pub async fn create_snapshot(
    site: &str,
    drive_id: &str,
    folder: &str,
    file_name: &str,
    snapshot_body: &str,
    share_query: Option<&str>,
) -> Result<SnapshotCreated> {
    let token = bearer_for(site).await?;
    let v = bearer_post(&snapshot_create_url(site, drive_id, folder, file_name, share_query), &token, snapshot_body, "loop snapshot create").await?;
    parse_snapshot_answer(&v).ok_or_else(|| anyhow::anyhow!("loop snapshot create: answer lacks item fields"))
}

/// C2 transport: share URL for the new file (odata-verbose). LIVE-UNPROVEN.
pub async fn get_sharing_information(site: &str, list_item_unique_id: &str) -> Result<String> {
    let token = bearer_for(site).await?;
    let resp = super::client::shared_http()
        .post(sharing_info_url(site, list_item_unique_id))
        .bearer_auth(&token)
        .header("Accept", "application/json;odata=verbose")
        .header("Content-Type", "application/json;odata=verbose")
        .send()
        .await?;
    if !resp.status().is_success() {
        anyhow::bail!("loop sharing info: HTTP {}", resp.status().as_u16());
    }
    let v: serde_json::Value = resp.json().await?;
    sharing_direct_url(&v).ok_or_else(|| anyhow::anyhow!("loop sharing info: answer lacks directUrl"))
}

/// C4 transport: create a Loop page. LIVE-UNPROVEN.
pub async fn create_loop_page(
    site_url: &str,
    drive_id: &str,
    title: &str,
    content_type: &str,
    content_value: &str,
    path: &str,
) -> Result<String> {
    let token = bearer_for(LOOP_AUDIENCE).await?;
    let body = page_create_body(title, content_type, content_value, path, None).to_string();
    let v = bearer_post(&storage_pages_url(site_url, drive_id), &token, &body, "loop page create").await?;
    created_page_link(&v).ok_or_else(|| anyhow::anyhow!("loop page create: answer lacks page.link"))
}

/// E1 transport: post a message carrying the Loop card. LIVE-UNPROVEN (P2-4).
pub async fn send_loop_embed(
    client: &TeamsClient,
    chat_id: &str,
    text: &str,
    component_url: &str,
    client_message_id: &str,
) -> Result<SentMessage> {
    let url = format!(
        "{}/v1/users/ME/conversations/{}/messages",
        client.chat_service_url(),
        chat_id
    );
    let body = embed_message_body(text, &embed_cards_json(component_url));
    super::chat::send_raw_with_receipt(client, &url, body, client_message_id).await
}

/// E2 transport (Graph): share link for recipients. LIVE-UNPROVEN.
pub async fn createlink_graph(
    client: &TeamsClient,
    drive_id: &str,
    item_id: &str,
    body: &serde_json::Value,
) -> Result<serde_json::Value> {
    let resp = client.graph_post(&graph_createlink_path(drive_id, item_id), body).await?;
    if !resp.status().is_success() {
        anyhow::bail!("loop createlink: HTTP {}", resp.status().as_u16());
    }
    Ok(resp.json::<serde_json::Value>().await?)
}

/// S1 transport: page HTML snapshot. LIVE-UNPROVEN.
pub async fn read_loop_page(host: &str, drive_id: &str, item_id: &str) -> Result<String> {
    let token = bearer_for(LOOP_AUDIENCE).await?;
    let v = bearer_post(&page_read_url(host, drive_id, item_id), &token, &page_read_body(None, None).to_string(), "loop page read").await?;
    page_content_of(&v).ok_or_else(|| anyhow::anyhow!("loop page read: answer lacks content"))
}

/// S2 transport: ODSP snapshot load. LIVE-UNPROVEN.
pub async fn snapshot_load(
    site: &str,
    drive_id: &str,
    item_id: &str,
    share_link: Option<&str>,
) -> Result<serde_json::Value> {
    let token = bearer_for(site).await?;
    bearer_get(&snapshot_load_url(site, drive_id, item_id, share_link), &token, "loop snapshot load").await
}

/// S3 transport: ops catch-up over [start, end]. LIVE-UNPROVEN.
pub async fn ops_fetch(
    site: &str,
    drive_id: &str,
    item_id: &str,
    start: u64,
    end: u64,
) -> Result<serde_json::Value> {
    let token = bearer_for(site).await?;
    bearer_get(&ops_fetch_url(site, drive_id, item_id, start, end), &token, "loop ops fetch").await
}

/// S4 transport: join collab session (socket creds). LIVE-UNPROVEN.
pub async fn join_session(site: &str, drive_id: &str, item_id: &str) -> Result<serde_json::Value> {
    let token = bearer_for(site).await?;
    bearer_get(&join_session_url(site, drive_id, item_id), &token, "loop join session").await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn c1_url_pins_mined_shape() {
        assert_eq!(
            snapshot_create_url("https://t-my.sharepoint.com", "D", "Loop", "x.loop", None),
            "https://t-my.sharepoint.com/_api/v2.1/drives/D/items/root:/Loop/x.loop:/opStream/snapshots/snapshot"
        );
        assert_eq!(
            snapshot_create_url(
                "https://t-my.sharepoint.com/", "D", "Loop", "x.loop",
                Some("createLinkScope=organization&createLinkRole=edit")
            ),
            "https://t-my.sharepoint.com/_api/v2.1/drives/D/items/root:/Loop/x.loop:/opStream/snapshots/snapshot?createLinkScope=organization&createLinkRole=edit"
        );
        // Segments are encodeURIComponent-escaped (space, slash).
        assert!(snapshot_create_url("https://s", "a b", "L", "f", None).contains("/drives/a%20b/"));
    }

    #[test]
    fn c1_answer_parse_requires_qe_keys() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{"itemId":"i","driveId":"d","itemUrl":"u","listItemUniqueId":"g",
                "sharing":{"shareId":"s","sharingLink":{"webUrl":"w"}}}"#,
        )
        .unwrap();
        let c = parse_snapshot_answer(&v).expect("full answer parses");
        assert_eq!((c.item_id.as_str(), c.drive_id.as_str()), ("i", "d"));
        assert_eq!(c.share_link.as_deref(), Some("w"));
        let missing: serde_json::Value = serde_json::from_str(r#"{"itemId":"i"}"#).unwrap();
        assert!(parse_snapshot_answer(&missing).is_none());
    }

    #[test]
    fn c2_url_pins_odata_shape() {
        assert_eq!(
            sharing_info_url("https://t-my.sharepoint.com", "GUID"),
            "https://t-my.sharepoint.com/_api/web/GetFileById(@a1)/ListItemAllFields/GetSharingInformation?@a1=guid'GUID'"
        );
        let v: serde_json::Value =
            serde_json::from_str(r#"{"d":{"directUrl":"https://t/x","defaultShareLinkScope":1}}"#).unwrap();
        assert_eq!(sharing_direct_url(&v).as_deref(), Some("https://t/x"));
    }

    #[test]
    fn c3_component_url_byte_exact() {
        let got = component_url("https://t-my.sharepoint.com/x", "/", "D", "F");
        let nav = got.split("?nav=").nth(1).expect("nav param");
        let raw = base64::engine::general_purpose::STANDARD.decode(nav).expect("nav is b64");
        assert_eq!(
            String::from_utf8(raw).unwrap(),
            "s=%2F&d=D&f=F&c=%40fluidx%2Floop-page-container&fluid=1&a=Teams&p=%40fluidx%2Floop-page-container"
        );
        // Existing query keeps working (& separator).
        assert!(component_url("https://t/x?a=b", "/", "D", "F").contains("&nav="));
    }

    #[test]
    fn c4_storage_create_pins_mined_shape() {
        let id = storage_id("https://t-my.sharepoint.com", "D");
        let raw = base64::engine::general_purpose::STANDARD.decode(&id).unwrap();
        assert_eq!(String::from_utf8(raw).unwrap(), "https://t-my.sharepoint.com,D");
        assert_eq!(
            storage_pages_url("https://t-my.sharepoint.com", "D"),
            format!("https://prod.api.loop.cloud.microsoft/v0.1/storage/{}/pages", id)
        );
        let body = page_create_body("T", "html", "<p>hi</p>", "/p", None);
        assert_eq!(body["title"], "T");
        assert_eq!(body["content"]["type"], "html");
        assert!(body.get("shareLinkOptions").is_none());
        let v: serde_json::Value = serde_json::from_str(r#"{"page":{"link":"L"}}"#).unwrap();
        assert_eq!(created_page_link(&v).as_deref(), Some("L"));
    }

    #[test]
    fn c5_url_pin() {
        assert_eq!(
            meeting_notes_url(),
            "https://teams.microsoft.com/api/mcps/prod/notes/getOrCreateMeetingNotes"
        );
    }

    #[test]
    fn e2_createlink_pins_mined_shapes() {
        assert_eq!(graph_createlink_path("d", "i"), "/v1.0/drives/d/items/i/createLink");
        assert_eq!(
            vroom_createlink_url("https://t/", "d", "i"),
            "https://t/_api/v2.1/drives/d/items/i/createLink"
        );
        let role = createlink_body(("role", "edit"), None, Some("organization"), vec![]);
        assert_eq!(role, serde_json::json!({"role": "edit", "scope": "organization"}));
        let typed = createlink_body(
            ("type", "view"), Some("commercial"), None,
            vec!["a@b.c".to_string()],
        );
        assert_eq!(
            typed,
            serde_json::json!({"type": "view", "variant": "commercial", "recipients": ["a@b.c"]})
        );
    }

    #[test]
    fn e1_embed_body_pins_cards_first_shape() {
        let cards = embed_cards_json("https://t/x?nav=abc");
        let parsed: serde_json::Value = serde_json::from_str(&cards).unwrap();
        assert_eq!(parsed[0]["contentType"], FLUID_EMBED_CARD_CT);
        assert_eq!(parsed[0]["content"]["componentUrl"], "https://t/x?nav=abc");
        let body = embed_message_body("hi <there>", &cards);
        assert_eq!(body["messagetype"], "RichText/Html");
        assert_eq!(body["contenttype"], "text");
        assert_eq!(body["content"], "<p>hi &lt;there&gt;</p>");
        assert_eq!(body["cards"], cards);
    }

    #[test]
    fn s1_read_pins_mined_shape() {
        let id = page_id("h", "d", "i");
        let raw = base64::engine::general_purpose::STANDARD.decode(&id).unwrap();
        assert_eq!(String::from_utf8(raw).unwrap(), "h,d,i");
        assert_eq!(
            page_read_url("h", "d", "i"),
            format!("https://prod.api.loop.cloud.microsoft/v0.1/pages/{}", id)
        );
        assert_eq!(page_read_body(None, None), serde_json::json!({"options": {"type": "html"}}));
        let v: serde_json::Value = serde_json::from_str(r#"{"content":"<p>x</p>"}"#).unwrap();
        assert_eq!(page_content_of(&v).as_deref(), Some("<p>x</p>"));
    }

    #[test]
    fn s2_s6_opstream_urls_pin_sdk_table() {
        let s = "https://t-my.sharepoint.com";
        assert_eq!(
            snapshot_load_url(s, "d", "i", None),
            "https://t-my.sharepoint.com/_api/v2.1/drives/d/items/i/opStream/snapshots/trees/latest?ump=1"
        );
        assert!(snapshot_load_url(s, "d", "i", Some("SL")).ends_with("?ump=1&sl=SL"));
        assert_eq!(
            ops_fetch_url(s, "d", "i", 3, 9),
            "https://t-my.sharepoint.com/_api/v2.1/drives/d/items/i/opStream?ump=1&filter=sequenceNumber ge 3 and sequenceNumber le 9"
        );
        assert_eq!(
            join_session_url(s, "d", "i"),
            "https://t-my.sharepoint.com/_api/v2.1/drives/d/items/i/opStream/joinSession?ump=1"
        );
        assert_eq!(
            summary_upload_url(s, "d", "i"),
            "https://t-my.sharepoint.com/_api/v2.1/drives/d/items/i/opStream/snapshots/snapshot"
        );
        assert_eq!(
            blob_content_url(s, "d", "i", "attachments/a1"),
            "https://t-my.sharepoint.com/_api/v2.1/drives/d/items/i/opStream/attachments/a1/content"
        );
    }

    #[test]
    fn mining_finds_embed_and_collaborate_only() {
        let cards = serde_json::json!([
            {"contentType": FLUID_EMBED_CARD_CT, "content": {"componentUrl": "E"}},
            {"contentType": "application/vnd.microsoft.card.fluid", "content": {"componentUrl": "C"}},
            {"contentType": "application/vnd.microsoft.card.adaptive", "content": {}},
            {"contentType": FLUID_EMBED_CARD_CT, "content": {}},
        ])
        .to_string();
        let found = fluid_embeds_in(&cards);
        assert_eq!(found.len(), 2);
        assert_eq!(
            found[0],
            FluidEmbed { component_url: "E".to_string(), mode: EmbedMode::Embed }
        );
        assert_eq!(found[1].mode, EmbedMode::Collaborate);
        assert!(has_fluid_cards(&cards));
        assert!(!has_fluid_cards("[]"));
        assert!(fluid_embeds_in("not json").is_empty());
    }

    #[test]
    fn keep_gate_retains_cards_field() {
        let mut extra = HashMap::new();
        extra.insert("cards".to_string(), serde_json::json!("[{\"a\":1}]"));
        assert_eq!(cards_json_of(&extra).as_deref(), Some("[{\"a\":1}]"));
        extra.insert("Cards".to_string(), serde_json::json!([{"a": 1}]));
        extra.remove("cards");
        assert_eq!(cards_json_of(&extra).as_deref(), Some(r#"[{"a":1}]"#));
        extra.clear();
        assert!(cards_json_of(&extra).is_none());
    }

    #[test]
    fn markers_and_segments() {
        assert!(contains_fluid_marker("<a href=\"http://schema.skype.com/FluidEmbedCard\">x</a>"));
        assert!(!contains_fluid_marker("<p>plain</p>"));
        assert_eq!(encode_segment("a b/c+d"), "a%20b%2Fc%2Bd");
        assert_eq!(encode_segment("abc-_.!~*'()"), "abc-_.!~*'()");
    }
}
