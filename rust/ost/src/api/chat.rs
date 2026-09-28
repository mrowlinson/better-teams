//! Native Teams chat API (chatsvcagg / chat service)
//!
//! Uses the Skype token with `Authentication: skypetoken={token}` header,
//! bypassing Graph API which requires tenant admin consent for Chat.Read.

use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::collections::HashMap;

use super::client::TeamsClient;
use super::me::whoami_data;

// -- Response types for the native chat API --

#[derive(Debug, Deserialize)]
struct ConversationsResponse {
    conversations: Option<Vec<Conversation>>,
}

#[derive(Debug, Deserialize)]
struct Conversation {
    id: Option<String>,
    #[serde(rename = "threadProperties")]
    thread_properties: Option<ThreadProperties>,
    #[serde(rename = "lastMessage")]
    last_message: Option<NativeMessage>,
}

#[derive(Debug, Deserialize)]
struct ThreadProperties {
    topic: Option<String>,
    #[serde(rename = "lastjoinat")]
    last_join_at: Option<String>,
    /// For 1:1 chats, contains member MRIs
    members: Option<String>,
}

#[derive(Debug, Deserialize)]
struct NativeMessage {
    id: Option<String>,
    #[serde(rename = "composetime")]
    compose_time: Option<String>,
    #[serde(rename = "originalarrivaltime")]
    original_arrival_time: Option<String>,
    #[serde(rename = "imdisplayname")]
    im_display_name: Option<String>,
    content: Option<String>,
    messagetype: Option<String>,
    from: Option<String>,
    /// OstMac om-reactions: per-message reactions when the server sends
    /// them (Graph-like list). Absent on old payloads → no counts.
    /// Kept raw (core-a) so reactor ids/names survive unknown shapes.
    reactions: Option<serde_json::Value>,
    /// Alternate nesting some payloads use (`properties.reactions`).
    properties: Option<MessageProperties>,
    /// Unknown top-level wire fields (om-lt2-quotelink): channel thread
    /// parents (`rootMessageId` / `replyToId`) land here; mined
    /// case-insensitively, never fatal.
    #[serde(default, flatten)]
    extra: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct MessageProperties {
    reactions: Option<serde_json::Value>,
    /// Unknown `properties.*` fields (om-lt2-quotelink): same parent
    /// mining as top-level, for nested channel shapes.
    #[serde(default, flatten)]
    extra: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct MessagesResponse {
    messages: Option<Vec<NativeMessage>>,
    #[serde(rename = "_metadata")]
    metadata: Option<MessagesMetadata>,
}

#[derive(Debug, Deserialize)]
struct MessagesMetadata {
    #[serde(rename = "backwardLink")]
    backward_link: Option<String>,
}

/// Block-level tags: a boundary here separates words, so it yields one
/// space (pending, only between two non-space chars). Inline tags
/// (`b`, `i`, `at`, `code`, …) vanish silently so `a<b>x</b>b` stays glued.
const BLOCK_TAGS: &[&str] = &[
    "p", "div", "br", "section", "article", "header", "footer", "h1", "h2", "h3", "h4",
    "h5", "h6", "ul", "ol", "li", "dl", "dt", "dd", "table", "tr", "td", "th",
    "blockquote", "pre", "hr",
];

/// Tag name of a raw `<…>` body: attributes and the `/` of closing
/// or self-closed tags stripped, case preserved (caller matches
/// case-insensitively). `<>` yields "".
fn tag_name(body: &str) -> &str {
    let b = body.strip_prefix('/').unwrap_or(body);
    let end = b
        .find(|c: char| c.is_whitespace() || c == '/')
        .unwrap_or(b.len());
    &b[..end]
}

/// Strip HTML tags from content for CLI display.
///
/// Spacing-aware (om-chatnames): block-level tag boundaries become a
/// single space so `</p><p>` never glues words ("tag-boundary glue").
/// No leading/trailing space is added (`<p>hi</p>` → `hi`).
fn strip_html(html: &str) -> String {
    let mut result = String::with_capacity(html.len());
    let mut tag = String::new();
    let mut in_tag = false;
    let mut pending_space = false;
    for ch in html.chars() {
        if in_tag {
            if ch == '>' {
                in_tag = false;
                if BLOCK_TAGS.contains(&tag_name(&tag).to_lowercase().as_str()) {
                    pending_space = true;
                }
                tag.clear();
            } else {
                tag.push(ch);
            }
        } else if ch == '<' {
            in_tag = true;
        } else {
            if pending_space {
                pending_space = false;
                if !result.is_empty()
                    && !result.ends_with(char::is_whitespace)
                    && !ch.is_whitespace()
                {
                    result.push(' ');
                }
            }
            result.push(ch);
        }
    }
    // Decode common HTML entities
    result
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
}

/// Human label for a chat with no topic, mate, or sender — never the
/// raw thread id (om-chatnames). `48:xxx` system chats humanize their
/// suffix (`48:notifications` → `Notifications`); anything else gets a
/// shape-based label (`[Direct message]`, `[Group chat]`, …).
fn system_label_for(chat_id: &str) -> String {
    if let Some(rest) = chat_id.strip_prefix("48:") {
        let mut chars = rest.chars();
        match chars.next() {
            None => return "[System chat]".to_string(),
            Some(first) => {
                return format!(
                    "{}{}",
                    first.to_uppercase().collect::<String>(),
                    chars.as_str()
                );
            }
        }
    }
    if chat_id.contains("meeting") {
        "[Meeting chat]"
    } else if chat_id.contains("@thread") {
        "[Group chat]"
    } else if chat_id.starts_with("19:") {
        "[Direct message]"
    } else {
        "[Chat]"
    }
    .to_string()
}

/// Display name for a conversation: topic → resolved 1:1 mate name →
/// last-message sender → system label. Never the raw thread id.
fn conversation_name(conv: &Conversation, mate: Option<&str>) -> String {
    if let Some(ref props) = conv.thread_properties {
        if let Some(ref topic) = props.topic {
            if !topic.trim().is_empty() {
                return topic.clone();
            }
        }
    }
    if let Some(m) = mate {
        if !m.trim().is_empty() {
            return m.to_string();
        }
    }
    if let Some(ref msg) = conv.last_message {
        if let Some(ref name) = msg.im_display_name {
            if !name.trim().is_empty() {
                return name.clone();
            }
        }
    }
    system_label_for(conv.id.as_deref().unwrap_or(""))
}

/// List recent chats using the native Teams API (prints to stdout).
pub async fn list_chats(limit: usize) -> Result<()> {
    let client = TeamsClient::new().await?;
    let chats = list_chats_data(&client, limit).await?;

    println!("\nRecent Chats:");
    println!("{:-<60}", "");

    if chats.is_empty() {
        println!("  (no chats found)");
        return Ok(());
    }

    for chat in &chats {
        println!("{}", chat.name);
        println!("  ID: {}", chat.id);

        if let Some(ref time) = chat.last_message_time {
            println!("  Last: {}", time);
        }
        if let Some(ref preview) = chat.last_message_preview {
            if !preview.trim().is_empty() {
                let sender = chat.last_message_sender.as_deref().unwrap_or("?");
                println!("  [{}]: {}", sender, preview.trim());
            }
        }

        println!();
    }

    Ok(())
}

/// Read messages from a specific chat thread (prints to stdout).
pub async fn read_messages(chat_id: &str, limit: usize) -> Result<()> {
    let client = TeamsClient::new().await?;
    let msgs = read_messages_data(&client, chat_id, limit).await?;

    if msgs.is_empty() {
        println!("(no messages)");
        return Ok(());
    }

    for msg in &msgs {
        // OstMac om-botposts: kept card posts carry empty `content` (the
        // embedder mines rows from `raw`) — never print a blank line.
        // Image-only bubbles keep their own shape (empty body, raw has
        // `<img>`); only card payloads get the marker.
        let body = if msg.content.trim().is_empty() && has_card_payload(&msg.raw) {
            "(card post)"
        } else {
            msg.content.as_str()
        };
        match &msg.reply_to {
            Some(parent) => println!(
                "[{}] {}: {} (reply to {})",
                msg.timestamp, msg.sender, body, parent
            ),
            None => println!("[{}] {}: {}", msg.timestamp, msg.sender, body),
        }
    }

    Ok(())
}

/// Send a message to a chat thread using the native API.
pub async fn send_message(chat_id: &str, message: &str) -> Result<()> {
    let client = TeamsClient::new().await?;
    send_message_with_client(&client, chat_id, message).await?;
    println!("Message sent.");
    Ok(())
}

/// Reply to one message in a chat thread (quote reply).
///
/// Resolves the parent from the newest history page for quote attribution;
/// errors clearly when the parent id is not in recent history.
pub async fn reply_message(chat_id: &str, parent_id: &str, message: &str) -> Result<()> {
    let client = TeamsClient::new().await?;
    let msgs = read_messages_data(&client, chat_id, 50).await?;
    let parent = msgs
        .iter()
        .find(|m| m.id == parent_id)
        .ok_or_else(|| {
            anyhow::anyhow!(
                "parent message {} not found in recent history",
                parent_id
            )
        })?;
    reply_message_with_client(
        &client,
        chat_id,
        &parent.id,
        &parent.sender,
        &parent.content,
        message,
    )
    .await?;
    println!("Reply sent.");
    Ok(())
}

/// HTML-escape text for embedding in Teams RichText/Html messages.
fn html_escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

/// Max fenced code blocks parsed per outbound message (hostile-input
/// cap, mirrors Swift `CodeBlocks.maxBlocks`); extra fences stay prose.
pub const WIRE_FENCE_MAX_BLOCKS: usize = 50;

/// One line classified as a fence opener: (fence char, run length).
/// Mirrors Swift `CodeBlocks.fenceMarker`: any indent, ``` or ~~~ runs
/// of ≥ 3, info strings must not contain the fence char (CommonMark).
fn wire_fence_opener(line: &str) -> Option<(char, usize)> {
    let t = line.trim_start_matches([' ', '\t']);
    let c = t.chars().next()?;
    if c != '`' && c != '~' {
        return None;
    }
    let len = t.chars().take_while(|&ch| ch == c).count();
    if len < 3 {
        return None;
    }
    let rest: String = t.chars().skip(len).collect();
    if rest.trim().is_empty() {
        return Some((c, len));
    }
    if rest.contains(c) {
        return None;
    }
    Some((c, len))
}

/// A closer line: same-char run ≥ opening length + nothing but
/// whitespace after (info-carrying lines never close).
fn wire_fence_closer(line: &str, ch: char, len: usize) -> bool {
    let t = line.trim_start_matches([' ', '\t']);
    let run = t.chars().take_while(|&c| c == ch).count();
    if run < len {
        return false;
    }
    t.chars().skip(run).collect::<String>().trim().is_empty()
}

/// Outbound wire HTML for a composer body. Fence-less messages keep the
/// legacy single-`<p>` shape bit-identical; each fenced block becomes a
/// `<pre>` (HTML preserves its newlines/indents in every client) and
/// surrounding prose becomes `<p>` chunks. Fence lines are consumed,
/// info strings dropped (the wire carries no highlighter), code
/// interiors byte-exact modulo HTML-escaping. Unclosed fences run to
/// end of text (Swift `CodeBlocks` parity).
pub fn build_message_html(message: &str) -> String {
    if !message.lines().any(|l| wire_fence_opener(l).is_some()) {
        return format!("<p>{}</p>", html_escape(message));
    }
    enum Seg {
        Prose(String),
        Code(String),
    }
    let mut segs: Vec<Seg> = Vec::new();
    let mut prose = String::new();
    let mut code: Option<(Vec<String>, char, usize)> = None;
    let mut blocks = 0;
    for line in message.split('\n') {
        if let Some((mut lines, ch, len)) = code.take() {
            if wire_fence_closer(line, ch, len) {
                segs.push(Seg::Code(lines.join("\n")));
            } else {
                lines.push(line.to_string());
                code = Some((lines, ch, len));
            }
            continue;
        }
        if blocks < WIRE_FENCE_MAX_BLOCKS {
            if let Some((ch, len)) = wire_fence_opener(line) {
                if !prose.is_empty() {
                    segs.push(Seg::Prose(std::mem::take(&mut prose)));
                }
                code = Some((Vec::new(), ch, len));
                blocks += 1;
                continue;
            }
        }
        if !prose.is_empty() {
            prose.push('\n');
        }
        prose.push_str(line);
    }
    if let Some((lines, _, _)) = code.take() {
        segs.push(Seg::Code(lines.join("\n")));
    } else if !prose.is_empty() {
        segs.push(Seg::Prose(prose));
    }
    let mut out = String::new();
    for s in segs {
        match s {
            Seg::Prose(t) => {
                // Whitespace-only prose renders blank either way; skip it
                // so whole-message fences emit a lone <pre>.
                if !t.trim().is_empty() {
                    out.push_str(&format!("<p>{}</p>", html_escape(&t)));
                }
            }
            Seg::Code(t) => out.push_str(&format!("<pre>{}</pre>", html_escape(&t))),
        }
    }
    out
}

/// POST body for sending one chat message (captured-body seam for
/// tests: the exact JSON `chat_post` receives, minus transport).
pub fn send_message_body(message: &str) -> serde_json::Value {
    serde_json::json!({
        "content": build_message_html(message),
        "messagetype": "RichText/Html",
        "contenttype": "text"
    })
}

/// Send a message using an existing client (shared helper).
pub async fn send_message_with_client(
    client: &TeamsClient,
    chat_id: &str,
    message: &str,
) -> Result<()> {
    let base = client.chat_service_url();
    let url = format!("{}/v1/users/ME/conversations/{}/messages", base, chat_id);

    let body = send_message_body(message);

    tracing::debug!("Sending message to {}", url);
    client.chat_post(&url, &body).await?;
    Ok(())
}

/// Max quoted chars carried in a reply `<quote>` block.
pub const REPLY_SNIPPET_MAX: usize = 140;

/// Collapse whitespace and truncate to a one-line quote snippet.
/// Over-long text is cut at a char boundary with a trailing `…`.
pub fn reply_snippet(text: &str) -> String {
    let one_line: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if one_line.chars().count() <= REPLY_SNIPPET_MAX {
        return one_line;
    }
    let end = one_line
        .char_indices()
        .nth(REPLY_SNIPPET_MAX)
        .map(|(i, _)| i)
        .unwrap_or(one_line.len());
    format!("{}…", &one_line[..end])
}

/// Build reply HTML: a Skype-style `<quote author guid>` block carrying the
/// parent id, then the [`build_message_html`] body (fenced replies get
/// `<pre>`, prose keeps `<p>`). Official clients render the quote;
/// [`split_reply_quote`] recovers the parent id on read.
pub fn build_reply_html(
    parent_id: &str,
    parent_sender: &str,
    parent_text: &str,
    text: &str,
) -> String {
    format!(
        "<quote author=\"{}\" guid=\"{}\">{}</quote>{}",
        html_escape(parent_sender),
        html_escape(parent_id),
        html_escape(&reply_snippet(parent_text)),
        build_message_html(text),
    )
}

/// Split the first `<quote … guid="…">…</quote>` block off raw content.
/// Returns the parent id plus the remaining HTML. Missing or malformed
/// quotes yield `(None, content)` unchanged.
pub fn split_reply_quote(content: &str) -> (Option<String>, String) {
    let Some(open) = content.find("<quote") else {
        return (None, content.to_string());
    };
    let rest = &content[open..];
    let Some(tag_end) = rest.find('>') else {
        return (None, content.to_string());
    };
    let tag = &rest[..tag_end];
    let id = parse_guid(tag).filter(|s| !s.is_empty());
    let after_tag = &rest[tag_end + 1..];
    let Some(close) = after_tag.find("</quote>") else {
        return (None, content.to_string());
    };
    let mut out = String::with_capacity(content.len());
    out.push_str(&content[..open]);
    out.push_str(&after_tag[close + "</quote>".len()..]);
    (id, out)
}

/// `guid="…"` (double or single quotes) from a `<quote …>` open tag.
fn parse_guid(tag: &str) -> Option<String> {
    for quote in ['"', '\''] {
        let mark = format!("guid={}", quote);
        if let Some(start) = tag.find(&mark) {
            let val_start = start + mark.len();
            if let Some(end) = tag[val_start..].find(quote) {
                return Some(tag[val_start..val_start + end].to_string());
            }
        }
    }
    None
}

/// Channel thread parent from wire fields (om-lt2-quotelink).
/// Top-level wins, then `properties.*`, then content-embedded forms.
/// Missing/odd shapes → None, never fatal.
fn message_parent_id(msg: &NativeMessage) -> Option<String> {
    if let Some(s) = wire_parent_from_map(&msg.extra) {
        return Some(s);
    }
    if let Some(props) = msg.properties.as_ref() {
        if let Some(s) = wire_parent_from_map(&props.extra) {
            return Some(s);
        }
    }
    if let Some(content) = msg.content.as_deref() {
        if let Some(s) = parent_id_from_content(content) {
            return Some(s);
        }
    }
    None
}

/// One wire value as a parent id: trimmed non-empty strings pass,
/// numbers stringify, everything else drops.
fn wire_parent_value(v: &serde_json::Value) -> Option<String> {
    match v {
        serde_json::Value::String(s) => {
            let t = s.trim();
            if t.is_empty() {
                None
            } else {
                Some(t.to_string())
            }
        }
        serde_json::Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

/// Case-insensitive parent-key lookup over one flattened map.
/// Graph sends `replyToId`; native channel cards send `rootMessageId`
/// (H0 live probe, om-channel-history). Both mean "replies to <id>".
fn wire_parent_from_map(map: &HashMap<String, serde_json::Value>) -> Option<String> {
    for (k, v) in map {
        let lk = k.to_lowercase();
        if lk == "rootmessageid"
            || lk == "replytoid"
            || lk == "parentmessageid"
            || lk == "parentid"
        {
            if let Some(s) = wire_parent_value(v) {
                return Some(s);
            }
        }
    }
    None
}

/// Scan raw content for embedded `rootMessageId` / `replyToId` forms:
/// `"key":"val"`, `key="val"`, `key:123` (any quote/sep mix).
/// Case-insensitive key, first non-empty wins. Byte-wise so Unicode
/// text never misaligns indices; unterminated values drop.
fn parent_id_from_content(html: &str) -> Option<String> {
    const KEYS: &[&[u8]] = &[b"rootmessageid", b"replytoid"];
    let bytes = html.as_bytes();
    for key in KEYS {
        let mut i = 0;
        while i + key.len() <= bytes.len() {
            if bytes[i..i + key.len()].eq_ignore_ascii_case(key) {
                let boundary = i == 0 || !bytes[i - 1].is_ascii_alphanumeric();
                if boundary {
                    if let Some(v) = parent_value_after(bytes, i + key.len()) {
                        return Some(v);
                    }
                }
                i += key.len();
            } else {
                i += 1;
            }
        }
    }
    None
}

/// Value after a matched parent key: skips an optional closing quote,
/// requires `:` or `=`, then reads a quoted or bare token. None when
/// the key is not a key/value pair or the value is empty/unterminated.
fn parent_value_after(bytes: &[u8], mut j: usize) -> Option<String> {
    while j < bytes.len() && bytes[j].is_ascii_whitespace() {
        j += 1;
    }
    if j < bytes.len() && (bytes[j] == b'"' || bytes[j] == b'\'') {
        j += 1;
    }
    while j < bytes.len() && bytes[j].is_ascii_whitespace() {
        j += 1;
    }
    if j >= bytes.len() || (bytes[j] != b':' && bytes[j] != b'=') {
        return None;
    }
    j += 1;
    while j < bytes.len() && bytes[j].is_ascii_whitespace() {
        j += 1;
    }
    if j >= bytes.len() {
        return None;
    }
    let val: String;
    if bytes[j] == b'"' || bytes[j] == b'\'' {
        let q = bytes[j];
        j += 1;
        let start = j;
        while j < bytes.len() && bytes[j] != q {
            j += 1;
        }
        if j >= bytes.len() {
            return None;
        }
        val = String::from_utf8_lossy(&bytes[start..j]).trim().to_string();
    } else {
        let start = j;
        while j < bytes.len()
            && !matches!(
                bytes[j],
                b'"' | b'\'' | b',' | b';' | b'<' | b'>' | b'}' | b']' | b')' | b' '
                | b'\t' | b'\n' | b'\r'
            )
        {
            j += 1;
        }
        val = String::from_utf8_lossy(&bytes[start..j]).trim().to_string();
    }
    if val.is_empty() {
        None
    } else {
        Some(val)
    }
}

/// Reply using an existing client (shared helper). The parent attribution
/// comes from the caller (no extra history fetch); the quote block keeps
/// the thread link readable in every client.
pub async fn reply_message_with_client(
    client: &TeamsClient,
    chat_id: &str,
    parent_id: &str,
    parent_sender: &str,
    parent_text: &str,
    text: &str,
) -> Result<()> {
    let base = client.chat_service_url();
    let url = format!("{}/v1/users/ME/conversations/{}/messages", base, chat_id);

    let body = serde_json::json!({
        "content": build_reply_html(parent_id, parent_sender, parent_text, text),
        "messagetype": "RichText/Html",
        "contenttype": "text"
    });

    tracing::debug!("Sending reply to {}", url);
    client.chat_post(&url, &body).await?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Channel thread replies (OstMac core-a)
// ---------------------------------------------------------------------------
//
// Teams channels are reply chains: a reply is a message posted to the
// thread conversation `<channelId>;messageid=<rootId>` (the same link
// shape the server stamps on channel replies' `conversationLink`), not
// a new top-level post carrying a quote block. Chats (1:1, group,
// meeting) have no chains — they keep the quote-reply path.

/// True for channel conversation ids (`19:…@thread.tacv2`, legacy
/// `19:…@thread.skype`). Group chats (`@thread.v2`), meetings and
/// 1:1s are not channels. Pure so tests pin it.
pub fn is_channel_conversation_id(id: &str) -> bool {
    let t = id.trim();
    t.starts_with("19:") && (t.ends_with("@thread.tacv2") || t.ends_with("@thread.skype"))
}

/// Thread conversation id for a channel reply chain. Pure.
pub fn thread_reply_conversation(channel_id: &str, root_id: &str) -> String {
    format!("{};messageid={}", channel_id.trim(), root_id.trim())
}

/// POST URL for one channel thread reply. Pure so tests pin it.
pub fn thread_reply_url(base: &str, channel_id: &str, root_id: &str) -> String {
    format!(
        "{}/v1/users/ME/conversations/{}/messages",
        base,
        thread_reply_conversation(channel_id, root_id)
    )
}

/// Post one reply into a channel thread (reply chain under `root_id`).
/// Body is the plain send body (no quote block — the chain is the
/// link). Non-channel ids and blank args are rejected before network.
pub async fn thread_reply_with_client(
    client: &TeamsClient,
    channel_id: &str,
    root_id: &str,
    text: &str,
) -> Result<()> {
    if !is_channel_conversation_id(channel_id) {
        bail!("not a channel conversation id");
    }
    if root_id.trim().is_empty() || root_id.contains(';') || root_id.contains('/') {
        bail!("bad root message id");
    }
    if text.trim().is_empty() {
        bail!("empty text");
    }
    let url = thread_reply_url(&client.chat_service_url(), channel_id, root_id);
    tracing::debug!("Sending thread reply");
    client.chat_post(&url, &send_message_body(text)).await?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Reactions (OstMac om-reactions lane)
// ---------------------------------------------------------------------------
//
// Wire shape mirrors the Graph chatMessageReaction resource
// (`POST .../messages/{id}/reactions`, `{"reactionType": "like"}`) against
// the native chat service with skypetoken auth. Best-effort: NOT yet
// verified live against the server (see OSTMAC-PATCHES.md §17).

/// Picker emoji → Teams reaction type, in picker order.
/// (like, heart, laugh, surprised, sad, angry — the Graph-supported six.)
pub const REACTION_EMOJI: &[(&str, &str)] = &[
    ("👍", "like"),
    ("❤️", "heart"),
    ("😂", "laugh"),
    ("😮", "surprised"),
    ("😢", "sad"),
    ("😠", "angry"),
];

/// Reaction type for a picker emoji, or None when unsupported.
pub fn reaction_type_for_emoji(emoji: &str) -> Option<&'static str> {
    REACTION_EMOJI
        .iter()
        .find(|(e, _)| *e == emoji)
        .map(|(_, t)| *t)
}

/// Picker emoji for a server reaction type (case-insensitive), or None
/// when unknown. Unknown types are dropped from counts, never fatal.
pub fn emoji_for_reaction_type(reaction_type: &str) -> Option<&'static str> {
    REACTION_EMOJI
        .iter()
        .find(|(_, t)| t.eq_ignore_ascii_case(reaction_type))
        .map(|(e, _)| *e)
}

/// POST target for adding a reaction to one message.
pub fn reaction_add_url(base: &str, chat_id: &str, message_id: &str) -> String {
    format!(
        "{}/v1/users/ME/conversations/{}/messages/{}/reactions",
        base, chat_id, message_id
    )
}

/// Per-message URL for edits and deletes (pure so embedders/tests pin it).
pub fn message_url(base: &str, chat_id: &str, message_id: &str) -> String {
    format!(
        "{}/v1/users/ME/conversations/{}/messages/{}",
        base, chat_id, message_id
    )
}

/// POST body for adding a reaction.
pub fn reaction_add_body(reaction_type: &str) -> serde_json::Value {
    serde_json::json!({ "reactionType": reaction_type })
}

/// DELETE target for removing one reaction type from a message.
pub fn reaction_remove_url(
    base: &str,
    chat_id: &str,
    message_id: &str,
    reaction_type: &str,
) -> String {
    format!(
        "{}/v1/users/ME/conversations/{}/messages/{}/reactions/{}",
        base, chat_id, message_id, reaction_type
    )
}

/// Add one emoji reaction to a message. Unknown emoji is rejected before
/// any network.
pub async fn send_reaction_with_client(
    client: &TeamsClient,
    chat_id: &str,
    message_id: &str,
    emoji: &str,
) -> Result<()> {
    let reaction_type = reaction_type_for_emoji(emoji)
        .with_context(|| format!("unsupported reaction emoji: {}", emoji))?;
    let base = client.chat_service_url();
    let url = reaction_add_url(&base, chat_id, message_id);
    let body = reaction_add_body(reaction_type);
    tracing::debug!("Adding {} reaction to {}", reaction_type, url);
    client.chat_post(&url, &body).await?;
    Ok(())
}

/// Remove one emoji reaction from a message. Unknown emoji is rejected
/// before any network.
pub async fn remove_reaction_with_client(
    client: &TeamsClient,
    chat_id: &str,
    message_id: &str,
    emoji: &str,
) -> Result<()> {
    let reaction_type = reaction_type_for_emoji(emoji)
        .with_context(|| format!("unsupported reaction emoji: {}", emoji))?;
    let base = client.chat_service_url();
    let url = reaction_remove_url(&base, chat_id, message_id, reaction_type);
    tracing::debug!("Removing {} reaction from {}", reaction_type, url);
    client.chat_delete(&url, None).await?;
    Ok(())
}

/// Add or remove a reaction (prints to stdout). CLI entry point.
pub async fn react(chat_id: &str, message_id: &str, emoji: &str, remove: bool) -> Result<()> {
    let client = TeamsClient::new().await?;
    if remove {
        remove_reaction_with_client(&client, chat_id, message_id, emoji).await?;
        println!("Reaction removed.");
    } else {
        send_reaction_with_client(&client, chat_id, message_id, emoji).await?;
        println!("Reaction added.");
    }
    Ok(())
}

/// Edit body for the native chat API. `skypeeditedid` carries the original
/// id so receivers (and our realtime parser) classify it as an edit.
pub fn edit_message_body(message_id: &str, text: &str) -> serde_json::Value {
    let mut body = send_message_body(text);
    body["skypeeditedid"] = serde_json::json!(message_id);
    body
}

/// Edit one own message's text via PUT (prints to stdout).
pub async fn edit_message(chat_id: &str, message_id: &str, text: &str) -> Result<()> {
    let client = TeamsClient::new().await?;
    edit_message_with_client(&client, chat_id, message_id, text).await?;
    println!("Message edited.");
    Ok(())
}

/// Edit one own message using an existing client (shared helper).
pub async fn edit_message_with_client(
    client: &TeamsClient,
    chat_id: &str,
    message_id: &str,
    text: &str,
) -> Result<()> {
    let base = client.chat_service_url();
    let url = message_url(&base, chat_id, message_id);
    let body = edit_message_body(message_id, text);
    tracing::debug!("Editing message at {}", url);
    client.chat_put(&url, &body).await?;
    Ok(())
}

/// Delete one own message via DELETE (prints to stdout).
pub async fn delete_message(chat_id: &str, message_id: &str) -> Result<()> {
    let client = TeamsClient::new().await?;
    delete_message_with_client(&client, chat_id, message_id).await?;
    println!("Message deleted.");
    Ok(())
}

/// Delete one own message using an existing client (shared helper).
pub async fn delete_message_with_client(
    client: &TeamsClient,
    chat_id: &str,
    message_id: &str,
) -> Result<()> {
    let base = client.chat_service_url();
    let url = message_url(&base, chat_id, message_id);
    tracing::debug!("Deleting message at {}", url);
    client.chat_delete(&url, None).await?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Leave chat (OstMac om-leave-block lane)
// ---------------------------------------------------------------------------
//
// Self-removal from a thread's roster: DELETE .../v1/threads/{id}/members/{mri}
// with skypetoken auth, where the member MRI is the signed-in user's own
// (`8:orgid:{oid}` from whoami). Best-effort: NOT yet verified live against
// the server (see OSTMAC-PATCHES.md §27). Targets group threads; 1:1
// threads are hidden client-side instead (the block flow).

/// Own roster MRI for an Entra object id (`8:orgid:{oid}`).
pub fn own_member_mri(oid: &str) -> String {
    format!("8:orgid:{}", oid.trim())
}

/// DELETE target for removing one member from a thread's roster.
pub fn leave_member_url(base: &str, chat_id: &str, member_mri: &str) -> String {
    format!(
        "{}/v1/threads/{}/members/{}",
        base, chat_id, member_mri
    )
}

/// Leave one chat: remove self from the thread roster. Empty ids are
/// rejected before any network; the own MRI resolves via whoami.
pub async fn leave_chat_with_client(client: &TeamsClient, chat_id: &str) -> Result<()> {
    if chat_id.trim().is_empty() {
        anyhow::bail!("empty chat_id");
    }
    let me = whoami_data(client).await?;
    if me.id.trim().is_empty() {
        anyhow::bail!("empty owner id");
    }
    let base = client.chat_service_url();
    let url = leave_member_url(&base, chat_id.trim(), &own_member_mri(&me.id));
    tracing::debug!("Leaving chat at {}", url);
    client.chat_delete(&url, None).await?;
    Ok(())
}

/// Leave one chat thread (prints to stdout).
pub async fn leave_chat(chat_id: &str) -> Result<()> {
    let client = TeamsClient::new().await?;
    leave_chat_with_client(&client, chat_id).await?;
    println!("Left chat.");
    Ok(())
}

// ---------------------------------------------------------------------------
// Read receipts (OstMac om-receipts lane)
// ---------------------------------------------------------------------------
//
// Wire shape mirrors the native chat service consumption horizon:
// PUT .../v1/users/ME/conversations/{id}/properties?name=consumptionhorizon
// with {"consumptionhorizon": "<t1>;<t2>;<messageId>"} marks read;
// GET .../v1/threads/{id}/consumptionhorizons lists peer positions.

/// One peer read position: user key + last-read message id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadReceipt {
    pub user: String,
    pub message_id: String,
    pub horizon: String,
}

/// PUT target for marking one conversation read up to a message.
pub fn consumptionhorizon_url(base: &str, chat_id: &str) -> String {
    format!(
        "{}/v1/users/ME/conversations/{}/properties?name=consumptionhorizon",
        base, chat_id
    )
}

/// GET target for listing peer read positions in one thread.
pub fn consumptionhorizons_url(base: &str, thread_id: &str) -> String {
    format!(
        "{}/v1/threads/{}/consumptionhorizons",
        base, thread_id
    )
}

/// Horizon value: "<now_ms>;<now_ms>;<message_id>". Both stamps are the
/// send time (server accepts equal stamps; the id is the read frontier).
pub fn consumptionhorizon_value(message_id: &str, now_ms: u64) -> String {
    format!("{};{};{}", now_ms, now_ms, message_id)
}

/// PUT body for marking read.
pub fn consumptionhorizon_body(message_id: &str, now_ms: u64) -> serde_json::Value {
    serde_json::json!({ "consumptionhorizon": consumptionhorizon_value(message_id, now_ms) })
}

/// Message id from a horizon value: text after the last ';'.
/// Empty/blank horizons yield None (caller drops the entry).
pub fn receipt_message_id(horizon: &str) -> Option<String> {
    let id = horizon.rsplit(';').next()?.trim();
    if id.is_empty() {
        return None;
    }
    Some(id.to_string())
}

/// User key from one consumptionhorizon entry: `mri` → `id` → `user`
/// → display name, else "". Never fails (unknown shapes stay parseable).
fn receipt_user(entry: &serde_json::Value) -> String {
    for k in ["mri", "id", "user", "imdisplayname", "displayName"] {
        if let Some(s) = entry.get(k).and_then(|v| v.as_str()) {
            if !s.trim().is_empty() {
                return s.to_string();
            }
        }
    }
    String::new()
}

/// Parse the GET consumptionhorizons envelope into receipts. Tolerant:
/// missing/empty lists yield vec![], entries without a parseable horizon
/// are dropped, bare-string entries use "" as the user key.
pub fn parse_consumptionhorizons(value: &serde_json::Value) -> Vec<ReadReceipt> {
    let list = value
        .get("consumptionhorizons")
        .and_then(|v| v.as_array());
    let Some(list) = list else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for e in list {
        if let Some(s) = e.as_str() {
            let horizon = s.trim().to_string();
            if let Some(mid) = receipt_message_id(&horizon) {
                out.push(ReadReceipt {
                    user: String::new(),
                    message_id: mid,
                    horizon,
                });
            }
            continue;
        }
        let horizon = e
            .get("consumptionhorizon")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim()
            .to_string();
        let Some(mid) = receipt_message_id(&horizon) else {
            continue;
        };
        out.push(ReadReceipt {
            user: receipt_user(e),
            message_id: mid,
            horizon,
        });
    }
    out
}

fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Mark one conversation read up to `message_id` via PUT. Empty ids are
/// rejected before any network.
pub async fn mark_read_with_client(
    client: &TeamsClient,
    chat_id: &str,
    message_id: &str,
) -> Result<()> {
    if chat_id.trim().is_empty() {
        anyhow::bail!("empty chat_id");
    }
    if message_id.trim().is_empty() {
        anyhow::bail!("empty message_id");
    }
    let base = client.chat_service_url();
    let url = consumptionhorizon_url(&base, chat_id.trim());
    let body = consumptionhorizon_body(message_id.trim(), now_millis());
    tracing::debug!("Marking read at {}", url);
    client.chat_put(&url, &body).await?;
    Ok(())
}

/// Peer read positions for one thread (read-only). Unknown users/shapes
/// parse tolerantly via [`parse_consumptionhorizons`].
pub async fn read_receipts_data(
    client: &TeamsClient,
    thread_id: &str,
) -> Result<Vec<ReadReceipt>> {
    if thread_id.trim().is_empty() {
        anyhow::bail!("empty thread_id");
    }
    let base = client.chat_service_url();
    let url = consumptionhorizons_url(&base, thread_id.trim());
    let resp = client.chat_get(&url).await?;
    let value: serde_json::Value = resp
        .json()
        .await
        .context("Failed to parse consumptionhorizons response")?;
    Ok(parse_consumptionhorizons(&value))
}

// ---------------------------------------------------------------------------
// Data-returning API functions for TUI integration
// ---------------------------------------------------------------------------

/// Chat metadata for TUI display.
#[allow(dead_code)]
pub struct ChatInfo {
    pub id: String,
    pub name: String,
    pub is_group: bool,
    pub last_message_time: Option<String>,
    pub last_message_sender: Option<String>,
    pub last_message_preview: Option<String>,
}

/// A single message for TUI display.
pub struct MessageInfo {
    /// Server message id; embedders match realtime edits by this.
    /// OstMac: synthetic `timestamp@sender` fallback when the server omits it.
    pub id: String,
    /// Sender MRI parsed from the `from` user link
    /// (`…/v1/users/ME/contacts/8:orgid:<guid>` → `8:orgid:<guid>`);
    /// "" when the server omits `from`. Om-chatnames: 1:1 mate
    /// attribution matches this, never display-name spelling.
    pub sender_mri: String,
    pub sender: String,
    pub timestamp: String,
    pub content: String,
    /// Unstripped server HTML (om-convrich: embedders mine `<at>` mentions
    /// and `<pre>` code blocks from it; `content` stays the stripped text).
    pub raw: String,
    /// Grouped reaction counts (om-reactions). Empty when the server sent
    /// none; unknown reaction types are dropped, never fatal.
    pub reactions: Vec<ReactionCount>,
    /// Parent message id for quote replies (om-replies: mined from the
    /// `<quote guid>` block; `content` excludes the quoted text).
    pub reply_to: Option<String>,
}

/// One grouped reaction count: picker emoji + number of reactors.
/// `reactors` (core-a) lists who reacted when the wire names them;
/// it may be shorter than `count` (entries without an id still count).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReactionCount {
    pub emoji: String,
    pub count: usize,
    pub reactors: Vec<Reactor>,
}

/// One reactor (core-a who-reacted). `id` is whatever the wire names
/// the user by: an MRI (`8:orgid:<guid>`, native `emotions`) or a
/// Graph user id (Graph-like `reactions[].user.user.id`). `name` is
/// the display name when the wire carries one, else "" (the embedder
/// resolves MRIs through the chat roster).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reactor {
    pub id: String,
    pub name: String,
}

/// Picker index for a wire reaction type (case-insensitive).
fn reaction_index(t: &str) -> Option<usize> {
    REACTION_EMOJI
        .iter()
        .position(|(_, known)| known.eq_ignore_ascii_case(t.trim()))
}

/// Case-insensitive object field lookup.
fn obj_get_ci<'a>(
    o: &'a serde_json::Map<String, serde_json::Value>,
    key: &str,
) -> Option<&'a serde_json::Value> {
    o.get(key)
        .or_else(|| o.iter().find(|(k, _)| k.eq_ignore_ascii_case(key)).map(|(_, v)| v))
}

fn obj_str_ci(o: &serde_json::Map<String, serde_json::Value>, key: &str) -> Option<String> {
    obj_get_ci(o, key)
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Reactor from one Graph-like entry: `user.user.{id,displayName}`
/// (chatMessageReaction) or a flat `user.{id,displayName}`.
fn graph_reactor(entry: &serde_json::Map<String, serde_json::Value>) -> Option<Reactor> {
    let user = obj_get_ci(entry, "user")?.as_object()?;
    let identity = obj_get_ci(user, "user")
        .and_then(|v| v.as_object())
        .unwrap_or(user);
    let id = obj_str_ci(identity, "id")?;
    let name = obj_str_ci(identity, "displayName").unwrap_or_default();
    Some(Reactor { id, name })
}

/// JSON arrays may arrive stringified inside `properties` (native
/// chat service habit); decode once, anything else passes through.
fn as_array_lenient(v: &serde_json::Value) -> Option<Vec<serde_json::Value>> {
    match v {
        serde_json::Value::Array(a) => Some(a.clone()),
        serde_json::Value::String(s) => serde_json::from_str::<Vec<serde_json::Value>>(s).ok(),
        _ => None,
    }
}

/// Grouped reactions from raw wire values (core-a, shared with the
/// realtime parser). `reactions` is the Graph-like list
/// (`[{reactionType, user?}]`, one entry per reactor); `emotions` is
/// the native chat-service form (`[{key, users:[{mri}]}]`, array or
/// stringified). The Graph-like list wins when present. Canonical
/// picker order; unknown types drop; never fatal.
pub fn reaction_counts_from_values(
    reactions: Option<&serde_json::Value>,
    emotions: Option<&serde_json::Value>,
) -> Vec<ReactionCount> {
    let mut counts = vec![0usize; REACTION_EMOJI.len()];
    let mut reactors: Vec<Vec<Reactor>> = vec![Vec::new(); REACTION_EMOJI.len()];
    let mut push = |i: usize, r: Option<Reactor>| {
        counts[i] += 1;
        if let Some(r) = r {
            if !reactors[i].iter().any(|x| x.id.eq_ignore_ascii_case(&r.id)) {
                reactors[i].push(r);
            }
        }
    };
    if let Some(list) = reactions.and_then(as_array_lenient) {
        for e in &list {
            let Some(o) = e.as_object() else { continue };
            let Some(t) = obj_str_ci(o, "reactionType") else { continue };
            if let Some(i) = reaction_index(&t) {
                push(i, graph_reactor(o));
            }
        }
    } else if let Some(list) = emotions.and_then(as_array_lenient) {
        for e in &list {
            let Some(o) = e.as_object() else { continue };
            let Some(t) = obj_str_ci(o, "key") else { continue };
            let Some(i) = reaction_index(&t) else { continue };
            let users = obj_get_ci(o, "users").and_then(as_array_lenient).unwrap_or_default();
            for u in &users {
                let Some(uo) = u.as_object() else { continue };
                let id = obj_str_ci(uo, "mri").or_else(|| obj_str_ci(uo, "id"));
                let name = obj_str_ci(uo, "displayName").unwrap_or_default();
                push(i, id.map(|id| Reactor { id, name }));
            }
        }
    }
    REACTION_EMOJI
        .iter()
        .zip(counts.into_iter().zip(reactors))
        .filter(|(_, (c, _))| *c > 0)
        .map(|((emoji, _), (count, reactors))| ReactionCount {
            emoji: emoji.to_string(),
            count,
            reactors,
        })
        .collect()
}

/// Reaction entries for one message: top-level `reactions` wins, then
/// `properties.reactions`, then native `properties.emotions`. None
/// present → empty.
fn message_reactions(msg: &NativeMessage) -> Vec<ReactionCount> {
    let props = msg.properties.as_ref();
    let graph = msg
        .reactions
        .as_ref()
        .filter(|v| !v.is_null())
        .or_else(|| props.and_then(|p| p.reactions.as_ref()).filter(|v| !v.is_null()));
    let emotions = props.and_then(|p| {
        p.extra
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case("emotions"))
            .map(|(_, v)| v)
    });
    reaction_counts_from_values(graph, emotions)
}

/// One page of history plus the cursor for the next older page.
pub struct MessagesPage {
    pub messages: Vec<MessageInfo>,
    /// Server `_metadata.backwardLink`: full URL of the next older page,
    /// or None when history is exhausted / the server omits metadata.
    pub backward_link: Option<String>,
}

/// Roster entry from `GET /v1/threads/{id}/members`: the member MRI
/// (`8:orgid:<guid>`) is `id`. No display names on this endpoint —
/// names come from message attribution (see [`resolve_mate_name`]).
#[derive(Debug, Deserialize)]
struct ThreadMember {
    id: Option<String>,
    /// `Admin` / `User` (core-a roster roles; absent on some shapes).
    role: Option<String>,
    /// Some tenants stamp a display name; usually absent.
    #[serde(rename = "friendlyName")]
    friendly_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ThreadMembersResponse {
    members: Option<Vec<ThreadMember>>,
}

/// Member MRIs for one thread (read-only). Errors (404 on system
/// threads like `48:notes`, network) propagate to the caller, which
/// falls back to sender/label naming — never fatal to the list.
async fn thread_member_mris(client: &TeamsClient, thread_id: &str) -> Result<Vec<String>> {
    let base = client.chat_service_url();
    let url = format!("{}/v1/threads/{}/members", base, thread_id);
    let resp = client.chat_get(&url).await?;
    let body: ThreadMembersResponse = resp
        .json()
        .await
        .context("Failed to parse thread members response")?;
    Ok(body
        .members
        .unwrap_or_default()
        .into_iter()
        .filter_map(|m| m.id)
        .filter(|id| !id.trim().is_empty())
        .collect())
}

/// Decode `%XX` runs; malformed runs pass through untouched.
fn percent_decode(s: &str) -> String {
    fn hex(b: u8) -> Option<u8> {
        match b {
            b'0'..=b'9' => Some(b - b'0'),
            b'a'..=b'f' => Some(b - b'a' + 10),
            b'A'..=b'F' => Some(b - b'A' + 10),
            _ => None,
        }
    }
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hi = bytes.get(i + 1).and_then(|b| hex(*b));
            let lo = bytes.get(i + 2).and_then(|b| hex(*b));
            if let (Some(h), Some(l)) = (hi, lo) {
                out.push(h * 16 + l);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Sender MRI from a message `from` user link: the last path segment,
/// percent-decoded (`…/ME/contacts/8:orgid:<guid>` → `8:orgid:<guid>`).
/// Missing/empty `from` → "".
fn mri_from_user_link(from: Option<&str>) -> String {
    let seg = from
        .unwrap_or("")
        .rsplit('/')
        .next()
        .unwrap_or("")
        .trim();
    if seg.is_empty() {
        return String::new();
    }
    percent_decode(seg)
}

/// True when `mri` is the signed-in user: exact match or the MRI ends
/// with the owner OID (`8:orgid:<oid>`). Empty OID never matches.
fn mri_is_self(mri: &str, self_oid: &str) -> bool {
    if self_oid.trim().is_empty() || mri.trim().is_empty() {
        return false;
    }
    let m = mri.to_lowercase();
    let o = self_oid.to_lowercase();
    m == o || m.ends_with(&o)
}

/// 1:1-shaped thread ids (`19:…@unq.…`): group (`@thread.v2`) and
/// meeting ids are excluded, `48:…` system ids never qualify.
fn is_onetoone_id(chat_id: &str) -> bool {
    chat_id.starts_with("19:") && !chat_id.contains("@thread") && !chat_id.contains("meeting")
}

/// Mate display name for a 1:1 chat, resolved via MRI (om-chatnames):
/// roster MRIs minus self leaves the mate; the mate's name is the
/// newest message attributed to that MRI. `None` unless the roster
/// holds exactly one non-self MRI with at least one message —
/// anything else keeps the sender/label fallback.
async fn resolve_mate_name(
    client: &TeamsClient,
    chat_id: &str,
    self_oid: &str,
) -> Option<String> {
    let members = thread_member_mris(client, chat_id).await.ok()?;
    let mates: Vec<&str> = members
        .iter()
        .map(String::as_str)
        .filter(|m| !mri_is_self(m, self_oid))
        .collect();
    if mates.len() != 1 {
        return None;
    }
    let mate = mates[0].to_lowercase();
    let page = read_messages_page(client, chat_id, 25, None).await.ok()?;
    page.messages
        .iter()
        .rev()
        .filter(|m| m.sender_mri.to_lowercase() == mate)
        .map(|m| m.sender.clone())
        .filter(|s| !s.trim().is_empty() && s != "?")
        .next()
}

// ---------------------------------------------------------------------------
// 1:1 chat create (om-lt5-person11: person-pick opens 1:1)
// ---------------------------------------------------------------------------

/// `POST /me/chats` path for 1:1 creation. Pure so tests pin it.
pub fn one_to_one_create_path() -> &'static str {
    "/me/chats"
}

/// `POST /me/chats` body for a 1:1 with `user` (AAD id or UPN).
/// Self is implied (members carries the peer only, owner role).
/// Pure so tests pin it.
pub fn one_to_one_create_body(user: &str) -> serde_json::Value {
    serde_json::json!({
        "chatType": "oneOnOne",
        "members": [
            {
                "@odata.type": "#microsoft.graph.aadUserConversationMember",
                "roles": ["owner"],
                "user@odata.bind": format!(
                    "https://graph.microsoft.com/v1.0/users('{}')",
                    user.trim()
                ),
            }
        ],
    })
}

#[derive(Debug, Deserialize)]
struct CreatedChat {
    id: String,
    topic: Option<String>,
}

/// Parse a `POST /me/chats` 1:1 response into a chat row. Graph
/// returns no topic for 1:1s — the caller names the thread after
/// the peer. Pure so tests pin it.
pub fn parse_created_chat(value: &serde_json::Value) -> Result<ChatInfo> {
    let chat: CreatedChat = serde_json::from_value(value.clone())
        .context("Failed to parse created chat response")?;
    Ok(ChatInfo {
        id: chat.id,
        name: chat.topic.unwrap_or_default(),
        is_group: false,
        last_message_time: None,
        last_message_sender: None,
        last_message_preview: None,
    })
}

/// Create (or re-open) a 1:1 chat with `user` (AAD id or UPN) via
/// Graph `POST /me/chats` and return the thread. Empty refs are
/// rejected before any network. Note: Graph mints a new thread
/// per call — no existing-1:1 lookup (minimal path).
pub async fn create_one_to_one_chat_data(
    client: &TeamsClient,
    user: &str,
) -> Result<ChatInfo> {
    if user.trim().is_empty() {
        bail!("empty user");
    }
    let resp = client
        .graph_post(
            one_to_one_create_path(),
            &one_to_one_create_body(user),
        )
        .await?;
    let value: serde_json::Value = resp
        .json()
        .await
        .context("Failed to parse created chat response")?;
    parse_created_chat(&value)
}

// ---------------------------------------------------------------------------
// Group chat create (OstMac core-a, G5)
// ---------------------------------------------------------------------------

/// `POST /chats` path for group creation. Pure so tests pin it.
pub fn group_chat_create_path() -> &'static str {
    "/chats"
}

/// Trim, drop blanks, and de-duplicate user refs (case-insensitive,
/// first spelling wins); `self_id` is removed (it is added as the
/// creator). Pure so tests pin it.
pub fn group_chat_members(self_id: &str, users: &[String]) -> Vec<String> {
    let me = self_id.trim().to_lowercase();
    let mut out: Vec<String> = Vec::new();
    for u in users {
        let t = u.trim();
        if t.is_empty() || t.to_lowercase() == me {
            continue;
        }
        if out.iter().any(|x| x.eq_ignore_ascii_case(t)) {
            continue;
        }
        out.push(t.to_string());
    }
    out
}

/// `POST /chats` body for a group chat: the creator first, then every
/// peer, all with the `owner` role (Graph's group-chat member role);
/// blank topics are omitted. `users` must already be normalized
/// ([`group_chat_members`]). Pure so tests pin it.
pub fn group_chat_create_body(
    self_id: &str,
    users: &[String],
    topic: Option<&str>,
) -> serde_json::Value {
    let member = |u: &str| {
        serde_json::json!({
            "@odata.type": "#microsoft.graph.aadUserConversationMember",
            "roles": ["owner"],
            "user@odata.bind": format!("https://graph.microsoft.com/v1.0/users('{}')", u.trim()),
        })
    };
    let mut members = vec![member(self_id)];
    members.extend(users.iter().map(|u| member(u)));
    let mut body = serde_json::json!({
        "chatType": "group",
        "members": members,
    });
    if let Some(t) = topic.map(str::trim).filter(|t| !t.is_empty()) {
        body["topic"] = serde_json::Value::String(t.to_string());
    }
    body
}

/// Create a group chat with `users` (AAD ids or UPNs) plus the signed-in
/// user, with an optional topic, via Graph `POST /chats`. At least one
/// peer is required (checked before any network); the server enforces
/// its own minimums. Returns the new thread (`is_group` true).
pub async fn create_group_chat_data(
    client: &TeamsClient,
    users: &[String],
    topic: Option<&str>,
) -> Result<ChatInfo> {
    if group_chat_members("", users).is_empty() {
        bail!("no members");
    }
    let me = whoami_data(client).await?;
    let peers = group_chat_members(&me.id, users);
    if peers.is_empty() {
        bail!("no members besides self");
    }
    let resp = client
        .graph_post(
            group_chat_create_path(),
            &group_chat_create_body(&me.id, &peers, topic),
        )
        .await?;
    let value: serde_json::Value = resp
        .json()
        .await
        .context("Failed to parse created chat response")?;
    let mut chat = parse_created_chat(&value)?;
    chat.is_group = true;
    Ok(chat)
}

// ---------------------------------------------------------------------------
// Chat roster (OstMac core-a)
// ---------------------------------------------------------------------------

/// One chat member. `mri` is the chat-service identity
/// (`8:orgid:<guid>`); `user_id` the Graph/AAD id (presence key).
/// `is_owner` is id-based: Graph `roles` contains `owner`, or the
/// chat-service role is `Admin`. `display_name` may be "" (chat
/// service rosters carry no names — the embedder resolves them).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatMemberInfo {
    pub mri: String,
    pub user_id: Option<String>,
    pub display_name: String,
    pub email: Option<String>,
    pub roles: Vec<String>,
    pub is_owner: bool,
}

/// Graph `GET /chats/{id}/members` path. Pure so tests pin it.
pub fn chat_members_path(chat_id: &str) -> String {
    format!("/chats/{}/members", chat_id.trim())
}

/// AAD object id from an orgid MRI (`8:orgid:<guid>` → `<guid>`).
fn oid_from_orgid_mri(mri: &str) -> Option<String> {
    let t = mri.trim();
    let rest = t.get(..8).filter(|p| p.eq_ignore_ascii_case("8:orgid:")).map(|_| &t[8..])?;
    let rest = rest.trim();
    if rest.is_empty() {
        None
    } else {
        Some(rest.to_string())
    }
}

/// Parse a Graph `conversationMember` collection (`{value:[…]}`).
/// Entries without a `userId` are skipped (bots/guests we cannot key).
/// Pure so tests pin it.
pub fn parse_graph_chat_members(value: &serde_json::Value) -> Result<Vec<ChatMemberInfo>> {
    let list = value
        .get("value")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow::anyhow!("chat members response has no value[]"))?;
    let mut out = Vec::new();
    for e in list {
        let Some(o) = e.as_object() else { continue };
        let Some(user_id) = obj_str_ci(o, "userId") else { continue };
        let roles: Vec<String> = obj_get_ci(o, "roles")
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|r| r.as_str())
                    .map(|r| r.trim().to_lowercase())
                    .filter(|r| !r.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        let is_owner = roles.iter().any(|r| r == "owner");
        out.push(ChatMemberInfo {
            mri: format!("8:orgid:{}", user_id),
            user_id: Some(user_id),
            display_name: obj_str_ci(o, "displayName").unwrap_or_default(),
            email: obj_str_ci(o, "email"),
            roles,
            is_owner,
        });
    }
    Ok(out)
}

/// Parse a chat-service `GET /v1/threads/{id}/members` body. Roles
/// lowercase (`admin`/`user`); `admin` is the owner. Blank ids skip.
/// Pure so tests pin it.
pub fn parse_thread_members(value: &serde_json::Value) -> Result<Vec<ChatMemberInfo>> {
    let body: ThreadMembersResponse = serde_json::from_value(value.clone())
        .context("Failed to parse thread members response")?;
    Ok(body
        .members
        .unwrap_or_default()
        .into_iter()
        .filter_map(|m| {
            let mri = m.id.map(|s| s.trim().to_string()).filter(|s| !s.is_empty())?;
            let roles: Vec<String> = m
                .role
                .map(|r| r.trim().to_lowercase())
                .filter(|r| !r.is_empty())
                .into_iter()
                .collect();
            let is_owner = roles.iter().any(|r| r == "admin");
            Some(ChatMemberInfo {
                user_id: oid_from_orgid_mri(&mri),
                mri,
                display_name: m.friendly_name.map(|s| s.trim().to_string()).unwrap_or_default(),
                email: None,
                roles,
                is_owner,
            })
        })
        .collect())
}

/// Where a roster came from (names are only on the Graph path).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RosterSource {
    Graph,
    ChatService,
}

/// Roster for one chat: Graph `GET /chats/{id}/members` (names, emails,
/// owner roles) first; on any Graph failure, the chat-service thread
/// roster (MRIs + Admin/User roles, skypetoken auth). Both failing
/// returns the chat-service error.
pub async fn list_chat_members_data(
    client: &TeamsClient,
    chat_id: &str,
) -> Result<(RosterSource, Vec<ChatMemberInfo>)> {
    if chat_id.trim().is_empty() {
        bail!("empty chat_id");
    }
    let graph = async {
        let resp = client.graph_get(&chat_members_path(chat_id)).await?;
        let v: serde_json::Value = resp.json().await.context("chat members json")?;
        parse_graph_chat_members(&v)
    }
    .await;
    match graph {
        Ok(m) if !m.is_empty() => return Ok((RosterSource::Graph, m)),
        Ok(_) => tracing::debug!("graph chat roster empty, trying chat service"),
        Err(e) => tracing::debug!("graph chat roster failed: {:#}", e),
    }
    let url = format!("{}/v1/threads/{}/members", client.chat_service_url(), chat_id.trim());
    let resp = client.chat_get(&url).await?;
    let v: serde_json::Value = resp
        .json()
        .await
        .context("Failed to parse thread members response")?;
    Ok((RosterSource::ChatService, parse_thread_members(&v)?))
}

/// List recent chats and return structured data.
///
/// 1:1 chats without a topic are named after the mate (roster MRI
/// minus self, attributed through message history); every other
/// fallback is topic → last sender → system label, never a raw id.
/// Mate resolution is best-effort: roster/history/whoami failures
/// keep the sender/label fallback, never fail the list.
pub async fn list_chats_data(client: &TeamsClient, limit: usize) -> Result<Vec<ChatInfo>> {
    // Strategy 1: CSA AFD endpoint with Bearer auth
    let csa_url = format!(
        "https://teams.microsoft.com/api/csa/api/v1/teams/users/ME/conversations?view=mychats&pageSize={}",
        limit
    );
    tracing::debug!("Trying CSA endpoint: {}", csa_url);
    let resp = match client.csa_get(&csa_url).await {
        Ok(r) => r,
        Err(e) => {
            tracing::debug!("CSA endpoint failed: {:#}, trying chatsvcagg", e);
            // Strategy 2: chatsvcagg with skypetoken auth
            let base = client.chatsvcagg_url();
            let url = format!(
                "{}/api/v2/users/ME/conversations?view=mychats&pageSize={}",
                base, limit
            );
            tracing::debug!("Trying chatsvcagg: {}", url);
            match client.chat_get(&url).await {
                Ok(r) => r,
                Err(e2) => {
                    tracing::debug!("chatsvcagg failed: {:#}, trying chat service", e2);
                    // Strategy 3: chat service (amer.ng.msg) with skypetoken auth
                    let base = client.chat_service_url();
                    let url = format!(
                        "{}/v1/users/ME/conversations?view=mychats&pageSize={}",
                        base, limit
                    );
                    client.chat_get(&url).await?
                }
            }
        }
    };

    let body: ConversationsResponse = resp
        .json()
        .await
        .context("Failed to parse conversations response")?;

    let conversations = body.conversations.unwrap_or_default();

    let mut chats = Vec::new();
    // (chat index, conversation index) for 1:1 chats without a topic:
    // the mate name resolves after the first pass (needs whoami OID).
    let mut needs_mate: Vec<(usize, usize)> = Vec::new();
    for (ci, conv) in conversations.iter().enumerate() {
        let id = conv.id.as_deref().unwrap_or("").to_string();
        if id.is_empty() {
            continue;
        }

        let name = conversation_name(conv, None);
        let topic_missing = conv
            .thread_properties
            .as_ref()
            .and_then(|p| p.topic.as_deref())
            .map(|t| t.trim().is_empty())
            .unwrap_or(true);
        if topic_missing && is_onetoone_id(&id) {
            needs_mate.push((chats.len(), ci));
        }
        let is_group = id.contains("thread") || id.contains("meeting");

        let (last_time, last_sender, last_preview) = if let Some(ref msg) = conv.last_message {
            let time = msg
                .original_arrival_time
                .as_deref()
                .or(msg.compose_time.as_deref())
                .map(String::from);
            let sender = msg.im_display_name.clone();
            let preview = msg.content.as_deref().map(|c| {
                let text = strip_html(c);
                if text.len() > 80 {
                    let end = text
                        .char_indices()
                        .map(|(i, _)| i)
                        .take_while(|&i| i <= 77)
                        .last()
                        .unwrap_or(0);
                    format!("{}...", &text[..end])
                } else {
                    text
                }
            });
            (time, sender, preview)
        } else {
            (None, None, None)
        };

        chats.push(ChatInfo {
            id,
            name,
            is_group,
            last_message_time: last_time,
            last_message_sender: last_sender,
            last_message_preview: last_preview,
        });
    }

    // Second pass: 1:1 mate names via MRI resolve. One whoami for the
    // owner OID, then per-chat roster + history attribution. Any
    // failure keeps the first-pass name — the list never fails here.
    if !needs_mate.is_empty() {
        if let Ok(me) = whoami_data(client).await {
            for (chat_idx, conv_idx) in needs_mate {
                let chat_id = chats[chat_idx].id.clone();
                if let Some(mate) = resolve_mate_name(client, &chat_id, &me.id).await {
                    let conv = &conversations[conv_idx];
                    chats[chat_idx].name = conversation_name(conv, Some(&mate));
                } else {
                    tracing::debug!("mate resolve failed for {}", chat_id);
                }
            }
        }
    }

    Ok(chats)
}

/// Read messages from a specific chat thread and return structured data.
///
/// Newest page only; use [`read_messages_page`] with the returned
/// `backward_link` to walk older history.
pub async fn read_messages_data(
    client: &TeamsClient,
    chat_id: &str,
    limit: usize,
) -> Result<Vec<MessageInfo>> {
    Ok(read_messages_page(client, chat_id, limit, None)
        .await?
        .messages)
}

/// Read one page of history. `page_url` is None for the newest page or
/// Some(previous `backward_link`) for the next older page. Messages come
/// back oldest-first; pages never overlap (verified live 2026-09-22).
pub async fn read_messages_page(
    client: &TeamsClient,
    chat_id: &str,
    limit: usize,
    page_url: Option<&str>,
) -> Result<MessagesPage> {
    let url = match page_url {
        Some(u) => with_page_size(u, limit),
        None => {
            let base = client.chat_service_url();
            format!(
                "{}/v1/users/ME/conversations/{}/messages?pageSize={}",
                base, chat_id, limit
            )
        }
    };

    tracing::debug!("Reading messages from {}", url);
    let resp = client.chat_get(&url).await?;
    let body: MessagesResponse = resp
        .json()
        .await
        .context("Failed to parse messages response")?;

    let messages = body.messages.unwrap_or_default();

    // Messages come newest-first; reverse for chronological display
    let mut msgs: Vec<&NativeMessage> = messages.iter().collect();
    msgs.reverse();

    let mut result = Vec::new();
    for msg in &msgs {
        let msgtype = msg.messagetype.as_deref().unwrap_or("");
        if !message_type_kept(msgtype) {
            continue;
        }

        let sender = msg
            .im_display_name
            .as_deref()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or("?")
            .to_string();
        let sender_mri = mri_from_user_link(msg.from.as_deref());
        let time = msg
            .original_arrival_time
            .as_deref()
            .or(msg.compose_time.as_deref())
            .unwrap_or("")
            .to_string();
        let content = msg.content.as_deref().unwrap_or("");
        // OstMac om-replies: split the quote block first so `content` is
        // the reply body only; the parent id rides `reply_to`.
        // OstMac om-lt2-quotelink: channel threads carry no quote block —
        // fall back to the wire parent (`rootMessageId` / `replyToId`).
        let (quote_parent, body_html) = split_reply_quote(content);
        let wire_parent = message_parent_id(msg);
        let mut reply_to = quote_parent.or(wire_parent);
        let text = strip_html(&body_html);

        // OstMac om-richmedia: image-only bubbles strip to "" but are
        // real messages — keep them (the embedder mines `<img>` from raw).
        // OstMac om-botposts: same for RSS/bot/card posts — attachment and
        // card payloads strip to "" but the embedder renders them as
        // title+link rows (or a placeholder when unparseable).
        if text.trim().is_empty() && !has_image(content) && !has_card_payload(content) {
            continue;
        }

        // OstMac: keep the server id so embedders can match realtime edits.
        let id = msg.id.as_deref().filter(|s| !s.is_empty()).map(String::from);
        let id = id.unwrap_or_else(|| format!("{}@{}", time, sender));
        // Self/blank parents never link (corrupt wire id guard).
        if reply_to
            .as_deref()
            .map(|p| p.trim().is_empty() || p == id)
            .unwrap_or(false)
        {
            reply_to = None;
        }
        let reactions = message_reactions(msg);
        result.push(MessageInfo {
            id,
            sender_mri,
            sender,
            timestamp: time,
            content: text.trim().to_string(),
            raw: content.to_string(),
            reactions,
            reply_to,
        });
    }

    let backward_link = body.metadata.and_then(|m| m.backward_link);
    Ok(MessagesPage {
        messages: result,
        backward_link,
    })
}

/// Type gate for history messages (pure so tests pin it).
///
/// Keeps Text/RichText, including RichText/Media_Card: bot/card posts
/// (RSS, roadmap, connector cards) strip to their readable summary
/// text, and whole channels carry nothing else — dropping them renders
/// long channels blank (H0: 100 raw Media_Card → 0 kept). Still drops
/// RichText/Media_CallRecording (strips to "TitlePlay" fragments) and
/// RichText/Media_CallTranscript (strips to raw JSON), which are not
/// readable bubbles (see task-0011), plus all ThreadActivity/* noise.
fn message_type_kept(messagetype: &str) -> bool {
    if !messagetype.contains("Text") && !messagetype.contains("RichText") {
        return false;
    }
    if messagetype.contains("Media_") && !messagetype.contains("Media_Card") {
        return false;
    }
    true
}

/// True when raw content carries an RSS/bot/card payload: an
/// `<attachment>` block (case-insensitive) or a card content-type marker
/// (O365 connector / Adaptive / MessageCard). Such posts strip to empty
/// text but must survive filtering — the embedder renders title+link
/// rows from the payload, or a placeholder when it cannot parse it.
fn has_card_payload(html: &str) -> bool {
    let lower = html.to_lowercase();
    lower.contains("<attachment")
        || lower.contains("o365connector")
        || lower.contains("adaptivecard")
        || lower.contains("messagecard")
        || lower.contains("application/vnd.microsoft")
}

/// True when raw HTML carries an `<img` tag (case-insensitive).
/// Image-only messages strip to empty text but must survive filtering.
fn has_image(html: &str) -> bool {
    html.as_bytes()
        .windows(4)
        .any(|w| w.eq_ignore_ascii_case(b"<img"))
}

/// Rewrite the `pageSize=` query value so a followed `backwardLink` honors
/// the caller's limit. No-op when the marker is absent.
fn with_page_size(url: &str, limit: usize) -> String {
    const MARK: &str = "pageSize=";
    let Some(start) = url.find(MARK) else {
        return url.to_string();
    };
    let val_start = start + MARK.len();
    let val_end = url[val_start..]
        .find(|c: char| !c.is_ascii_digit())
        .map(|i| val_start + i)
        .unwrap_or(url.len());
    format!("{}{}{}", &url[..val_start], limit, &url[val_end..])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_to_one_create_shape() {
        assert_eq!(one_to_one_create_path(), "/me/chats");
        let b = one_to_one_create_body("  aad-1 ");
        assert_eq!(b["chatType"], "oneOnOne");
        let m = &b["members"][0];
        assert_eq!(
            m["@odata.type"],
            "#microsoft.graph.aadUserConversationMember"
        );
        assert_eq!(m["roles"][0], "owner");
        assert_eq!(
            m["user@odata.bind"],
            "https://graph.microsoft.com/v1.0/users('aad-1')"
        );
    }

    #[test]
    fn created_chat_parse_tolerates_shapes() {
        let v: serde_json::Value =
            serde_json::from_str(r#"{"id":"19:one@unq.v1"}"#).unwrap();
        let c = parse_created_chat(&v).unwrap();
        assert_eq!(c.id, "19:one@unq.v1");
        assert_eq!(c.name, "");
        assert!(!c.is_group);
        let v: serde_json::Value =
            serde_json::from_str(r#"{"id":"19:g@t","topic":"T"}"#).unwrap();
        assert_eq!(parse_created_chat(&v).unwrap().name, "T");
        let v: serde_json::Value = serde_json::from_str(r#"{"nope":1}"#).unwrap();
        assert!(parse_created_chat(&v).is_err());
    }

    #[test]
    fn edit_url_and_body_shape() {
        assert_eq!(
            message_url("https://h", "19:chat", "123"),
            "https://h/v1/users/ME/conversations/19:chat/messages/123"
        );
        let b = edit_message_body("123", "a<b>&\"'");
        assert_eq!(b["messagetype"], "RichText/Html");
        assert_eq!(b["contenttype"], "text");
        assert_eq!(b["skypeeditedid"], "123");
        assert_eq!(
            b["content"],
            "<p>a&lt;b&gt;&amp;&quot;&#39;</p>"
        );
    }

    #[test]
    fn leave_url_and_mri_shape() {
        assert_eq!(own_member_mri("abc-123"), "8:orgid:abc-123");
        assert_eq!(own_member_mri("  abc-123  "), "8:orgid:abc-123");
        assert_eq!(
            leave_member_url("https://h", "19:t@thread.v2", "8:orgid:abc-123"),
            "https://h/v1/threads/19:t@thread.v2/members/8:orgid:abc-123"
        );
    }

    #[test]
    fn message_type_gate_keeps_cards_drops_noise() {
        // Plain + rich text always kept.
        assert!(message_type_kept("Text"));
        assert!(message_type_kept("RichText/Html"));
        // Cards kept: whole bot channels carry nothing else.
        assert!(message_type_kept("RichText/Media_Card"));
        // Call media still dropped (unreadable strips, task-0011).
        assert!(!message_type_kept("RichText/Media_CallRecording"));
        assert!(!message_type_kept("RichText/Media_CallTranscript"));
        // Unknown Media_* stays dropped (unprobed shapes).
        assert!(!message_type_kept("RichText/Media_Poll"));
        // ThreadActivity noise dropped; empty type dropped.
        assert!(!message_type_kept("ThreadActivity/AddMember"));
        assert!(!message_type_kept("ThreadActivity/DeleteMember"));
        assert!(!message_type_kept(""));
    }

    #[test]
    fn image_tag_detection() {
        assert!(has_image(r#"<p><img src="https://h/v1/objects/0/views/imgo"></p>"#));
        assert!(has_image(r#"<IMG SRC="https://h/x.png">"#));
        assert!(has_image(r#"<p>hi <img
src="x">"#));
        assert!(!has_image("<p>plain text</p>"));
        assert!(!has_image("<p>image word, no tag</p>"));
        assert!(!has_image(""));
    }

    #[test]
    fn card_payload_detection() {
        // Empty placeholder attachment (server holds the card): kept.
        assert!(has_card_payload(r#"<attachment id="abc123"></attachment>"#));
        assert!(has_card_payload(
            r#"<p>digest</p><ATTACHMENT><p><a href="https://h/a">Post A</a></p></ATTACHMENT>"#
        ));
        // Card content-type markers in any casing: kept.
        assert!(has_card_payload(
            r#"{"@type":"MessageCard","title":"Build green"}"#
        ));
        assert!(has_card_payload(
            r#"<div data-contenttype="application/vnd.microsoft.card.adaptive"></div>"#
        ));
        assert!(has_card_payload("connector o365connector card"));
        // Plain text, bare images, and empty payloads: not cards.
        assert!(!has_card_payload("<p>plain text</p>"));
        assert!(!has_card_payload(r#"<p><img src="https://h/x.png"></p>"#));
        assert!(!has_card_payload(""));
        assert!(!has_card_payload("   "));
    }

    #[test]
    fn page_size_rewrite_mid_and_end() {
        assert_eq!(
            with_page_size("https://h/m?pageSize=2&view=x", 50),
            "https://h/m?pageSize=50&view=x"
        );
        assert_eq!(
            with_page_size("https://h/m?view=x&pageSize=2", 50),
            "https://h/m?view=x&pageSize=50"
        );
        assert_eq!(with_page_size("https://h/m", 50), "https://h/m");
    }

    #[test]
    fn reply_snippet_collapses_and_truncates() {
        assert_eq!(reply_snippet("hi"), "hi");
        assert_eq!(reply_snippet("a  b\n\tc"), "a b c");
        assert_eq!(reply_snippet("  padded  "), "padded");
        let long = "w".repeat(200);
        let snip = reply_snippet(&long);
        assert_eq!(snip.chars().count(), REPLY_SNIPPET_MAX + 1);
        assert!(snip.ends_with('…'));
        // Multibyte cut lands on a char boundary (no panic, exact width).
        let uni = "é".repeat(200);
        let usnip = reply_snippet(&uni);
        assert_eq!(usnip.chars().count(), REPLY_SNIPPET_MAX + 1);
    }

    #[test]
    fn reply_html_round_trips_through_split() {
        let html = build_reply_html("m1", "Megan Harper", "Ship <it> & go", "On it!");
        assert!(html.contains("<quote"), "{}", html);
        assert!(html.contains("&lt;it&gt; &amp; go"), "{}", html);
        let (parent, body) = split_reply_quote(&html);
        assert_eq!(parent.as_deref(), Some("m1"));
        assert_eq!(strip_html(&body).trim(), "On it!");
    }

    #[test]
    fn split_quote_rejects_malformed() {
        let (p, b) = split_reply_quote("<p>plain</p>");
        assert_eq!(p, None);
        assert_eq!(b, "<p>plain</p>");
        // Unterminated quote: keep the whole content, no parent.
        let (p, b) = split_reply_quote("<quote guid=\"m1\"><p>oops</p>");
        assert_eq!(p, None);
        assert_eq!(b, "<quote guid=\"m1\"><p>oops</p>");
        // Quote without guid still strips (body-only bubble, unknown parent).
        let (p, b) = split_reply_quote("<quote author=\"A\">old</quote><p>new</p>");
        assert_eq!(p, None);
        assert_eq!(strip_html(&b).trim(), "new");
        // Single-quoted guid parses.
        let (p, _) = split_reply_quote("<quote guid='m9'>x</quote><p>y</p>");
        assert_eq!(p.as_deref(), Some("m9"));
    }

    #[test]
    fn metadata_backward_link_parses() {
        let body: MessagesResponse = serde_json::from_str(
            r#"{"messages":[],"_metadata":{"backwardLink":"https://h/back"},"tenantId":"t"}"#,
        )
        .unwrap();
        assert_eq!(
            body.metadata.unwrap().backward_link.as_deref(),
            Some("https://h/back")
        );
        let bare: MessagesResponse = serde_json::from_str(r#"{"messages":[]}"#).unwrap();
        assert!(bare.metadata.is_none());
    }

    #[test]
    fn reaction_emoji_round_trip() {
        assert_eq!(REACTION_EMOJI.len(), 6);
        for (emoji, rtype) in REACTION_EMOJI {
            assert_eq!(reaction_type_for_emoji(emoji), Some(*rtype));
            assert_eq!(emoji_for_reaction_type(rtype), Some(*emoji));
        }
        assert_eq!(reaction_type_for_emoji("🎉"), None);
        assert_eq!(reaction_type_for_emoji(""), None);
        assert_eq!(emoji_for_reaction_type("party"), None);
        assert_eq!(emoji_for_reaction_type("LIKE"), Some("👍"));
    }

    #[test]
    fn reaction_endpoint_shapes() {
        let base = "https://h";
        assert_eq!(
            reaction_add_url(base, "19:thread", "42"),
            "https://h/v1/users/ME/conversations/19:thread/messages/42/reactions"
        );
        assert_eq!(
            reaction_add_body("like"),
            serde_json::json!({ "reactionType": "like" })
        );
        assert_eq!(
            reaction_remove_url(base, "19:thread", "42", "like"),
            "https://h/v1/users/ME/conversations/19:thread/messages/42/reactions/like"
        );
    }

    fn reacted(content: &str, reactions_json: &str, via_properties: bool) -> NativeMessage {
        let payload = if via_properties {
            format!(
                r#"{{"id":"1","messagetype":"RichText/Html","content":{},"properties":{{"reactions":{}}}}}"#,
                serde_json::to_string(content).unwrap(),
                reactions_json
            )
        } else {
            format!(
                r#"{{"id":"1","messagetype":"RichText/Html","content":{},"reactions":{}}}"#,
                serde_json::to_string(content).unwrap(),
                reactions_json
            )
        };
        serde_json::from_str(&payload).unwrap()
    }

    #[test]
    fn reactions_group_in_picker_order() {
        let msg = reacted(
            "<p>hi</p>",
            r#"[{"reactionType":"laugh"},{"reactionType":"like"},{"reactionType":"like"}]"#,
            false,
        );
        assert_eq!(
            message_reactions(&msg),
            vec![
                ReactionCount {
                    emoji: "👍".to_string(),
                    count: 2,
                    reactors: vec![]
                },
                ReactionCount {
                    emoji: "😂".to_string(),
                    count: 1,
                    reactors: vec![]
                },
            ]
        );
    }

    #[test]
    fn reactions_nested_and_unknown_shapes() {
        // properties.reactions nesting works; unknown/missing types drop.
        let msg = reacted(
            "<p>hi</p>",
            r#"[{"reactionType":"Heart"},{"reactionType":"party"},{"reactionType":null},{}]"#,
            true,
        );
        assert_eq!(
            message_reactions(&msg),
            vec![ReactionCount {
                emoji: "❤️".to_string(),
                count: 1,
                reactors: vec![]
            }]
        );
        // No reactions key at all → empty, old payloads unaffected.
        let bare: NativeMessage =
            serde_json::from_str(r#"{"id":"1","content":"<p>hi</p>"}"#).unwrap();
        assert!(message_reactions(&bare).is_empty());
    }

    #[test]
    fn strip_html_block_boundaries_space_words() {
        // Tag-boundary glue: block boundaries separate words…
        assert_eq!(strip_html("<p>Hello</p><p>World</p>"), "Hello World");
        assert_eq!(strip_html("<div>a</div><div>b</div>"), "a b");
        assert_eq!(strip_html("a<br>b"), "a b");
        assert_eq!(strip_html("a<br/>b"), "a b");
        assert_eq!(strip_html("<ul><li>a</li><li>b</li></ul>"), "a b");
        // …but add no leading/trailing space…
        assert_eq!(strip_html("<p>hi</p>"), "hi");
        assert_eq!(strip_html(""), "");
        // …never double existing whitespace…
        assert_eq!(strip_html("<p>a</p> <p>b</p>"), "a b");
        assert_eq!(strip_html("a  <p>b"), "a  b");
        // …and leave inline tags glued.
        assert_eq!(strip_html("a<b>x</b>b"), "axb");
        assert_eq!(strip_html("<p>Hi <at id=\"8:x\">Bo</at>!</p>"), "Hi Bo!");
        // Attributes, case, and entities still handled.
        assert_eq!(strip_html("<P CLASS=\"x\">a</P><p>b</p>"), "a b");
        assert_eq!(strip_html("<p>a &amp; b</p>"), "a & b");
    }

    fn conv(json: &str) -> Conversation {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn conversation_name_never_raw_id() {
        // Topic wins over everything.
        let c = conv(
            r#"{"id":"19:t@thread.v2","threadProperties":{"topic":"Ship it"},
                "lastMessage":{"imdisplayname":"A"}}"#,
        );
        assert_eq!(conversation_name(&c, Some("Mate")), "Ship it");
        // Resolved mate beats last sender (1:1 named after self otherwise).
        let c = conv(
            r#"{"id":"19:a@unq.gbl.spaces","lastMessage":{"imdisplayname":"Self, Pat"}}"#,
        );
        assert_eq!(conversation_name(&c, Some("Mate, Sam")), "Mate, Sam");
        assert_eq!(conversation_name(&c, None), "Self, Pat");
        // Blank topic/mate/sender fall through to the system label.
        let c = conv(
            r#"{"id":"19:a@unq.gbl.spaces","threadProperties":{"topic":"  "},
                "lastMessage":{"imdisplayname":""}}"#,
        );
        assert_eq!(conversation_name(&c, Some(" ")), "[Direct message]");
        // Shape-based labels, never the id.
        for (id, want) in [
            ("19:a@unq.gbl.spaces", "[Direct message]"),
            ("19:t@thread.v2", "[Group chat]"),
            ("19:meeting_x@thread.v2", "[Meeting chat]"),
            ("48:notifications", "Notifications"),
            ("48:mentions", "Mentions"),
            ("48:notes", "Notes"),
            ("weird", "[Chat]"),
        ] {
            let c = conv(&format!(r#"{{"id":"{}"}}"#, id));
            let name = conversation_name(&c, None);
            assert_eq!(name, want);
            assert!(!name.contains(id), "raw id leaks: {}", name);
        }
        // Missing id entirely still labels.
        let c: Conversation = serde_json::from_str(r#"{}"#).unwrap();
        assert_eq!(conversation_name(&c, None), "[Chat]");
    }

    #[test]
    fn mri_helpers_parse_and_match() {
        // Sender MRI = last `from` segment, percent-decoded.
        assert_eq!(
            mri_from_user_link(Some(
                "https://h/v1/users/ME/contacts/8:orgid:abc-123"
            )),
            "8:orgid:abc-123"
        );
        assert_eq!(
            mri_from_user_link(Some("https://h/v1/users/8%3Aorgid%3Aabc")),
            "8:orgid:abc"
        );
        assert_eq!(mri_from_user_link(None), "");
        assert_eq!(mri_from_user_link(Some("")), "");
        // Malformed % runs pass through.
        assert_eq!(percent_decode("a%2Fb%zzc%"), "a/b%zzc%");
        // Self match: exact or OID suffix, case-insensitive, never empty.
        assert!(mri_is_self("8:orgid:ABC-123", "abc-123"));
        assert!(mri_is_self("abc-123", "ABC-123"));
        assert!(!mri_is_self("8:orgid:abc-123", "other-oid"));
        assert!(!mri_is_self("8:orgid:abc-123", ""));
        assert!(!mri_is_self("", "abc-123"));
        // 1:1 id shapes.
        assert!(is_onetoone_id("19:a_b@unq.gbl.spaces"));
        assert!(!is_onetoone_id("19:t@thread.v2"));
        assert!(!is_onetoone_id("19:meeting_x@thread.v2"));
        assert!(!is_onetoone_id("48:notes"));
        // Roster payload parses (member MRI = `id`).
        let roster: ThreadMembersResponse = serde_json::from_str(
            r#"{"totalMemberCount":2,"members":[{"id":"8:orgid:self"},{"id":"8:orgid:mate"}],"isDeleted":false}"#,
        )
        .unwrap();
        let ids: Vec<_> = roster
            .members
            .unwrap()
            .into_iter()
            .filter_map(|m| m.id)
            .collect();
        assert_eq!(ids, vec!["8:orgid:self", "8:orgid:mate"]);
    }

    #[test]
    fn receipt_endpoint_shapes() {
        let base = "https://h";
        assert_eq!(
            consumptionhorizon_url(base, "19:t@thread.v2"),
            "https://h/v1/users/ME/conversations/19:t@thread.v2/properties?name=consumptionhorizon"
        );
        assert_eq!(
            consumptionhorizons_url(base, "19:t@thread.v2"),
            "https://h/v1/threads/19:t@thread.v2/consumptionhorizons"
        );
        assert_eq!(
            consumptionhorizon_value("m42", 1700000000000),
            "1700000000000;1700000000000;m42"
        );
        assert_eq!(
            consumptionhorizon_body("m42", 7),
            serde_json::json!({ "consumptionhorizon": "7;7;m42" })
        );
    }

    #[test]
    fn receipt_message_id_splits_last_segment() {
        assert_eq!(
            receipt_message_id("1;2;m42").as_deref(),
            Some("m42")
        );
        assert_eq!(receipt_message_id("m42").as_deref(), Some("m42"));
        assert_eq!(receipt_message_id(" 1;2; m42 ").as_deref(), Some("m42"));
        assert_eq!(receipt_message_id(""), None);
        assert_eq!(receipt_message_id("   "), None);
        assert_eq!(receipt_message_id("1;2;"), None);
    }

    #[test]
    fn receipt_parse_tolerates_shapes() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{"id":"19:t@thread.v2","version":"1","consumptionhorizons":[
                {"mri":"8:orgid:a","consumptionhorizon":"1;2;m1"},
                {"user":"Bo","consumptionhorizon":"3;4;m2"},
                "5;6;m3",
                {"mri":"8:orgid:bad","consumptionhorizon":""},
                {"mri":"8:orgid:nohorizon"}
            ]}"#,
        )
        .unwrap();
        let out = parse_consumptionhorizons(&v);
        assert_eq!(out.len(), 3);
        assert_eq!(
            out[0],
            ReadReceipt {
                user: "8:orgid:a".to_string(),
                message_id: "m1".to_string(),
                horizon: "1;2;m1".to_string(),
            }
        );
        assert_eq!(out[1].user, "Bo");
        assert_eq!(out[1].message_id, "m2");
        assert_eq!(out[2].user, "");
        assert_eq!(out[2].message_id, "m3");
        // Missing/empty lists yield empty, never panic.
        let missing: serde_json::Value = serde_json::from_str(r#"{"id":"x"}"#).unwrap();
        assert!(parse_consumptionhorizons(&missing).is_empty());
        let empty: serde_json::Value =
            serde_json::from_str(r#"{"consumptionhorizons":[]}"#).unwrap();
        assert!(parse_consumptionhorizons(&empty).is_empty());
    }

    fn native(json: &str) -> NativeMessage {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn channel_parent_top_level_root_message_id() {
        let m = native(
            r#"{"id":"r1","messagetype":"RichText/Html","content":"<p>reply</p>","rootMessageId":"m1"}"#,
        );
        assert_eq!(message_parent_id(&m).as_deref(), Some("m1"));
        // Graph casing variant.
        let m = native(
            r#"{"id":"r1","messagetype":"RichText/Html","content":"<p>reply</p>","replyToId":"m2"}"#,
        );
        assert_eq!(message_parent_id(&m).as_deref(), Some("m2"));
        // Lowercase wire variant.
        let m = native(
            r#"{"id":"r1","messagetype":"RichText/Html","content":"<p>reply</p>","rootmessageid":"m3"}"#,
        );
        assert_eq!(message_parent_id(&m).as_deref(), Some("m3"));
    }

    #[test]
    fn channel_parent_nested_properties_and_content() {
        // properties.replyToId nesting.
        let m = native(
            r#"{"id":"r1","messagetype":"RichText/Media_Card","content":"<p>reply</p>","properties":{"replyToId":"m9"}}"#,
        );
        assert_eq!(message_parent_id(&m).as_deref(), Some("m9"));
        // Content-embedded JSON form (Media_Card payloads).
        let m = native(
            r#"{"id":"r2","messagetype":"RichText/Media_Card","content":"{\"rootMessageId\":\"m7\",\"body\":\"hi\"}"}"#,
        );
        assert_eq!(message_parent_id(&m).as_deref(), Some("m7"));
        // Content-embedded attr form.
        assert_eq!(
            parent_id_from_content(r#"<msg rootMessageId="m5">hi</msg>"#).as_deref(),
            Some("m5")
        );
    }

    #[test]
    fn channel_parent_missing_is_none_never_crash() {
        let m = native(r#"{"id":"m1","content":"<p>plain</p>"}"#);
        assert_eq!(message_parent_id(&m), None);
        // Empty / null / numeric-adjacent shapes.
        let m = native(
            r#"{"id":"m1","content":"<p>x</p>","rootMessageId":"  "}"#,
        );
        assert_eq!(message_parent_id(&m), None);
        let m = native(r#"{"id":"m1","content":"<p>x</p>","rootMessageId":null}"#);
        assert_eq!(message_parent_id(&m), None);
        assert_eq!(parent_id_from_content(""), None);
        assert_eq!(parent_id_from_content("<p>no keys here</p>"), None);
        assert_eq!(parent_id_from_content(r#"rootMessageId="m1"#), None);
    }

    // wire-pre lane: fenced blocks go out as <pre> (other clients keep
    // indents); prose keeps the legacy single-<p> shape bit-identical.

    #[test]
    fn wire_prose_unchanged_single_p() {
        assert_eq!(build_message_html("hi"), "<p>hi</p>");
        assert_eq!(
            build_message_html("a<b>&\"'\nline2  indented"),
            "<p>a&lt;b&gt;&amp;&quot;&#39;\nline2  indented</p>"
        );
        // Inline backticks and short runs are not fences.
        assert_eq!(build_message_html("use `x` here"), "<p>use `x` here</p>");
        assert_eq!(build_message_html("a\n``\nb"), "<p>a\n``\nb</p>");
        // Info string containing the fence char: not a fence (CommonMark).
        assert_eq!(
            build_message_html("``` `x` ```\nstill prose"),
            "<p>``` `x` ```\nstill prose</p>"
        );
    }

    #[test]
    fn wire_fenced_block_byte_exact_pre() {
        // Captured wire body: exact JSON `chat_post` receives.
        let body = send_message_body("```swift\nlet x  =  1\n\tindented\n```");
        assert_eq!(body["messagetype"], "RichText/Html");
        assert_eq!(body["contenttype"], "text");
        assert_eq!(body["content"], "<pre>let x  =  1\n\tindented</pre>");
        // Escaping still applies inside <pre>; fences + info consumed.
        let body = send_message_body("```\na<b>&\"'\n```");
        assert_eq!(body["content"], "<pre>a&lt;b&gt;&amp;&quot;&#39;</pre>");
        // ~~~ fences + indented fence lines work.
        let body = send_message_body("  ~~~py\nx = 1\n  ~~~");
        assert_eq!(body["content"], "<pre>x = 1</pre>");
    }

    #[test]
    fn wire_mixed_prose_and_code_segments() {
        assert_eq!(
            build_message_html("hi\n```\ncode  x\n```\nbye"),
            "<p>hi</p><pre>code  x</pre><p>bye</p>"
        );
        // Longer runs need equally long closers; inner short runs stay code.
        assert_eq!(
            build_message_html("````\n```\ninner\n```\n````"),
            "<pre>```\ninner\n```</pre>"
        );
    }

    #[test]
    fn wire_unclosed_fence_runs_to_end() {
        // Swift CodeBlocks parity: mid-typing states stay code.
        assert_eq!(
            build_message_html("note\n```\nline1\nline2"),
            "<p>note</p><pre>line1\nline2</pre>"
        );
    }

    #[test]
    fn wire_fence_cap_leaves_extras_prose() {
        let mut msg = String::new();
        for i in 0..(WIRE_FENCE_MAX_BLOCKS + 1) {
            msg.push_str(&format!("```\nc{}\n```\n", i));
        }
        let html = build_message_html(&msg);
        assert_eq!(html.matches("<pre>").count(), WIRE_FENCE_MAX_BLOCKS);
        // 51st block never parsed: its fences stay literal prose, nothing lost.
        assert!(html.contains("```\nc50\n```"), "{}", html);
    }

    #[test]
    fn wire_reply_and_edit_carry_pre() {
        let html = build_reply_html("m1", "A", "parent", "```\ncode\n```");
        assert!(html.starts_with("<quote"), "{}", html);
        assert!(html.contains("<pre>code</pre>"), "{}", html);
        // Prose reply keeps the legacy quote+<p> shape.
        assert_eq!(
            build_reply_html("m1", "A", "p", "On it!"),
            "<quote author=\"A\" guid=\"m1\">p</quote><p>On it!</p>"
        );
        let b = edit_message_body("123", "```\ncode\n```");
        assert_eq!(b["content"], "<pre>code</pre>");
        assert_eq!(b["messagetype"], "RichText/Html");
        assert_eq!(b["skypeeditedid"], "123");
    }

}
