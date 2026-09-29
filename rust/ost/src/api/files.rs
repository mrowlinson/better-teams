//! Shared files in chats and channels via Microsoft Graph driveItems.
//!
//! Channels: `GET /teams/{team}/channels/{channel}/filesFolder` returns the
//! SharePoint folder driveItem, then `GET /drives/{d}/items/{i}/children`
//! lists files. Chats (1:1/group): files live in the sender's OneDrive
//! "Microsoft Teams Chat Files" folder with no filesFolder endpoint, so the
//! list is mined from Graph chat messages: `reference` attachments carry a
//! SharePoint `contentUrl` resolved via `GET /shares/{id}/driveItem`.
//!
//! Auth: existing Graph token (Teams client `/.default`). No scope widening:
//! the Teams desktop app registration already grants Files.Read/Write for
//! delegated flows. Uploads <=4 MB use a single simple PUT; larger files
//! use a resumable upload session (`createUploadSession` + fragment PUTs)
//! with per-fragment progress reports.

use anyhow::{bail, Context, Result};
use serde::Deserialize;

use super::client::TeamsClient;

const CHAT_FILES_FOLDER: &str = "Microsoft Teams Chat Files";
const MAX_SIMPLE_UPLOAD: u64 = 4 * 1024 * 1024;
/// Resumable-upload fragment size (16 x 320 KiB; Graph requires multiples
/// of 320 KiB except the tail).
const UPLOAD_CHUNK: u64 = 5 * 1024 * 1024;

/// Upload progress sink: `(bytes_sent, bytes_total)` after each fragment
/// (simple PUT reports once at completion).
pub type UploadProgress<'a> = dyn Fn(u64, u64) + Sync + 'a;

/// Inclusive `(start, end)` fragment ranges covering `total` bytes in
/// `chunk`-sized fragments with a short tail. Empty for empty files.
pub fn upload_chunk_ranges(total: u64, chunk: u64) -> Vec<(u64, u64)> {
    let chunk = chunk.max(1);
    let mut out = Vec::new();
    let mut start = 0u64;
    while start < total {
        let end = (start + chunk).min(total) - 1;
        out.push((start, end));
        start = end + 1;
    }
    out
}

/// `Content-Range` header value for one fragment (inclusive `end`).
pub fn content_range_value(start: u64, end: u64, total: u64) -> String {
    format!("bytes {}-{}/{}", start, end, total)
}

/// `createUploadSession` body. `replace` matches simple-PUT semantics
/// (same-name uploads overwrite, never fork copies).
pub fn upload_session_body(name: &str) -> serde_json::Value {
    serde_json::json!({
        "item": {
            "@microsoft.graph.conflictBehavior": "replace",
            "name": name,
        }
    })
}

// -- Wire types --

#[derive(Debug, Deserialize)]
struct DriveChildrenResponse {
    value: Vec<DriveItem>,
}

#[derive(Debug, Deserialize)]
struct DriveItem {
    id: String,
    name: Option<String>,
    size: Option<u64>,
    #[serde(rename = "eTag")]
    etag: Option<String>,
    #[serde(rename = "webUrl")]
    web_url: Option<String>,
    #[serde(rename = "webDavUrl")]
    web_dav_url: Option<String>,
    #[serde(rename = "@microsoft.graph.downloadUrl")]
    download_url: Option<String>,
    #[serde(rename = "createdDateTime")]
    created: Option<String>,
    #[serde(rename = "lastModifiedDateTime")]
    modified: Option<String>,
    file: Option<FileFacet>,
    folder: Option<serde_json::Value>,
    #[serde(rename = "parentReference")]
    parent: Option<ParentRef>,
}

#[derive(Debug, Deserialize)]
struct FileFacet {
    #[serde(rename = "mimeType")]
    mime_type: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ParentRef {
    #[serde(rename = "driveId")]
    drive_id: Option<String>,
}

#[cfg(test)]
#[derive(Debug, Deserialize)]
struct ChatMessagesResponse {
    value: Vec<GraphChatMessage>,
}

#[derive(Debug, Deserialize)]
struct GraphChatMessage {
    #[serde(default)]
    from: Option<MessageFrom>,
    #[serde(default)]
    attachments: Vec<GraphAttachment>,
}

#[derive(Debug, Deserialize)]
struct MessageFrom {
    #[serde(default)]
    user: Option<MessageUser>,
}

#[derive(Debug, Deserialize)]
struct MessageUser {
    #[serde(rename = "displayName")]
    display_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GraphAttachment {
    /// The `<attachment id>` the message body references.
    #[serde(default)]
    id: Option<String>,
    #[serde(rename = "contentType")]
    content_type: Option<String>,
    #[serde(rename = "contentUrl")]
    content_url: Option<String>,
    name: Option<String>,
}

// -- Public model --

/// One shared file (driveItem projection for list/upload/download).
pub struct SharedFile {
    pub id: String,
    pub name: String,
    pub size: u64,
    pub mime: Option<String>,
    pub web_url: Option<String>,
    pub download_url: Option<String>,
    pub drive_id: Option<String>,
    pub created: Option<String>,
    pub modified: Option<String>,
    /// Display name of the chat sender (chat path only; None for channels).
    pub sender: Option<String>,
    /// True when the driveItem is a folder (has the `folder` facet).
    /// Folders have no size/mime/download_url; Swift drills in via the
    /// children endpoint (drive_id + id). Always present in core JSON.
    pub is_folder: bool,
    /// Sharing link from createLink (om-i1-links). List paths never fill
    /// it (None); Swift caches the created link per file id after Copy link.
    pub share_url: Option<String>,
    /// File-attachment GUID mined from the driveItem eTag (om-inline-docs):
    /// matches the `<attachment id>` in the message that shared this file,
    /// so embedders render inline doc rows in the bubble. None when the
    /// eTag carries no GUID (channel children often don't; the Shared tab
    /// still lists the file, it just never matches a bubble).
    pub attachment_id: Option<String>,
}

fn shared_from_item(item: DriveItem, sender: Option<String>) -> SharedFile {
    let attachment_id = item.etag.as_deref().and_then(guid_from_etag);
    let is_folder = item.folder.is_some();
    SharedFile {
        id: item.id,
        name: item.name.unwrap_or_else(|| "[unnamed]".to_string()),
        size: item.size.unwrap_or(0),
        mime: item.file.and_then(|f| f.mime_type),
        web_url: item.web_url,
        download_url: item.download_url,
        drive_id: item.parent.and_then(|p| p.drive_id),
        created: item.created,
        modified: item.modified,
        sender,
        is_folder,
        attachment_id,
        share_url: None,
    }
}

/// True when a raw driveItem survives the folders filter: files always
/// pass; folders pass only when `include_folders` is set.
fn keep_item(item: &DriveItem, include_folders: bool) -> bool {
    include_folders || item.folder.is_none()
}

/// Encode a SharePoint sharing URL as a Graph shares id (`u!` + base64url).
/// See https://learn.microsoft.com/graph/api/shares-get
pub fn encode_share_id(url: &str) -> String {
    use base64::Engine;
    let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(url.as_bytes());
    format!("u!{}", b64)
}

/// Minimal path-segment encoder for drive `:/path:/content` addresses.
/// Keeps unreserved chars, encodes the rest (spaces -> %20, etc).
fn encode_segment(s: &str) -> String {
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

/// First GUID (`8-4-4-4-12` hex) in an eTag, the file-attachment id.
/// driveItem eTags embed the attachment GUID (Graph chatMessage-post docs).
fn guid_from_etag(etag: &str) -> Option<String> {
    let bytes = etag.as_bytes();
    if bytes.len() < 36 {
        return None;
    }
    let is_hex = |b: u8| b.is_ascii_hexdigit();
    for start in 0..=bytes.len() - 36 {
        let w = &bytes[start..start + 36];
        if w[8] == b'-' && w[13] == b'-' && w[18] == b'-' && w[23] == b'-'
            && w[..8].iter().all(|&b| is_hex(b))
            && w[9..13].iter().all(|&b| is_hex(b))
            && w[14..18].iter().all(|&b| is_hex(b))
            && w[19..23].iter().all(|&b| is_hex(b))
            && w[24..36].iter().all(|&b| is_hex(b))
        {
            return Some(etag[start..start + 36].to_string());
        }
    }
    None
}

fn sender_of(msg: &GraphChatMessage) -> Option<String> {
    msg.from
        .as_ref()
        .and_then(|f| f.user.as_ref())
        .and_then(|u| u.display_name.clone())
}

/// True when `id` is channel-shaped (`19:...@thread.tacv2`). Chat ids
/// share the `19:` prefix but end `@thread.v2`, so the suffix is the
/// scope discriminator: channels list/upload via the team filesFolder,
/// chats via messages/attachments + the sender's OneDrive chat folder.
/// Unknown shapes return false (chat path first, channel fallback).
pub fn is_channel_id(id: &str) -> bool {
    id.trim().ends_with("@thread.tacv2")
}

// -- List --

/// List shared files for a chat id or a channel id.
///
/// Scope-aware order: channel-shaped ids try the channel filesFolder path
/// first (team scan + `/drives/.../children`), chat-shaped ids the
/// chat-messages/attachments path first (Graph `/me/chats/{id}/messages`
/// + shares resolution); each falls back to the other path when its own
/// fails (unknown id shapes still resolve). Folders are skipped; only
/// file driveItems are returned. Deduplicated by item id.
/// Default shape (stable): same as `_opts` with `include_folders=false`.
pub async fn list_chat_files_data(
    client: &TeamsClient,
    chat_id: &str,
    limit: usize,
) -> Result<Vec<SharedFile>> {
    list_chat_files_data_opts(client, chat_id, limit, false).await
}

/// List shared files, optionally including folders (om-i5-folders).
/// `include_folders=true` keeps folder driveItems in both list paths;
/// each carries `is_folder` so callers can drill in via
/// [`list_folder_children_data`]. Default callers use
/// [`list_chat_files_data`] (folders filtered, shape unchanged).
pub async fn list_chat_files_data_opts(
    client: &TeamsClient,
    chat_id: &str,
    limit: usize,
    include_folders: bool,
) -> Result<Vec<SharedFile>> {
    // §GRAPHSWEEP: no Graph `/me/chats/{id}/messages` route any more — it
    // needs Chat.Read, which the Teams web token lacks (live 403), and for
    // channel ids it was never a valid route. Chats read the chat service,
    // channels (and anything else) the channel files folder; their error
    // is the one surfaced.
    if is_chat_id(chat_id) {
        list_via_chat_service(client, chat_id, limit, include_folders).await
    } else {
        list_via_channel_folder(client, chat_id, limit, include_folders).await
    }
}

/// True when `id` is chat-shaped: group/meeting `19:…@thread.v2`, 1:1
/// `19:…@unq.gbl.spaces`, legacy `@thread.skype`, or the `48:` self and
/// system conversations. Channel ids (`@thread.tacv2`) are not.
pub fn is_chat_id(id: &str) -> bool {
    let id = id.trim();
    id.starts_with("48:")
        || id.starts_with("28:") // OstMac §83: bot 1:1 chats
        || (id.starts_with("19:")
            && ["@thread.v2", "@unq.gbl.spaces", "@thread.skype"].iter().any(|s| id.ends_with(s)))
}

/// Most chat-service history pages the Shared tab walks (200 each).
const CHAT_FILE_PAGES: usize = 5;

/// Chat Shared tab via the chat service: the files messages carry
/// (`properties.files`), newest first, each resolved to its driveItem
/// through `/shares/{id}/driveItem` (Files.ReadWrite.All). A file that
/// will not resolve (deleted, no access) still lists from the message
/// metadata: name, link, sender, time; no drive id (open-only).
async fn list_via_chat_service(
    client: &TeamsClient,
    chat_id: &str,
    limit: usize,
    include_folders: bool,
) -> Result<Vec<SharedFile>> {
    let refs = crate::api::chat::chat_file_refs_data(client, chat_id, limit.max(1), CHAT_FILE_PAGES).await?;
    Ok(resolve_file_refs(client, refs, include_folders).await)
}

/// Chat-service file refs → Shared files: each resolved through
/// `/shares/{id}/driveItem` (share link first, then the object URL);
/// unresolvable refs list from their metadata (open-only). Deduped by
/// driveItem id; each keeps its message attachment id.
async fn resolve_file_refs(
    client: &TeamsClient,
    refs: Vec<crate::api::chat::ChatFileRef>,
    include_folders: bool,
) -> Vec<SharedFile> {
    let mut files = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for r in refs {
        let mut item = None;
        for u in [r.share_url.as_deref(), Some(r.object_url.as_str())].into_iter().flatten() {
            let spath = format!("/shares/{}/driveItem", encode_share_id(u));
            if let Ok(resp) = client.graph_get(&spath).await {
                if let Ok(it) = resp.json::<DriveItem>().await {
                    item = Some(it);
                    break;
                }
            }
        }
        let file = match item {
            Some(it) => {
                if !keep_item(&it, include_folders) || !seen.insert(it.id.clone()) {
                    continue;
                }
                let mut f = shared_from_item(it, r.sender.clone());
                if f.name == "[unnamed]" {
                    f.name = r.name.clone();
                }
                if f.attachment_id.is_none() {
                    f.attachment_id = r.attachment_id.clone();
                }
                f
            }
            None => shared_from_ref(&r),
        };
        files.push(file);
    }
    files
}

/// A chat file that did not resolve to a driveItem, from its message
/// metadata alone (open-in-browser only: no drive id, no size).
fn shared_from_ref(r: &crate::api::chat::ChatFileRef) -> SharedFile {
    SharedFile {
        id: r.attachment_id.clone().unwrap_or_else(|| r.object_url.clone()),
        name: r.name.clone(),
        size: 0,
        mime: None,
        web_url: Some(r.object_url.clone()),
        download_url: None,
        drive_id: None,
        created: r.time.clone(),
        modified: r.time.clone(),
        sender: r.sender.clone(),
        is_folder: false,
        share_url: r.share_url.clone(),
        attachment_id: r.attachment_id.clone(),
    }
}

/// Resolve one message's `reference` attachments to driveItems through
/// `/shares/{id}/driveItem`, paired with each attachment's own id.
/// Unresolvable attachments are skipped (logged); `seen` dedupes by item
/// id across calls.
async fn reference_files(
    client: &TeamsClient,
    msg: &GraphChatMessage,
    include_folders: bool,
    seen: &mut std::collections::HashSet<String>,
) -> Vec<(Option<String>, SharedFile)> {
    let sender = sender_of(msg);
    let mut files = Vec::new();
    for att in &msg.attachments {
        if att.content_type.as_deref() != Some("reference") {
            continue;
        }
        let Some(url) = att.content_url.as_deref().filter(|s| !s.is_empty()) else {
            continue;
        };
        let share_id = encode_share_id(url);
        let spath = format!("/shares/{}/driveItem", share_id);
        let item: DriveItem = match client.graph_get(&spath).await {
            Ok(r) => match r.json().await {
                Ok(it) => it,
                Err(e) => {
                    tracing::warn!("Shares resolve parse failed for {}: {:#}", url, e);
                    continue;
                }
            },
            Err(e) => {
                tracing::warn!("Shares resolve failed for {}: {:#}", url, e);
                continue;
            }
        };
        if !keep_item(&item, include_folders) {
            continue;
        }
        if !seen.insert(item.id.clone()) {
            continue;
        }
        // Fall back to the attachment name when the item omits it.
        let mut file = shared_from_item(item, sender.clone());
        if file.name == "[unnamed]" {
            if let Some(n) = att.name.clone() {
                file.name = n;
            }
        }
        files.push((att.id.clone(), file));
    }
    files
}

// -- One message's files (timeline file chips) --

/// Graph path for one chat message (`team_id` None) or one channel post
/// (`team_id` Some). Ids are path segments: blank ids and ids carrying
/// `/`, `?`, `#` or whitespace are rejected before any network.
pub fn message_path(conversation_id: &str, message_id: &str, team_id: Option<&str>) -> Result<String> {
    let bad = |s: &str| {
        s.is_empty() || s.chars().any(|c| c == '/' || c == '?' || c == '#' || c.is_whitespace())
    };
    let conv = conversation_id.trim();
    let msg = message_id.trim();
    if bad(conv) {
        bail!("invalid conversation id");
    }
    if bad(msg) {
        bail!("invalid message id");
    }
    Ok(match team_id {
        Some(team) => {
            if bad(team.trim()) {
                bail!("invalid team id");
            }
            format!("/teams/{}/channels/{}/messages/{}", team.trim(), conv, msg)
        }
        None => format!("/me/chats/{}/messages/{}", conv, msg),
    })
}

/// §GRAPHSWEEP: which source a message's shared files come from — the
/// chat service for every id except channel posts (`@thread.tacv2`, read
/// under their team with ChannelMessage.Read.All). Pure so tests pin it.
pub fn message_files_via_chat_service(conversation_id: &str) -> bool {
    !is_channel_id(conversation_id)
}

/// The files one message shares: its `reference` attachments resolved
/// to driveItems, each tagged with the attachment's own id (the
/// `<attachment id>` in the body) so a timeline chip matches it even
/// past the first page of the Shared list. Chat ids read the chat
/// service (§83; Graph `/me/chats/{c}/messages/{m}` 403s without
/// Chat.Read), as do all other non-channel ids; channel ids (`@thread.tacv2`) read the
/// channel post under its team. Folders are skipped.
pub async fn list_message_files_data(
    client: &TeamsClient,
    conversation_id: &str,
    message_id: &str,
) -> Result<Vec<SharedFile>> {
    // §GRAPHSWEEP: every non-channel id reads the chat service — the Graph
    // `/me/chats/{c}/messages/{m}` route needs Chat.Read, which the Teams
    // web token lacks (a guaranteed 403).
    if message_files_via_chat_service(conversation_id) {
        // OstMac §83: chats read the chat service (Graph needs Chat.Read).
        message_path(conversation_id, message_id, None)?; // guard ids pre-network
        let refs = crate::api::chat::chat_message_file_refs_data(
            client, conversation_id, message_id, CHAT_FILE_PAGES,
        )
        .await?;
        return Ok(resolve_file_refs(client, refs, false).await);
    }
    let team = if is_channel_id(conversation_id) {
        message_path(conversation_id, message_id, Some("t"))?; // guard ids pre-network
        Some(find_team_for_channel(client, conversation_id.trim()).await?)
    } else {
        None
    };
    let path = message_path(conversation_id, message_id, team.as_deref())?;
    let resp = client.graph_get(&path).await?;
    let msg: GraphChatMessage = resp
        .json()
        .await
        .context("Failed to parse chat message response")?;
    let mut seen = std::collections::HashSet::new();
    Ok(reference_files(client, &msg, false, &mut seen)
        .await
        .into_iter()
        .map(|(att_id, mut file)| {
            if let Some(id) = att_id.filter(|s| !s.trim().is_empty()) {
                file.attachment_id = Some(id);
            }
            file
        })
        .collect())
}

async fn list_via_channel_folder(
    client: &TeamsClient,
    channel_id: &str,
    limit: usize,
    include_folders: bool,
) -> Result<Vec<SharedFile>> {
    let team_id = find_team_for_channel(client, channel_id).await?;
    let fpath = format!("/teams/{}/channels/{}/filesFolder", team_id, channel_id);
    let resp = client.graph_get(&fpath).await?;
    let folder: DriveItem = resp
        .json()
        .await
        .context("Failed to parse filesFolder response")?;
    let drive_id = folder
        .parent
        .as_ref()
        .and_then(|p| p.drive_id.clone())
        .context("filesFolder response missing parent driveId")?;
    let cpath = format!(
        "/drives/{}/items/{}/children?$top={}",
        drive_id,
        folder.id,
        limit.max(1)
    );
    let resp = client.graph_get(&cpath).await?;
    let children: DriveChildrenResponse = resp
        .json()
        .await
        .context("Failed to parse drive children response")?;
    Ok(children
        .value
        .into_iter()
        .filter(|it| keep_item(it, include_folders))
        .map(|it| shared_from_item(it, None))
        .collect())
}

// -- Folder children (om-i5-folders) --

/// Graph path for one folder's children (`drive_id` + folder `item_id`).
pub fn folder_children_path(drive_id: &str, item_id: &str, limit: usize) -> String {
    format!(
        "/drives/{}/items/{}/children?$top={}",
        drive_id,
        item_id,
        limit.max(1)
    )
}

/// List one folder's children by drive+item id. Returns files AND
/// subfolders (no filtering: browsing needs folders visible); each
/// item carries `is_folder`, and folders drill in via this same call
/// with their own id. Ids come from any [`SharedFile`] (`drive_id`+`id`).
pub async fn list_folder_children_data(
    client: &TeamsClient,
    drive_id: &str,
    item_id: &str,
    limit: usize,
) -> Result<Vec<SharedFile>> {
    let path = folder_children_path(drive_id, item_id, limit);
    let resp = client.graph_get(&path).await?;
    let children: DriveChildrenResponse = resp
        .json()
        .await
        .context("Failed to parse drive children response")?;
    Ok(children
        .value
        .into_iter()
        .map(|it| shared_from_item(it, None))
        .collect())
}

// -- Drive recents (top10-files: OneDrive/SharePoint recent files) --

/// Graph path for the signed-in user's recently accessed driveItems.
/// Files-only callers filter folders out (same stable list shape as
/// [`list_chat_files_data`]); shared items arrive as remoteItem facets
/// but parse as plain driveItems (id/name/size present).
pub fn drive_recents_path(limit: usize) -> String {
    format!("/me/drive/recent?$top={}", limit.max(1))
}

/// List recently accessed files across OneDrive + SharePoint (the
/// unified Files surface's third leg: catches drive uploads that no
/// conversation list shows yet, e.g. Q&A exports). Files only;
/// folders are skipped. Server orders by recency; callers re-sort
/// after merging with the chat/channel legs.
pub async fn list_drive_recents_data(
    client: &TeamsClient,
    limit: usize,
) -> Result<Vec<SharedFile>> {
    let path = drive_recents_path(limit);
    let resp = client.graph_get(&path).await?;
    let recent: DriveChildrenResponse = resp
        .json()
        .await
        .context("Failed to parse drive recent response")?;
    Ok(recent
        .value
        .into_iter()
        .filter(|it| keep_item(it, false))
        .map(|it| shared_from_item(it, None))
        .collect())
}

async fn find_team_for_channel(client: &TeamsClient, channel_id: &str) -> Result<String> {
    let teams = crate::api::list_teams_data(client).await?;
    for team in &teams {
        if team.channels.iter().any(|c| c.id == channel_id) {
            return Ok(team.id.clone());
        }
    }
    bail!("No joined team contains channel {}", channel_id)
}

/// List shared files (prints to stdout).
pub async fn list_files(chat_id: &str, limit: usize) -> Result<()> {
    let client = TeamsClient::new().await?;
    let files = list_chat_files_data(&client, chat_id, limit).await?;

    println!("\nShared Files:");
    println!("{:-<60}", "");
    if files.is_empty() {
        println!("  (no shared files found)");
        return Ok(());
    }
    for f in &files {
        if f.is_folder {
            println!("{}/", f.name);
        } else {
            println!("{}", f.name);
        }
        println!("  ID:   {}", f.id);
        if let Some(ref d) = f.drive_id {
            println!("  Drive: {}", d);
        }
        println!("  Size: {} bytes", f.size);
        if let Some(ref m) = f.mime {
            println!("  Type: {}", m);
        }
        if let Some(ref s) = f.sender {
            println!("  From: {}", s);
        }
        if let Some(ref u) = f.web_url {
            println!("  URL:  {}", u);
        }
        println!();
    }
    Ok(())
}

// -- Download --

/// Download one driveItem's content to `dest_path`. Returns bytes written.
pub async fn download_file_data(
    client: &TeamsClient,
    drive_id: &str,
    item_id: &str,
    dest_path: &str,
) -> Result<u64> {
    let path = format!("/drives/{}/items/{}/content", drive_id, item_id);
    let resp = client.graph_get_download(&path).await?;
    let bytes = resp.bytes().await.context("Failed to read file content")?;
    std::fs::write(dest_path, &bytes)
        .with_context(|| format!("Failed to write {}", dest_path))?;
    Ok(bytes.len() as u64)
}

/// Download a shared file by drive+item id (prints to stdout).
pub async fn download_file(drive_id: &str, item_id: &str, dest_path: &str) -> Result<()> {
    let client = TeamsClient::new().await?;
    let n = download_file_data(&client, drive_id, item_id, dest_path).await?;
    println!("Downloaded {} bytes to {}", n, dest_path);
    Ok(())
}

// -- Versions (om-i2-versions: OneDrive/SharePoint version history) --

#[derive(Debug, Deserialize)]
struct VersionsResponse {
    value: Vec<DriveItemVersion>,
}

#[derive(Debug, Deserialize)]
struct DriveItemVersion {
    id: String,
    size: Option<u64>,
    #[serde(rename = "lastModifiedDateTime")]
    modified: Option<String>,
    #[serde(rename = "lastModifiedBy")]
    modified_by: Option<ModifiedBy>,
}

#[derive(Debug, Deserialize)]
struct ModifiedBy {
    user: Option<MessageUser>,
}

/// One file version (driveItemVersion projection for list/restore/download).
pub struct FileVersion {
    pub id: String,
    pub size: u64,
    pub modified: Option<String>,
    pub modified_by: Option<String>,
}

fn version_from_item(item: DriveItemVersion) -> FileVersion {
    FileVersion {
        id: item.id,
        size: item.size.unwrap_or(0),
        modified: item.modified,
        modified_by: item.modified_by.and_then(|b| b.user).and_then(|u| u.display_name),
    }
}

/// List version history for one driveItem, newest first (Graph order).
pub async fn list_file_versions_data(
    client: &TeamsClient,
    drive_id: &str,
    item_id: &str,
) -> Result<Vec<FileVersion>> {
    let path = format!("/drives/{}/items/{}/versions", drive_id, item_id);
    let resp = client.graph_get(&path).await?;
    let body: VersionsResponse = resp
        .json()
        .await
        .context("Failed to parse versions response")?;
    Ok(body.value.into_iter().map(version_from_item).collect())
}

/// Restore one version as current (Graph `restoreVersion` action).
pub async fn restore_file_version_data(
    client: &TeamsClient,
    drive_id: &str,
    item_id: &str,
    version_id: &str,
) -> Result<()> {
    let path = format!(
        "/drives/{}/items/{}/versions/{}/restoreVersion",
        drive_id, item_id, version_id
    );
    client.graph_post(&path, &serde_json::json!({})).await?;
    Ok(())
}

/// Download one old version's content to `dest_path`. Returns bytes written.
pub async fn download_file_version_data(
    client: &TeamsClient,
    drive_id: &str,
    item_id: &str,
    version_id: &str,
    dest_path: &str,
) -> Result<u64> {
    let path = format!(
        "/drives/{}/items/{}/versions/{}/content",
        drive_id, item_id, version_id
    );
    let resp = client.graph_get_download(&path).await?;
    let bytes = resp.bytes().await.context("Failed to read version content")?;
    std::fs::write(dest_path, &bytes)
        .with_context(|| format!("Failed to write {}", dest_path))?;
    Ok(bytes.len() as u64)
}

// -- Upload --

/// Upload a local file to a chat or channel and post it as a `reference`
/// attachment message. Files <=4 MB use one simple PUT; larger files use
/// a resumable upload session. Returns the uploaded item.
pub async fn upload_file_data(
    client: &TeamsClient,
    chat_id: &str,
    local_path: &str,
) -> Result<SharedFile> {
    upload_file_data_with_progress(client, chat_id, local_path, None).await
}

/// [`upload_file_data`] with per-fragment progress reports
/// (`(bytes_sent, bytes_total)`; simple PUT reports once at completion).
pub async fn upload_file_data_with_progress(
    client: &TeamsClient,
    chat_id: &str,
    local_path: &str,
    progress: Option<&UploadProgress<'_>>,
) -> Result<SharedFile> {
    let cmid = crate::api::new_client_message_id();
    upload_file_data_idem(client, chat_id, local_path, progress, &cmid, false).await
}

/// OstMac §106: [`upload_file_data_with_progress`] with a caller-owned
/// `clientmessageid` for the chat file post (a Retry reuses it).
/// `verify_first` (retries): when the chat already carries a message with
/// that id, the (idempotent, replace) upload runs but the post is skipped
/// — a post whose answer was lost is never posted twice. Channel posts
/// use the same chat-service post + verify (FIXPACK F1).
pub async fn upload_file_data_idem(
    client: &TeamsClient,
    chat_id: &str,
    local_path: &str,
    progress: Option<&UploadProgress<'_>>,
    client_message_id: &str,
    verify_first: bool,
) -> Result<SharedFile> {
    let bytes = std::fs::read(local_path)
        .with_context(|| format!("Failed to read {}", local_path))?;
    let report = |sent: u64, total: u64| {
        if let Some(cb) = progress {
            cb(sent, total);
        }
    };
    let filename = std::path::Path::new(local_path)
        .file_name()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty())
        .context("Local path has no file name")?;

    // Channel-shaped ids upload to the channel folder; chat-shaped ids go
    // straight to the sender's OneDrive chat-files folder with no team scan
    // (the scan costs joinedTeams + one channels call per team).
    if is_channel_id(chat_id) {
        let team_id = find_team_for_channel(client, chat_id).await?;
        upload_to_channel(client, &team_id, chat_id, filename, bytes, &report, client_message_id, verify_first).await
    } else {
        upload_to_chat(client, chat_id, filename, bytes, &report, client_message_id, verify_first).await
    }
}

async fn upload_to_chat(
    client: &TeamsClient,
    chat_id: &str,
    filename: &str,
    bytes: Vec<u8>,
    report: &impl Fn(u64, u64),
    cmid: &str,
    verify_first: bool,
) -> Result<SharedFile> {
    let folder = encode_segment(CHAT_FILES_FOLDER);
    let fname = encode_segment(filename);
    let item = if bytes.len() as u64 > MAX_SIMPLE_UPLOAD {
        let spath = format!("/me/drive/root:/{}/{}:/createUploadSession", folder, fname);
        upload_via_session(client, &spath, filename, &bytes, report).await?
    } else {
        let upath = format!("/me/drive/root:/{}/{}:/content", folder, fname);
        let total = bytes.len() as u64;
        let resp = client
            .graph_put_bytes(&upath, bytes, "application/octet-stream")
            .await?;
        report(total, total);
        resp.json()
            .await
            .context("Failed to parse upload response")?
    };
    // §84: the chat service leads (skypetoken; Graph chat-message POST
    // needs ChatMessage.Send, which the Teams web token may lack).
    // OstMac §106/§FIXPACK-F1: the post carries a clientmessageid and is
    // settled by [`post_file_message_idem`] (verify before any fallback).
    post_file_message_idem(
        client,
        chat_id,
        &item,
        filename,
        cmid,
        verify_first,
        &format!("/me/chats/{}/messages", chat_id),
    )
    .await?;
    Ok(shared_from_item(item, None))
}

/// OstMac FIXPACK F1: what to do after the chat-service file post
/// returned an error. `landed` is the by-clientmessageid lookup:
/// `Some(true)` found, `Some(false)` looked and absent, `None` lookup failed.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum FilePostNext {
    /// Teams already has the message: done, never post again.
    Landed,
    /// Teams definitely rejected it and it is absent: Graph reference post.
    Graph,
    /// Cannot tell (timeout / 5xx / lookup failed): stop, surface an error;
    /// the Swift Retry verifies by the same id before posting again.
    Unknown,
}

/// A rejection the server answered (HTTP 4xx): the message was not accepted.
/// Timeouts, transport errors and 5xx are ambiguous (Teams may have accepted).
pub(crate) fn is_definite_rejection(err: &str) -> bool {
    let e = err.trim_start();
    e.starts_with("HTTP 4") || e.starts_with("401 ")
}

pub(crate) fn file_post_next(err: &str, landed: Option<bool>) -> FilePostNext {
    match landed {
        Some(true) => FilePostNext::Landed,
        Some(false) if is_definite_rejection(err) => FilePostNext::Graph,
        _ => FilePostNext::Unknown,
    }
}

/// Post the uploaded file into a chat or channel through the chat service
/// with `cmid` as the idempotency key. `verify_first` (Retry): a message
/// already carrying `cmid` means the earlier post landed, so nothing is
/// posted. After a failed post the lookup by `cmid` runs (three tries with a
/// short wait when the failure is ambiguous, for indexing lag) before any
/// Graph fallback; an ambiguous failure with no proof of absence is an error,
/// never a second post. Used for chats and channels alike.
async fn post_file_message_idem(
    client: &TeamsClient,
    chat_id: &str,
    item: &DriveItem,
    filename: &str,
    cmid: &str,
    verify_first: bool,
    graph_path: &str,
) -> Result<()> {
    if verify_first {
        if let Ok(Some(_)) = crate::api::find_message_by_client_id(client, chat_id, cmid).await {
            return Ok(());
        }
    }
    let svc = async {
        let mut body = chat_service_file_body_for(item, filename)?;
        body["clientmessageid"] = serde_json::json!(cmid);
        let url = format!("{}/v1/users/ME/conversations/{}/messages", client.chat_service_url(), chat_id);
        client.chat_post(&url, &body).await?;
        Ok::<_, anyhow::Error>(())
    }
    .await;
    let e = match svc {
        Ok(()) => return Ok(()),
        Err(e) => e,
    };
    let msg = format!("{:#}", e);
    let tries = if is_definite_rejection(&msg) { 1 } else { 3 };
    let mut landed = None;
    for i in 0..tries {
        if i > 0 {
            tokio::time::sleep(std::time::Duration::from_millis(1200)).await;
        }
        landed = match crate::api::find_message_by_client_id(client, chat_id, cmid).await {
            Ok(Some(_)) => Some(true),
            Ok(None) => Some(false),
            Err(_) => None,
        };
        if landed == Some(true) {
            break;
        }
    }
    match file_post_next(&msg, landed) {
        FilePostNext::Landed => Ok(()),
        FilePostNext::Graph => {
            tracing::debug!("chat-service file post rejected, trying Graph: {}", msg);
            post_reference_message(client, graph_path, item, filename)
                .await
                .map_err(|g| g.context(format!("chat-service file post also failed: {}", msg)))
        }
        FilePostNext::Unknown => bail!(
            "file post state unknown ({}); not posted again, Retry checks first",
            msg
        ),
    }
}

async fn upload_to_channel(
    client: &TeamsClient,
    team_id: &str,
    channel_id: &str,
    filename: &str,
    bytes: Vec<u8>,
    report: &impl Fn(u64, u64),
    cmid: &str,
    verify_first: bool,
) -> Result<SharedFile> {
    let fpath = format!("/teams/{}/channels/{}/filesFolder", team_id, channel_id);
    let resp = client.graph_get(&fpath).await?;
    let folder: DriveItem = resp
        .json()
        .await
        .context("Failed to parse filesFolder response")?;
    let drive_id = folder
        .parent
        .as_ref()
        .and_then(|p| p.drive_id.clone())
        .context("filesFolder response missing parent driveId")?;
    let fname = encode_segment(filename);
    let item = if bytes.len() as u64 > MAX_SIMPLE_UPLOAD {
        let spath = format!(
            "/drives/{}/items/{}:/{}:/createUploadSession",
            drive_id, folder.id, fname
        );
        upload_via_session(client, &spath, filename, &bytes, report).await?
    } else {
        let upath = format!(
            "/drives/{}/items/{}:/{}:/content",
            drive_id, folder.id, fname
        );
        let total = bytes.len() as u64;
        let resp = client
            .graph_put_bytes(&upath, bytes, "application/octet-stream")
            .await?;
        report(total, total);
        resp.json()
            .await
            .context("Failed to parse upload response")?
    };
    // OstMac FIXPACK F1: channel posts use the same idempotent chat-service
    // post (clientmessageid + verify) as chats; Graph only on a proven rejection.
    post_file_message_idem(
        client,
        channel_id,
        &item,
        filename,
        cmid,
        verify_first,
        &format!("/teams/{}/channels/{}/messages", team_id, channel_id),
    )
    .await?;
    Ok(shared_from_item(item, None))
}

#[derive(Debug, Deserialize)]
struct UploadSessionResponse {
    #[serde(rename = "uploadUrl")]
    upload_url: String,
}

/// Resumable upload: create the session, PUT fragments sequentially
/// (reporting `(sent, total)` after each), return the final driveItem.
/// Non-final fragments answer 202; the last answers 200/201 with the item.
async fn upload_via_session(
    client: &TeamsClient,
    session_path: &str,
    filename: &str,
    bytes: &[u8],
    report: &impl Fn(u64, u64),
) -> Result<DriveItem> {
    let resp = client
        .graph_post(session_path, &upload_session_body(filename))
        .await?;
    let session: UploadSessionResponse = resp
        .json()
        .await
        .context("Failed to parse createUploadSession response")?;
    let total = bytes.len() as u64;
    let mut last: Option<DriveItem> = None;
    for (start, end) in upload_chunk_ranges(total, UPLOAD_CHUNK) {
        let resp = client
            .drive_session_put(
                &session.upload_url,
                &bytes[start as usize..=end as usize],
                start,
                end,
                total,
            )
            .await?;
        report(end + 1, total);
        if resp.status().is_success() && resp.status() != reqwest::StatusCode::ACCEPTED {
            last = Some(
                resp.json()
                    .await
                    .context("Failed to parse session-upload response")?,
            );
        }
    }
    last.context("Upload session finished without a driveItem response")
}

fn reference_attachment(item: &DriveItem, filename: &str) -> Result<serde_json::Value> {
    let etag = item.etag.as_deref().unwrap_or("");
    let attach_id =
        guid_from_etag(etag).with_context(|| format!("Upload response eTag has no GUID: {:?}", etag))?;
    let content_url = item
        .web_dav_url
        .clone()
        .or_else(|| item.web_url.clone())
        .context("Upload response has no webDavUrl/webUrl")?;
    Ok(serde_json::json!({
        "id": attach_id,
        "contentType": "reference",
        "contentUrl": content_url,
        "name": filename,
    }))
}

/// SharePoint site root of a file URL (`…/personal/<u>/` or
/// `…/sites/<s>/`), else the origin + `/`. Pure.
pub fn file_base_url(object_url: &str) -> String {
    let (scheme, rest) = object_url.split_once("://").unwrap_or(("https", object_url));
    let mut parts = rest.split('/');
    let host = parts.next().unwrap_or("");
    let segs: Vec<&str> = parts.collect();
    match segs.first() {
        Some(&kind) if (kind == "personal" || kind == "sites" || kind == "teams") && segs.len() > 2 => {
            format!("{}://{}/{}/{}/", scheme, host, kind, segs[1])
        }
        _ => format!("{}://{}/", scheme, host),
    }
}

/// OstMac §84: chat-service POST body for a file message, the shape the
/// Teams web client sends and `parse_chat_file_refs` reads back:
/// `properties.files` is a JSON *string* of one
/// `http://schema.skype.com/File` entry (`id`/`itemid` = the SharePoint
/// unique id from the upload eTag, `objectUrl` = the file itself). The
/// visible content is the file name (never an empty bubble). Pure.
pub fn chat_service_file_body(attach_id: &str, object_url: &str, filename: &str) -> serde_json::Value {
    let ext = filename.rsplit_once('.').map(|(_, e)| e.to_lowercase()).unwrap_or_default();
    let base = file_base_url(object_url);
    let file = serde_json::json!({
        "@type": "http://schema.skype.com/File",
        "version": 2,
        "id": attach_id,
        "baseUrl": base,
        "type": ext,
        "title": filename,
        "state": "active",
        "objectUrl": object_url,
        "providerData": "",
        "itemid": attach_id,
        "fileName": filename,
        "fileType": ext,
        "fileInfo": {
            "itemId": null,
            "fileUrl": object_url,
            "siteUrl": base,
            "serverRelativeUrl": "",
            "shareUrl": null,
            "shareId": null
        },
        "botFileProperties": {},
        "permissionScope": "users",
        "filePreview": {},
        "fileChicletState": {"serviceName": "p2p", "state": "active"}
    });
    serde_json::json!({
        "content": format!("<p>{}</p>", html_escape_text(filename)),
        "messagetype": "RichText/Html",
        "contenttype": "text",
        "properties": {"files": serde_json::Value::Array(vec![file]).to_string()}
    })
}

fn html_escape_text(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

fn chat_service_file_body_for(item: &DriveItem, filename: &str) -> Result<serde_json::Value> {
    let attachment = reference_attachment(item, filename)?;
    let id = attachment["id"].as_str().unwrap_or("");
    let url = attachment["contentUrl"].as_str().unwrap_or("");
    Ok(chat_service_file_body(id, url, filename))
}

async fn post_reference_message(
    client: &TeamsClient,
    path: &str,
    item: &DriveItem,
    filename: &str,
) -> Result<()> {
    let attachment = reference_attachment(item, filename)?;
    let body = serde_json::json!({
        "body": { "contentType": "html", "content": format!("<attachment id=\"{}\"></attachment>", attachment["id"].as_str().unwrap_or("")) },
        "attachments": [attachment],
    });
    client.graph_post(path, &body).await?;
    Ok(())
}

/// Upload a local file (streams `%` progress, prints to stdout).
pub async fn upload_file(chat_id: &str, local_path: &str) -> Result<()> {
    use std::io::Write;
    let client = TeamsClient::new().await?;
    let progress = |sent: u64, total: u64| {
        let pct = if total == 0 { 100 } else { sent * 100 / total };
        eprint!("\rUploading {}% ({}/{})", pct, sent, total);
        let _ = std::io::stderr().flush();
    };
    let file = upload_file_data_with_progress(&client, chat_id, local_path, Some(&progress)).await?;
    eprintln!();
    println!("Uploaded {} ({} bytes, id {})", file.name, file.size, file.id);
    Ok(())
}

// -- Sharing links (om-i1-links) --

/// A view-only sharing link for one driveItem (Graph createLink).
pub struct SharedLink {
    pub url: String,
    pub scope: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CreateLinkResponse {
    link: Option<CreateLinkInner>,
}

#[derive(Debug, Deserialize)]
struct CreateLinkInner {
    #[serde(rename = "webUrl")]
    web_url: Option<String>,
    scope: Option<String>,
}

/// Normalize a createLink scope (the perms surface): `anonymous` (anyone
/// with the link) or `organization` (org-only). Blank/unknown input falls
/// back to `organization` (least privilege). Case-insensitive; `anyone`
/// is accepted as an alias for `anonymous`.
pub fn normalize_link_scope(scope: &str) -> &'static str {
    match scope.trim().to_lowercase().as_str() {
        "anonymous" | "anyone" => "anonymous",
        _ => "organization",
    }
}

/// POST body for createLink (view-only link; edit links not offered).
pub fn create_link_body(scope: &str) -> serde_json::Value {
    serde_json::json!({"type": "view", "scope": normalize_link_scope(scope)})
}

/// Graph path for createLink on one driveItem.
pub fn create_link_path(drive_id: &str, item_id: &str) -> String {
    format!("/drives/{}/items/{}/createLink", drive_id, item_id)
}

/// Pull the shareable URL out of a Graph createLink response body.
pub fn parse_create_link(body: &serde_json::Value) -> Result<SharedLink> {
    let resp: CreateLinkResponse =
        serde_json::from_value(body.clone()).context("Failed to parse createLink response")?;
    let inner = resp
        .link
        .context("createLink response has no link object")?;
    let url = inner
        .web_url
        .filter(|s| !s.is_empty())
        .context("createLink response link has no webUrl")?;
    Ok(SharedLink {
        url,
        scope: inner.scope,
    })
}

/// Create (or fetch the existing) view-only sharing link for one
/// driveItem. Idempotent server-side: the same scope returns the same
/// link. `scope` is normalized via [`normalize_link_scope`].
pub async fn create_link_data(
    client: &TeamsClient,
    drive_id: &str,
    item_id: &str,
    scope: &str,
) -> Result<SharedLink> {
    let path = create_link_path(drive_id, item_id);
    let body = create_link_body(scope);
    let resp = client.graph_post(&path, &body).await?;
    let value: serde_json::Value = resp
        .json()
        .await
        .context("Failed to read createLink response")?;
    parse_create_link(&value)
}

/// Create a sharing link (prints the URL to stdout).
pub async fn create_link(drive_id: &str, item_id: &str, scope: &str) -> Result<()> {
    let client = TeamsClient::new().await?;
    let link = create_link_data(&client, drive_id, item_id, scope).await?;
    println!("{}", link.url);
    Ok(())
}

// -- Manage (om-i3-manage): rename/move/copy/delete driveItems --

/// Graph path of one driveItem.
pub fn drive_item_path(drive_id: &str, item_id: &str) -> String {
    format!("/drives/{}/items/{}", drive_id, item_id)
}

/// PATCH body renaming an item (same-folder rename).
pub fn rename_body(new_name: &str) -> serde_json::Value {
    serde_json::json!({ "name": new_name })
}

/// Graph path of a drive's root folder (id only).
pub fn drive_root_path(drive_id: &str) -> String {
    format!("/drives/{}/root?$select=id", drive_id)
}

/// Graph rejects `"id": "root"` in a move/copy parentReference: the
/// alias resolves to the root folder's real id. Other ids pass through.
async fn resolve_folder_id(client: &TeamsClient, drive_id: &str, folder_id: &str) -> Result<String> {
    if folder_id != "root" {
        return Ok(folder_id.to_string());
    }
    let resp = client.graph_get(&drive_root_path(drive_id)).await?;
    let root: serde_json::Value = resp.json().await.context("Failed to parse drive root")?;
    match root.get("id").and_then(|v| v.as_str()) {
        Some(id) if !id.is_empty() => Ok(id.to_string()),
        _ => bail!("Drive root has no id"),
    }
}

/// PATCH body moving an item to another folder (same drive).
pub fn move_body(dest_folder_id: &str) -> serde_json::Value {
    serde_json::json!({ "parentReference": { "id": dest_folder_id } })
}

/// POST body copying an item to another folder (same drive).
/// `new_name` renames the copy; None keeps the source name.
pub fn copy_body(
    drive_id: &str,
    dest_folder_id: &str,
    new_name: Option<&str>,
) -> serde_json::Value {
    let parent = serde_json::json!({ "driveId": drive_id, "id": dest_folder_id });
    match new_name {
        Some(n) => serde_json::json!({ "parentReference": parent, "name": n }),
        None => serde_json::json!({ "parentReference": parent }),
    }
}

/// Rename one driveItem (PATCH name). Returns the updated item.
pub async fn rename_file_data(
    client: &TeamsClient,
    drive_id: &str,
    item_id: &str,
    new_name: &str,
) -> Result<SharedFile> {
    if new_name.trim().is_empty() {
        bail!("New name is empty");
    }
    let path = drive_item_path(drive_id, item_id);
    let resp = client.graph_patch(&path, &rename_body(new_name)).await?;
    let item: DriveItem = resp
        .json()
        .await
        .context("Failed to parse rename response")?;
    Ok(shared_from_item(item, None))
}

/// Move one driveItem to another folder in the same drive (PATCH
/// parentReference). Returns the updated item.
pub async fn move_file_data(
    client: &TeamsClient,
    drive_id: &str,
    item_id: &str,
    dest_folder_id: &str,
) -> Result<SharedFile> {
    if dest_folder_id.trim().is_empty() {
        bail!("Destination folder id is empty");
    }
    let dest = resolve_folder_id(client, drive_id, dest_folder_id).await?;
    let path = drive_item_path(drive_id, item_id);
    let resp = client.graph_patch(&path, &move_body(&dest)).await?;
    let item: DriveItem = resp.json().await.context("Failed to parse move response")?;
    Ok(shared_from_item(item, None))
}

/// Copy one driveItem to another folder in the same drive (async on the
/// server: Graph answers 202 + a `Location` monitor URL). Returns the
/// monitor URL, or "" when the server omits it.
pub async fn copy_file_data(
    client: &TeamsClient,
    drive_id: &str,
    item_id: &str,
    dest_folder_id: &str,
    new_name: Option<&str>,
) -> Result<String> {
    if dest_folder_id.trim().is_empty() {
        bail!("Destination folder id is empty");
    }
    let dest = resolve_folder_id(client, drive_id, dest_folder_id).await?;
    let path = format!("{}/copy", drive_item_path(drive_id, item_id));
    let resp = client
        .graph_post(&path, &copy_body(drive_id, &dest, new_name))
        .await?;
    Ok(resp
        .headers()
        .get(reqwest::header::LOCATION)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string())
}

/// Delete one driveItem (DELETE; Graph answers 204, no body).
pub async fn delete_file_data(client: &TeamsClient, drive_id: &str, item_id: &str) -> Result<()> {
    let path = drive_item_path(drive_id, item_id);
    client.graph_delete(&path).await?;
    Ok(())
}

#[cfg(test)]
mod chat_file_send_tests {
    use super::*;

    #[test]
    fn chat_service_file_body_round_trips_through_the_reader() {
        let url = "https://contoso-my.sharepoint.com/personal/a_contoso_com/Documents/Microsoft Teams Chat Files/Q3 <Plan>.docx";
        let b = chat_service_file_body("0f1e2d3c-aaaa-bbbb-cccc-000000000001", url, "Q3 <Plan>.docx");
        assert_eq!(b["messagetype"], "RichText/Html");
        assert_eq!(b["content"], "<p>Q3 &lt;Plan&gt;.docx</p>");
        // files travels as a JSON string, like the Teams web client.
        let files: serde_json::Value = serde_json::from_str(b["properties"]["files"].as_str().unwrap()).unwrap();
        let f = &files[0];
        assert_eq!(f["@type"], "http://schema.skype.com/File");
        assert_eq!(f["id"], f["itemid"]);
        assert_eq!(f["fileType"], "docx");
        assert_eq!(f["baseUrl"], "https://contoso-my.sharepoint.com/personal/a_contoso_com/");
        assert_eq!(f["fileInfo"]["fileUrl"], url);
        // The §83 reader sees exactly one file with this id and name.
        let page = serde_json::json!({"messages": [{"id": "1", "properties": b["properties"].clone()}]});
        let (refs, _) = crate::api::chat::parse_chat_file_refs(&page);
        assert_eq!(refs.len(), 1);
        assert_eq!(refs[0].name, "Q3 <Plan>.docx");
        assert_eq!(refs[0].object_url, url);
        assert_eq!(refs[0].attachment_id.as_deref(), Some("0f1e2d3c-aaaa-bbbb-cccc-000000000001"));
        assert_eq!(file_base_url("https://h.sharepoint.com/sites/Eng/Shared Documents/x.pdf"), "https://h.sharepoint.com/sites/Eng/");
        assert_eq!(file_base_url("https://h/x.pdf"), "https://h/");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn share_id_roundtrips_via_url_safe_base64() {
        use base64::Engine;
        let url = "https://contoso.sharepoint.com/personal/a_b/Documents/file.docx";
        let id = encode_share_id(url);
        assert!(id.starts_with("u!"));
        let decoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(&id[2..])
            .unwrap();
        assert_eq!(String::from_utf8(decoded).unwrap(), url);
    }

    #[test]
    fn segment_encoding_keeps_unreserved() {
        assert_eq!(encode_segment("aB09-_.~"), "aB09-_.~");
        assert_eq!(encode_segment("a b/c"), "a%20b%2Fc");
        assert_eq!(encode_segment("Microsoft Teams Chat Files"), "Microsoft%20Teams%20Chat%20Files");
    }

    #[test]
    fn guid_scan_finds_first_guid() {
        let etag = "\"c:{3F2504E0-4F89-11D3-9A0C-0305E82C3301},1\"";
        assert_eq!(
            guid_from_etag(etag).as_deref(),
            Some("3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        );
        assert_eq!(guid_from_etag("no-guid-here"), None);
        assert_eq!(guid_from_etag("short"), None);
        // Lowercase hex also matches.
        assert_eq!(
            guid_from_etag("x550e8400-e29b-41d4-a716-446655440000y").as_deref(),
            Some("550e8400-e29b-41d4-a716-446655440000")
        );
    }

    #[test]
    fn drive_children_parse_skips_folders() {
        let body: DriveChildrenResponse = serde_json::from_str(
            r#"{"value":[
                {"id":"f1","name":"a.pdf","size":12,"file":{"mimeType":"application/pdf"},
                 "webUrl":"https://w/a","@microsoft.graph.downloadUrl":"https://d/a",
                 "parentReference":{"driveId":"D1"}},
                {"id":"dir1","name":"sub","folder":{}}
            ]}"#,
        )
        .unwrap();
        let files: Vec<SharedFile> = body
            .value
            .into_iter()
            .filter(|it| it.folder.is_none())
            .map(|it| shared_from_item(it, None))
            .collect();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].id, "f1");
        assert_eq!(files[0].name, "a.pdf");
        assert_eq!(files[0].size, 12);
        assert_eq!(files[0].mime.as_deref(), Some("application/pdf"));
        assert_eq!(files[0].drive_id.as_deref(), Some("D1"));
        assert_eq!(files[0].download_url.as_deref(), Some("https://d/a"));
    }

    #[test]
    fn keep_item_filters_folders_by_default() {
        let file: DriveItem =
            serde_json::from_str(r#"{"id":"f1","name":"a.pdf","file":{}}"#).unwrap();
        let folder: DriveItem =
            serde_json::from_str(r#"{"id":"d1","name":"sub","folder":{}}"#).unwrap();
        assert!(keep_item(&file, false));
        assert!(keep_item(&file, true));
        assert!(!keep_item(&folder, false));
        assert!(keep_item(&folder, true));
    }

    #[test]
    fn shared_from_item_marks_folder_facet() {
        let folder: DriveItem =
            serde_json::from_str(r#"{"id":"d1","name":"sub","folder":{"childCount":3}}"#)
                .unwrap();
        let f = shared_from_item(folder, None);
        assert!(f.is_folder);
        assert_eq!(f.name, "sub");
        assert_eq!(f.size, 0);
        assert_eq!(f.mime, None);
        let file: DriveItem =
            serde_json::from_str(r#"{"id":"f1","name":"a.pdf","file":{"mimeType":"application/pdf"}}"#)
                .unwrap();
        assert!(!shared_from_item(file, None).is_folder);
    }

    #[test]
    fn folder_children_path_shape() {
        assert_eq!(
            folder_children_path("D1", "root", 20),
            "/drives/D1/items/root/children?$top=20"
        );
        assert_eq!(
            folder_children_path("D1", "abc", 0),
            "/drives/D1/items/abc/children?$top=1"
        );
    }

    #[test]
    fn drive_recents_path_shape() {
        assert_eq!(drive_recents_path(20), "/me/drive/recent?$top=20");
        assert_eq!(drive_recents_path(0), "/me/drive/recent?$top=1");
    }

    #[test]
    fn drive_recents_parse_skips_folders() {
        // Recent endpoint shape: same driveItem collection; folders
        // (recently touched dirs) drop so the list stays files-only.
        let body: DriveChildrenResponse = serde_json::from_str(
            r#"{"value":[
                {"id":"r1","name":"qna-export.csv","size":99,
                 "file":{"mimeType":"text/csv"},
                 "lastModifiedDateTime":"2026-09-25T10:00:00Z",
                 "parentReference":{"driveId":"D9"}},
                {"id":"dir9","name":"touched-dir","folder":{}}
            ]}"#,
        )
        .unwrap();
        let files: Vec<SharedFile> = body
            .value
            .into_iter()
            .filter(|it| keep_item(it, false))
            .map(|it| shared_from_item(it, None))
            .collect();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].id, "r1");
        assert_eq!(files[0].drive_id.as_deref(), Some("D9"));
        assert!(!files[0].is_folder);
    }

    #[test]
    fn children_parse_keeps_folders_and_files() {
        // Children endpoint never filters: subfolders stay visible.
        let body: DriveChildrenResponse = serde_json::from_str(
            r#"{"value":[
                {"id":"dir1","name":"sub","folder":{},"parentReference":{"driveId":"D1"}},
                {"id":"f1","name":"a.pdf","size":12,"file":{"mimeType":"application/pdf"},
                 "parentReference":{"driveId":"D1"}}
            ]}"#,
        )
        .unwrap();
        let files: Vec<SharedFile> =
            body.value.into_iter().map(|it| shared_from_item(it, None)).collect();
        assert_eq!(files.len(), 2);
        assert!(files[0].is_folder);
        assert_eq!(files[0].drive_id.as_deref(), Some("D1"));
        assert!(!files[1].is_folder);
        assert_eq!(files[1].size, 12);
    }

    #[test]
    fn chat_message_attachments_filter_reference_only() {
        let body: ChatMessagesResponse = serde_json::from_str(
            r#"{"value":[
                {"from":{"user":{"displayName":"A Uzer"}},
                 "attachments":[
                   {"contentType":"reference","contentUrl":"https://sp/f","name":"f.docx"},
                   {"contentType":"messageReference","contentUrl":"https://x","name":"quote"}
                 ]},
                {"from":{},"attachments":[]}
            ]}"#,
        )
        .unwrap();
        assert_eq!(body.value.len(), 2);
        assert_eq!(sender_of(&body.value[0]).as_deref(), Some("A Uzer"));
        let refs: Vec<&GraphAttachment> = body.value[0]
            .attachments
            .iter()
            .filter(|a| a.content_type.as_deref() == Some("reference"))
            .collect();
        assert_eq!(refs.len(), 1);
        assert_eq!(refs[0].content_url.as_deref(), Some("https://sp/f"));
        assert!(sender_of(&body.value[1]).is_none());
    }

    #[test]
    fn reference_attachment_prefers_web_dav() {
        let item: DriveItem = serde_json::from_str(
            r#"{"id":"i1","eTag":"\"c:{550E8400-E29B-41D4-A716-446655440000},2\"",
                "webUrl":"https://web/f","webDavUrl":"https://dav/f"}"#,
        )
        .unwrap();
        let v = reference_attachment(&item, "f").unwrap();
        assert_eq!(v["id"], "550E8400-E29B-41D4-A716-446655440000");
        assert_eq!(v["contentType"], "reference");
        assert_eq!(v["contentUrl"], "https://dav/f");
        assert_eq!(v["name"], "f");
    }

    #[test]
    fn reference_attachment_requires_guid() {
        let item: DriveItem = serde_json::from_str(r#"{"id":"i1","eTag":"nope"}"#).unwrap();
        assert!(reference_attachment(&item, "f").is_err());
    }

    #[test]
    fn shared_file_carries_attachment_guid_from_etag() {
        // Chat-file eTags embed the attachment GUID: the bubble-match key.
        let with: DriveItem = serde_json::from_str(
            r#"{"id":"i1","name":"f.docx","eTag":"\"c:{550E8400-E29B-41D4-A716-446655440000},2\""}"#,
        )
        .unwrap();
        let f = shared_from_item(with, Some("A Uzer".to_string()));
        assert_eq!(
            f.attachment_id.as_deref(),
            Some("550E8400-E29B-41D4-A716-446655440000")
        );
        // No GUID (channel children, missing eTag): None, never fatal.
        let without: DriveItem =
            serde_json::from_str(r#"{"id":"i2","name":"g.docx","eTag":"nope"}"#).unwrap();
        assert_eq!(shared_from_item(without, None).attachment_id, None);
        let missing: DriveItem =
            serde_json::from_str(r#"{"id":"i3","name":"h.docx"}"#).unwrap();
        assert_eq!(shared_from_item(missing, None).attachment_id, None);
    }

    #[test]
    fn link_scope_normalizes_to_least_privilege() {
        assert_eq!(normalize_link_scope("organization"), "organization");
        assert_eq!(normalize_link_scope("  Organization "), "organization");
        assert_eq!(normalize_link_scope("anonymous"), "anonymous");
        assert_eq!(normalize_link_scope("Anyone"), "anonymous");
        assert_eq!(normalize_link_scope(""), "organization");
        assert_eq!(normalize_link_scope("edit"), "organization");
    }

    #[test]
    fn link_body_is_view_only_with_scope() {
        assert_eq!(
            create_link_body("anonymous"),
            serde_json::json!({"type": "view", "scope": "anonymous"})
        );
        assert_eq!(
            create_link_body("bogus"),
            serde_json::json!({"type": "view", "scope": "organization"})
        );
    }

    /// §GRAPHSWEEP: only channel posts read Graph; every other id (chats,
    /// meetings, bots, odd shapes) reads the chat service, never Graph
    /// `/me/chats/{c}/messages/{m}` (Chat.Read is not on the Teams token).
    #[test]
    fn message_files_route_off_graph_chats() {
        for id in ["19:a@thread.v2", "19:a_b@unq.gbl.spaces", "48:notes", "28:bot", "19:x@thread.other", " 19:y@thread.skype "] {
            assert!(message_files_via_chat_service(id), "{}", id);
        }
        assert!(!message_files_via_chat_service("19:c@thread.tacv2"));
        assert!(!message_files_via_chat_service(" 19:c@thread.tacv2 "));
    }

    #[test]
    fn message_paths_and_attachment_ids() {
        assert_eq!(message_path("19:a@thread.v2", "1727", None).unwrap(),
                   "/me/chats/19:a@thread.v2/messages/1727");
        assert_eq!(message_path("19:c@thread.tacv2", "1727", Some("t1")).unwrap(),
                   "/teams/t1/channels/19:c@thread.tacv2/messages/1727");
        for bad in ["", " ", "a/b", "a?b", "a#b", "a b"] {
            assert!(message_path(bad, "1727", None).is_err());
            assert!(message_path("19:a@thread.v2", bad, None).is_err());
        }
        let msg: GraphChatMessage = serde_json::from_str(
            r#"{"attachments":[{"id":"6D2A-1","contentType":"reference","contentUrl":"https://x/a.pdf","name":"a.pdf"}]}"#,
        ).unwrap();
        assert_eq!(msg.attachments[0].id.as_deref(), Some("6D2A-1"));
    }

    #[test]
    fn manage_paths_and_bodies() {
        // om-i3-manage: driveItem PATCH/DELETE manage shapes.
        assert_eq!(drive_item_path("D1", "I1"), "/drives/D1/items/I1");
        assert_eq!(drive_root_path("D1"), "/drives/D1/root?$select=id");
        assert_eq!(
            rename_body("plan v2.docx"),
            serde_json::json!({"name": "plan v2.docx"})
        );
        assert_eq!(
            move_body("F9"),
            serde_json::json!({"parentReference": {"id": "F9"}})
        );
        assert_eq!(
            copy_body("D1", "F9", Some("copy.docx")),
            serde_json::json!({"parentReference": {"driveId": "D1", "id": "F9"}, "name": "copy.docx"})
        );
        assert_eq!(
            copy_body("D1", "F9", None),
            serde_json::json!({"parentReference": {"driveId": "D1", "id": "F9"}})
        );
    }

    #[test]
    fn link_path_addresses_drive_item() {
        assert_eq!(
            create_link_path("D1", "I1"),
            "/drives/D1/items/I1/createLink"
        );
    }

    #[test]
    fn link_parse_extracts_web_url_and_scope() {
        let body: serde_json::Value = serde_json::from_str(
            r#"{"id":"perm-1","link":{"type":"view","scope":"organization",
                "webUrl":"https://contoso.sharepoint.com/:i:/x/ABC"}}"#,
        )
        .unwrap();
        let link = parse_create_link(&body).unwrap();
        assert_eq!(link.url, "https://contoso.sharepoint.com/:i:/x/ABC");
        assert_eq!(link.scope.as_deref(), Some("organization"));
    }

    #[test]
    fn link_parse_rejects_missing_link_or_url() {
        for raw in [
            r#"{"id":"perm-1"}"#,
            r#"{"link":{"type":"view","scope":"organization"}}"#,
            r#"{"link":{"webUrl":""}}"#,
        ] {
            let body: serde_json::Value = serde_json::from_str(raw).unwrap();
            assert!(parse_create_link(&body).is_err(), "raw {}", raw);
        }
    }

    #[test]
    fn list_never_fills_share_url() {
        let item: DriveItem =
            serde_json::from_str(r#"{"id":"i1","name":"f.docx"}"#).unwrap();
        assert_eq!(shared_from_item(item, None).share_url, None);
    }

    #[test]
    fn versions_parse_newest_first_with_author() {
        let body: VersionsResponse = serde_json::from_str(
            r#"{"value":[
                {"id":"3.0","size":48211,"lastModifiedDateTime":"2026-09-20T10:00:00Z",
                 "lastModifiedBy":{"user":{"displayName":"Megan Harper"}}},
                {"id":"2.0"},
                {"id":"1.0","size":100,"lastModifiedBy":{}}
            ]}"#,
        )
        .unwrap();
        let vs: Vec<FileVersion> = body.value.into_iter().map(version_from_item).collect();
        assert_eq!(vs.len(), 3);
        assert_eq!(vs[0].id, "3.0");
        assert_eq!(vs[0].size, 48211);
        assert_eq!(vs[0].modified.as_deref(), Some("2026-09-20T10:00:00Z"));
        assert_eq!(vs[0].modified_by.as_deref(), Some("Megan Harper"));
        // Sparse versions default size 0, no author (never fatal).
        assert_eq!(vs[1].size, 0);
        assert_eq!(vs[1].modified_by, None);
        assert_eq!(vs[2].id, "1.0");
        assert_eq!(vs[2].modified_by, None);
    }

    #[test]
    fn channel_scope_is_tacv2_suffix() {
        assert!(is_channel_id("19:general@thread.tacv2"));
        assert!(is_channel_id("  19:abc@thread.tacv2  "));
        assert!(!is_channel_id("19:abc@thread.v2"));
        assert!(!is_channel_id("19:meeting_xyz@thread.v2"));
        assert!(!is_channel_id(""));
        assert!(!is_channel_id("19:general@thread.tacv2.evil"));
        assert!(!is_channel_id("general"));
    }

    #[test]
    fn chat_scope_never_takes_the_channel_scan() {
        assert!(is_chat_id("19:abc@thread.v2"));
        assert!(is_chat_id(" 19:meeting_xyz@thread.v2 "));
        assert!(is_chat_id("19:a_b@unq.gbl.spaces"));
        assert!(is_chat_id("19:old@thread.skype"));
        assert!(is_chat_id("48:notes"));
        assert!(is_chat_id("28:1a2b3c4d-bot"));
        assert!(!is_chat_id("19:general@thread.tacv2"));
        assert!(!is_chat_id("general"));
        assert!(!is_chat_id(""));
        let r = crate::api::chat::ChatFileRef {
            attachment_id: Some("att-1".into()),
            name: "Plan.docx".into(),
            file_type: Some("docx".into()),
            object_url: "https://contoso-my.sharepoint.com/personal/a/Documents/Plan.docx".into(),
            share_url: None,
            sender: Some("Alex Carter".into()),
            time: Some("2026-09-28T09:00:00Z".into()),
        };
        let f = shared_from_ref(&r);
        assert_eq!(f.id, "att-1");
        assert_eq!(f.drive_id, None);
        assert_eq!(f.web_url.as_deref(), Some(r.object_url.as_str()));
        assert_eq!(f.attachment_id.as_deref(), Some("att-1"));
        assert!(!f.is_folder);
    }

    #[test]
    fn chunk_ranges_cover_total_with_short_tail() {
        // Exact multiple: no tail.
        assert_eq!(
            upload_chunk_ranges(10, 5),
            vec![(0, 4), (5, 9)]
        );
        // Short tail keeps the byte count exact.
        assert_eq!(
            upload_chunk_ranges(12, 5),
            vec![(0, 4), (5, 9), (10, 11)]
        );
        // Single chunk when the file fits.
        assert_eq!(upload_chunk_ranges(3, 5), vec![(0, 2)]);
        // Empty file: no ranges (simple PUT handles it).
        assert!(upload_chunk_ranges(0, 5).is_empty());
    }

    #[test]
    fn content_range_value_is_inclusive() {
        assert_eq!(content_range_value(0, 4, 12), "bytes 0-4/12");
        assert_eq!(content_range_value(10, 11, 12), "bytes 10-11/12");
    }

    #[test]
    fn session_body_replaces_like_simple_put() {
        let body = upload_session_body("a b.pdf");
        assert_eq!(
            body["item"]["@microsoft.graph.conflictBehavior"],
            "replace"
        );
        assert_eq!(body["item"]["name"], "a b.pdf");
    }
}

#[cfg(test)]
mod file_post_idem_tests {
    use super::*;

    #[test]
    fn timeout_with_no_proof_of_absence_never_falls_back_to_a_second_post() {
        // Post timed out, lookup failed or found nothing yet: Teams may have
        // accepted it. Never the Graph fallback (that was the double-post).
        let timeout = "Chat POST https://x/v1/users/ME/conversations/19:a/messages failed: operation timed out";
        assert_eq!(file_post_next(timeout, Some(false)), FilePostNext::Unknown);
        assert_eq!(file_post_next(timeout, None), FilePostNext::Unknown);
        let five = "HTTP 503 for https://x: unavailable";
        assert_eq!(file_post_next(five, Some(false)), FilePostNext::Unknown);
    }

    #[test]
    fn landed_message_is_settled_without_a_second_post() {
        let timeout = "Chat POST failed: operation timed out";
        assert_eq!(file_post_next(timeout, Some(true)), FilePostNext::Landed);
    }

    #[test]
    fn only_a_proven_4xx_rejection_with_the_id_absent_uses_graph() {
        assert_eq!(file_post_next("HTTP 403 for https://x: no", Some(false)), FilePostNext::Graph);
        assert_eq!(file_post_next("401 Unauthorized for https://x.", Some(false)), FilePostNext::Graph);
        // 4xx but the lookup failed: still unknown.
        assert_eq!(file_post_next("HTTP 403 for https://x: no", None), FilePostNext::Unknown);
        assert!(!is_definite_rejection("HTTP 500 for x"));
    }
}

/// F1 fake-transport tests: the real `post_file_message_idem` against a
/// loopback fake (chat service + Graph), no tenant contact.
#[cfg(test)]
mod file_post_idem_fake_tests {
    use super::*;
    use crate::api::fake_transport::Fake;
    use serde_json::json;

    const CHAT: &str = "19:chat1@thread.v2";
    const CHANNEL: &str = "19:chan1@thread.tacv2";
    const CMID: &str = "1700000000000123";

    fn item() -> DriveItem {
        serde_json::from_value(json!({
            "id": "item1",
            "eTag": "\"{0F1E2D3C-AAAA-BBBB-CCCC-000000000001},2\"",
            "webUrl": "https://contoso-my.sharepoint.com/personal/a_contoso_com/Documents/Microsoft Teams Chat Files/plan.docx",
        }))
        .expect("item")
    }

    fn landed_page() -> String {
        json!({"messages": [{
            "id": "1", "messagetype": "RichText/Html", "content": "<p>plan.docx</p>",
            "clientmessageid": CMID, "imdisplayname": "Alex Carter",
            "originalarrivaltime": "2026-09-29T10:00:00.000Z",
        }]})
        .to_string()
    }

    async fn run(fake: &Fake, id: &str, verify_first: bool) -> Result<()> {
        let graph_path = format!("/me/chats/{}/messages", id);
        post_file_message_idem(&fake.client(), id, &item(), "plan.docx", CMID, verify_first, &graph_path).await
    }

    fn count(fake: &Fake, method: &str, prefix: &str) -> usize {
        fake.requests().iter().filter(|r| r.method == method && r.path.starts_with(prefix)).count()
    }

    #[tokio::test]
    async fn first_post_carries_the_client_message_id_and_stops() {
        for id in [CHAT, CHANNEL] {
            let fake = Fake::start(vec![("POST", "/chat/v1/users/ME/conversations/", 201, "{}".into())]).await;
            run(&fake, id, false).await.expect("posted");
            let reqs = fake.requests();
            assert_eq!(reqs.len(), 1, "one POST, nothing else: {id}");
            assert_eq!(reqs[0].json()["clientmessageid"], CMID);
        }
    }

    #[tokio::test]
    async fn retry_finds_the_landed_message_and_posts_nothing() {
        for id in [CHAT, CHANNEL] {
            let fake = Fake::start(vec![
                ("GET", "/chat/v1/users/ME/conversations/", 200, landed_page()),
                ("POST", "/chat/", 201, "{}".into()),
            ])
            .await;
            run(&fake, id, true).await.expect("settled");
            assert_eq!(count(&fake, "POST", "/"), 0, "verify-first found it: no post at all ({id})");
        }
    }

    #[tokio::test]
    async fn timed_out_post_that_landed_is_not_posted_to_graph() {
        // Chat service answers 503 (ambiguous) but the message is there.
        let fake = Fake::start(vec![
            ("POST", "/chat/v1/users/ME/conversations/", 503, "{}".into()),
            ("GET", "/chat/v1/users/ME/conversations/", 200, landed_page()),
        ])
        .await;
        run(&fake, CHANNEL, false).await.expect("landed = success");
        assert_eq!(count(&fake, "POST", "/graph"), 0);
        assert_eq!(count(&fake, "POST", "/chat"), 1);
    }

    #[tokio::test]
    async fn ambiguous_failure_with_nothing_found_errors_and_never_double_posts() {
        let fake = Fake::start(vec![
            ("POST", "/chat/v1/users/ME/conversations/", 503, "{}".into()),
            ("GET", "/chat/v1/users/ME/conversations/", 200, "{\"messages\":[]}".into()),
            ("POST", "/graph/", 201, "{}".into()),
        ])
        .await;
        let err = run(&fake, CHAT, false).await.err().expect("unknown = error");
        assert!(format!("{err:#}").contains("Retry checks first"), "{err:#}");
        assert_eq!(count(&fake, "POST", "/graph"), 0, "no second post to Graph");
        assert_eq!(count(&fake, "POST", "/chat"), 1);
    }

    #[tokio::test]
    async fn lookup_failure_after_a_failed_post_errors_without_a_second_post() {
        let fake = Fake::start(vec![
            ("POST", "/chat/v1/users/ME/conversations/", 503, "{}".into()),
            ("GET", "/chat/v1/users/ME/conversations/", 500, "{}".into()),
            ("POST", "/graph/", 201, "{}".into()),
        ])
        .await;
        assert!(run(&fake, CHANNEL, false).await.is_err());
        assert_eq!(count(&fake, "POST", "/graph"), 0);
    }

    #[tokio::test]
    async fn proven_rejection_falls_back_to_graph_once() {
        for (id, path) in [(CHAT, "/graph/me/chats/"), (CHANNEL, "/graph/me/chats/")] {
            let fake = Fake::start(vec![
                ("POST", "/chat/v1/users/ME/conversations/", 403, "{\"error\":\"no\"}".into()),
                ("GET", "/chat/v1/users/ME/conversations/", 200, "{\"messages\":[]}".into()),
                ("POST", "/graph/", 201, "{}".into()),
            ])
            .await;
            run(&fake, id, false).await.expect("graph fallback ok");
            assert_eq!(count(&fake, "POST", path), 1, "{id}");
        }
    }
}
