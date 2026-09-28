//! Authenticated HTTP client for Teams APIs
//!
//! Wraps reqwest::Client with automatic token injection and refresh.

use anyhow::{bail, Context, Result};

use std::sync::OnceLock;

use crate::auth::TokenStore;
use crate::config::Config;

const GRAPH_BASE: &str = "https://graph.microsoft.com/v1.0";
const DEFAULT_CHAT_SERVICE: &str = "https://amer.ng.msg.teams.microsoft.com";
const CHATSVCAGG: &str = "https://chatsvcagg.teams.microsoft.com";

/// Authenticated client that handles both Graph (AAD) and Teams (Skype) APIs.
pub struct TeamsClient {
    http: reqwest::Client,
    config: Config,
}

/// Process-wide shared HTTP client: one connection pool for all calls.
/// `Client::clone` is cheap — clones share the pool.
pub fn shared_http() -> reqwest::Client {
    static HTTP: OnceLock<reqwest::Client> = OnceLock::new();
    HTTP.get_or_init(reqwest::Client::new).clone()
}

impl TeamsClient {
    /// Load config and build client. Attempts token refresh if AAD token is expired.
    pub async fn new() -> Result<Self> {
        Self::new_for_profile(&crate::config::active_profile()).await
    }

    /// Same as [`Self::new`], scoped to one account profile
    /// (multi-account: per-account reads without switching active).
    pub async fn new_for_profile(profile: &str) -> Result<Self> {
        let mut config = Config::load_cached_for(profile)?;

        // Auto-refresh if any token is expired but refresh token exists
        let needs_refresh = config.get_access_token().map_or(true, |t| t.is_expired())
            || config.get_graph_token().map_or(true, |t| t.is_expired());
        if needs_refresh {
            if config.get_refresh_token().is_some() {
                tracing::info!("Tokens missing or expired, refreshing...");
                match crate::auth::oauth::refresh_for(profile).await {
                    Ok(true) => {
                        config = Config::load_cached_for(profile)?;
                        tracing::info!("Token refreshed");
                    }
                    Ok(false) => {
                        bail!("No refresh token available. Run 'teams-cli login'.");
                    }
                    Err(e) => {
                        bail!("Token refresh failed: {:#}. Run 'teams-cli login'.", e);
                    }
                }
            } else {
                bail!("Token expired and no refresh token. Run 'teams-cli login'.");
            }
        }

        Ok(Self {
            http: shared_http(),
            config,
        })
    }

    fn graph_token(&self) -> Result<String> {
        let token = self
            .config
            .get_graph_token()
            .context("No Graph token. Run 'teams-cli login' first.")?;
        if token.is_expired() {
            bail!("Graph token expired. Run 'teams-cli login'.");
        }
        Ok(token.token)
    }

    fn skype_token(&self) -> Result<String> {
        let token = self
            .config
            .get_skype_token()
            .context("No Skype token. Run 'teams-cli login' first.")?;
        if token.is_expired() {
            bail!("Skype token expired. Run 'teams-cli login'.");
        }
        Ok(token.token)
    }

    /// GET request to Microsoft Graph API (bearer auth with Graph token).
    pub async fn graph_get(&self, path: &str) -> Result<reqwest::Response> {
        let token = self.graph_token()?;
        let url = format!("{}{}", GRAPH_BASE, path);
        tracing::debug!("Graph GET {}", url);

        let resp = self
            .http
            .get(&url)
            .bearer_auth(&token)
            .send()
            .await
            .with_context(|| format!("Graph GET {} failed", url))?;

        check_response(resp, &url).await
    }

    /// GET request with `ConsistencyLevel: eventual` (Graph `$search` /
    /// `$count` queries 400 without it). Otherwise identical to
    /// [`graph_get`](Self::graph_get). OstMac (om-jb-filesearch): people
    /// search.
    pub async fn graph_get_consistent(&self, path: &str) -> Result<reqwest::Response> {
        let token = self.graph_token()?;
        let url = format!("{}{}", GRAPH_BASE, path);
        tracing::debug!("Graph GET {}", url);

        let resp = self
            .http
            .get(&url)
            .bearer_auth(&token)
            .header("ConsistencyLevel", "eventual")
            .send()
            .await
            .with_context(|| format!("Graph GET {} failed", url))?;

        check_response(resp, &url).await
    }

    /// POST request to Microsoft Graph API (bearer auth with Graph token).
    /// GET an absolute Graph URL with the Graph bearer token (async
    /// `Content-Location` operation polls hand back absolute URLs).
    pub async fn graph_get_url(&self, url: &str) -> Result<reqwest::Response> {
        let token = self.graph_token()?;
        tracing::debug!("Graph GET {}", url);

        let resp = self
            .http
            .get(url)
            .bearer_auth(&token)
            .send()
            .await
            .with_context(|| format!("Graph GET {} failed", url))?;

        check_response(resp, url).await
    }

    pub async fn graph_post(
        &self,
        path: &str,
        body: &serde_json::Value,
    ) -> Result<reqwest::Response> {
        let token = self.graph_token()?;
        let url = format!("{}{}", GRAPH_BASE, path);
        tracing::debug!("Graph POST {}", url);

        let resp = self
            .http
            .post(&url)
            .bearer_auth(&token)
            .json(body)
            .send()
            .await
            .with_context(|| format!("Graph POST {} failed", url))?;

        check_response(resp, &url).await
    }

    /// DELETE request to Microsoft Graph API (Bearer [REDACTED] with Graph token).
    /// OstMac (om-h5-members): team member removal.
    pub async fn graph_delete(&self, path: &str) -> Result<reqwest::Response> {
        let token = self.graph_token()?;
        let url = format!("{}{}", GRAPH_BASE, path);
        tracing::debug!("Graph DELETE {}", url);

        let resp = self
            .http
            .delete(&url)
            .bearer_auth(&token)
            .send()
            .await
            .with_context(|| format!("Graph DELETE {} failed", url))?;

        check_response(resp, &url).await
    }

    /// PUT bytes to Microsoft Graph API (drive upload). `content_type` is
    /// the file MIME; Graph accepts `application/octet-stream` for all.
    pub async fn graph_put_bytes(
        &self,
        path: &str,
        bytes: Vec<u8>,
        content_type: &str,
    ) -> Result<reqwest::Response> {
        let token = self.graph_token()?;
        let url = format!("{}{}", GRAPH_BASE, path);
        tracing::debug!("Graph PUT {} ({} bytes)", url, bytes.len());

        let resp = self
            .http
            .put(&url)
            .bearer_auth(&token)
            .header(reqwest::header::CONTENT_TYPE, content_type.to_string())
            .body(bytes)
            .send()
            .await
            .with_context(|| format!("Graph PUT {} failed", url))?;

        check_response(resp, &url).await
    }

    /// PUT one resumable-upload fragment to a drive `uploadUrl`.
    /// The session URL is pre-authenticated: no bearer header (Graph
    /// rejects authed fragment PUTs). `start`/`end` are inclusive.
    /// OstMac (om-i4-bigup): >4 MB uploads.
    pub async fn drive_session_put(
        &self,
        upload_url: &str,
        chunk: &[u8],
        start: u64,
        end: u64,
        total: u64,
    ) -> Result<reqwest::Response> {
        tracing::debug!(
            "Session PUT bytes {}-{}/{} ({} bytes)",
            start,
            end,
            total,
            chunk.len()
        );
        let resp = self
            .http
            .put(upload_url)
            .header(
                reqwest::header::CONTENT_RANGE,
                format!("bytes {}-{}/{}", start, end, total),
            )
            .header(reqwest::header::CONTENT_LENGTH, chunk.len())
            .body(chunk.to_vec())
            .send()
            .await
            .with_context(|| format!("Session PUT bytes {}-{}/{} failed", start, end, total))?;
        check_response(resp, upload_url).await
    }

    /// PATCH request to Microsoft Graph API (Bearer [REDACTED] with Graph token).
    /// OstMac (om-remind): To Do task completion flips `status` via PATCH.
    pub async fn graph_patch(
        &self,
        path: &str,
        body: &serde_json::Value,
    ) -> Result<reqwest::Response> {
        let token = self.graph_token()?;
        let url = format!("{}{}", GRAPH_BASE, path);
        tracing::debug!("Graph PATCH {}", url);

        let resp = self
            .http
            .patch(&url)
            .bearer_auth(&token)
            .json(body)
            .send()
            .await
            .with_context(|| format!("Graph PATCH {} failed", url))?;

        check_response(resp, &url).await
    }

    /// PATCH request to Microsoft Graph API with a raw body (Bearer [REDACTED] auth).
    /// Used by the OneNote edit path (multipart/form-data Commands).
    pub async fn graph_patch_raw(
        &self,
        path: &str,
        content_type: &str,
        body: Vec<u8>,
    ) -> Result<reqwest::Response> {
        let token = self.graph_token()?;
        let url = format!("{}{}", GRAPH_BASE, path);
        tracing::debug!("Graph PATCH {}", url);

        let resp = self
            .http
            .patch(&url)
            .bearer_auth(&token)
            .header("Content-Type", content_type)
            .body(body)
            .send()
            .await
            .with_context(|| format!("Graph PATCH {} failed", url))?;

        check_response(resp, &url).await
    }

    /// GET request to Teams/Skype API (X-SkypeToken header).
    pub async fn teams_get(&self, url: &str) -> Result<reqwest::Response> {
        let token = self.skype_token()?;
        tracing::debug!("Teams GET {}", url);

        let resp = self
            .http
            .get(url)
            .header("X-SkypeToken", &token)
            .send()
            .await
            .with_context(|| format!("Teams GET {} failed", url))?;

        check_response(resp, url).await
    }

    /// POST request to Teams/Skype API (X-SkypeToken header).
    pub async fn teams_post(
        &self,
        url: &str,
        body: &serde_json::Value,
    ) -> Result<reqwest::Response> {
        let token = self.skype_token()?;
        tracing::debug!("Teams POST {}", url);

        let resp = self
            .http
            .post(url)
            .header("X-SkypeToken", &token)
            .json(body)
            .send()
            .await
            .with_context(|| format!("Teams POST {} failed", url))?;

        check_response(resp, url).await
    }

    /// Chat service base URL from region_gtms, falling back to default.
    pub fn chat_service_url(&self) -> String {
        self.config
            .get_region_gtms()
            .and_then(|v| {
                v.get("chatService")
                    .and_then(|s| s.as_str())
                    .map(String::from)
            })
            .unwrap_or_else(|| DEFAULT_CHAT_SERVICE.to_string())
    }

    /// Chat service aggregator URL from region_gtms, falling back to default.
    pub fn chatsvcagg_url(&self) -> String {
        self.config
            .get_region_gtms()
            .and_then(|v| {
                v.get("chatServiceAggregator")
                    .and_then(|s| s.as_str())
                    .map(String::from)
            })
            .unwrap_or_else(|| CHATSVCAGG.to_string())
    }

    /// GET using `Authorization: Bearer {skype_token}` with client version header (CSA/AFD endpoint).
    pub async fn csa_get(&self, url: &str) -> Result<reqwest::Response> {
        let token = self.skype_token()?;
        tracing::debug!("CSA GET {}", url);

        let resp = self
            .http
            .get(url)
            .bearer_auth(&token)
            .header("x-ms-client-version", "1416/1.0.0.2024050301")
            .send()
            .await
            .with_context(|| format!("CSA GET {} failed", url))?;

        check_response(resp, url).await
    }

    /// GET using `Authentication: skypetoken=...` header (native chat API).
    pub async fn chat_get(&self, url: &str) -> Result<reqwest::Response> {
        let token = self.skype_token()?;
        tracing::debug!("Chat GET {}", url);

        let resp = self
            .http
            .get(url)
            .header("Authentication", format!("skypetoken={}", token))
            .send()
            .await
            .with_context(|| format!("Chat GET {} failed", url))?;

        check_response(resp, url).await
    }

    /// Raw-bytes GET for inline chat media (om-richmedia, om-imgfix).
    /// Microsoft media hosts attach the Skype token with the per-family
    /// scheme (see `media::auth_headers`); public hosts fetch without
    /// auth so the token never leaks to third parties. Rejects over-cap
    /// payloads (never truncated).
    pub async fn media_get(&self, url: &str) -> Result<super::media::MediaBytes> {
        let headers = if super::media::needs_auth(url) {
            let token = self.skype_token()?;
            super::media::auth_headers(url, &token)
        } else {
            Vec::new()
        };
        Self::media_fetch(&self.http, url, &headers).await
    }

    /// Transport core behind [`Self::media_get`]: GET with exactly the
    /// given headers, status-checked, body capped. Split out so the
    /// om-imgfix repro matrix can drive it against a local stub.
    async fn media_fetch(
        http: &reqwest::Client,
        url: &str,
        headers: &[(&'static str, String)],
    ) -> Result<super::media::MediaBytes> {
        let mut req = http.get(url);
        for (name, value) in headers {
            req = req.header(*name, value.as_str());
        }
        tracing::debug!("Media GET {}", url);
        let resp = req
            .send()
            .await
            .with_context(|| format!("Media GET {} failed", url))?;
        let resp = check_response(resp, url).await?;
        let content_type = resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(String::from);
        let bytes = resp
            .bytes()
            .await
            .with_context(|| format!("Media GET {} body failed", url))?;
        if bytes.len() > super::media::MAX_BYTES {
            anyhow::bail!(
                "Media {} exceeds {} bytes",
                url,
                super::media::MAX_BYTES
            );
        }
        Ok(super::media::MediaBytes {
            data: bytes.to_vec(),
            content_type,
        })
    }

    /// POST using `Authentication: skypetoken=...` header (native chat API).
    pub async fn chat_post(
        &self,
        url: &str,
        body: &serde_json::Value,
    ) -> Result<reqwest::Response> {
        let token = self.skype_token()?;
        tracing::debug!("Chat POST {}", url);

        let resp = self
            .http
            .post(url)
            .header("Authentication", format!("skypetoken={}", token))
            .json(body)
            .send()
            .await
            .with_context(|| format!("Chat POST {} failed", url))?;

        check_response(resp, url).await
    }

    /// PUT using `Authentication: skypetoken=...` header (native chat API).
    /// OstMac (om-editdel): message edits PUT new content to the per-message URL.
    pub async fn chat_put(
        &self,
        url: &str,
        body: &serde_json::Value,
    ) -> Result<reqwest::Response> {
        let token = self.skype_token()?;
        tracing::debug!("Chat PUT {}", url);

        let resp = self
            .http
            .put(url)
            .header("Authentication", format!("skypetoken={}", token))
            .json(body)
            .send()
            .await
            .with_context(|| format!("Chat PUT {} failed", url))?;

        check_response(resp, url).await
    }

    /// DELETE using `Authentication: skypetoken=...` header (native chat
    /// API; om-reactions: reaction removal; om-editdel: message deletes
    /// pass `None`). Optional JSON body, same auth as [`Self::chat_post`].
    pub async fn chat_delete(
        &self,
        url: &str,
        body: Option<&serde_json::Value>,
    ) -> Result<reqwest::Response> {
        let token = self.skype_token()?;
        tracing::debug!("Chat DELETE {}", url);

        let mut req = self
            .http
            .delete(url)
            .header("Authentication", format!("skypetoken={}", token));
        if let Some(b) = body {
            req = req.json(b);
        }
        let resp = req
            .send()
            .await
            .with_context(|| format!("Chat DELETE {} failed", url))?;

        check_response(resp, url).await
    }
}

/// Check HTTP response status code and return a clear error on failure.
async fn check_response(resp: reqwest::Response, url: &str) -> Result<reqwest::Response> {
    let status = resp.status();
    if status == reqwest::StatusCode::UNAUTHORIZED {
        bail!(
            "401 Unauthorized for {}. Token may be invalid -- run 'teams-cli login'.",
            url
        );
    }
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        bail!("HTTP {} for {}: {}", status.as_u16(), url, body);
    }
    Ok(resp)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// One request observed by the stub: path + lowercased header map.
    struct Hit {
        path: String,
        headers: HashMap<String, String>,
    }

    /// Serve canned raw-HTTP responses, one per connection, recording
    /// request headers. Returns base URL, hit log, and server task.
    async fn start_stub(
        responses: Vec<Vec<u8>>,
    ) -> (
        String,
        Arc<Mutex<Vec<Hit>>>,
        tokio::task::JoinHandle<()>,
    ) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("stub binds");
        let base = format!("http://{}", listener.local_addr().expect("stub addr"));
        let hits: Arc<Mutex<Vec<Hit>>> = Arc::new(Mutex::new(Vec::new()));
        let seen = hits.clone();
        let task = tokio::spawn(async move {
            for body in responses {
                let Ok((mut sock, _)) = listener.accept().await else {
                    break;
                };
                let mut buf = Vec::new();
                let mut tmp = [0u8; 4096];
                loop {
                    let n = sock.read(&mut tmp).await.unwrap_or(0);
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&tmp[..n]);
                    if buf.len() > 65536
                        || buf.windows(4).any(|w| w == b"\r\n\r\n")
                    {
                        break;
                    }
                }
                let head = String::from_utf8_lossy(&buf);
                let mut lines = head.split("\r\n");
                let path = lines
                    .next()
                    .and_then(|l| l.split_whitespace().nth(1))
                    .unwrap_or("")
                    .to_string();
                let mut headers = HashMap::new();
                for line in lines {
                    if line.is_empty() {
                        break;
                    }
                    if let Some((k, v)) = line.split_once(':') {
                        headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
                    }
                }
                seen.lock().expect("hit log").push(Hit { path, headers });
                sock.write_all(&body).await.ok();
                sock.shutdown().await.ok();
            }
        });
        (base, hits, task)
    }

    fn plain(status: &str, content_type: &str, body: &[u8]) -> Vec<u8> {
        let mut v = format!(
            "HTTP/1.1 {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            status,
            content_type,
            body.len()
        )
        .into_bytes();
        v.extend_from_slice(body);
        v
    }

    /// 401 cause (om-imgfix): the ASM family must carry the object-store
    /// scheme. Fails on the old mapping (chat headers) — mirrors the live
    /// 401.
    #[tokio::test]
    async fn media_asm_headers_reach_server() {
        let (base, hits, task) = start_stub(vec![plain("200 OK", "image/png", b"PNG!")]).await;
        let http = reqwest::Client::new();
        let headers = super::super::media::auth_headers(
            "https://us-api.asm.skype.com/v1/objects/0-eus-d1-abc/views/imgo",
            "T",
        );
        let mb = TeamsClient::media_fetch(&http, &(base + "/views/imgo"), &headers)
            .await
            .expect("stub fetch");
        assert_eq!(mb.data, b"PNG!");
        task.await.expect("stub drains");
        let hits = hits.lock().expect("hit log");
        assert_eq!(hits.len(), 1);
        assert_eq!(
            hits[0].headers.get("authorization").map(String::as_str),
            Some("skype_token T")
        );
        assert!(!hits[0].headers.contains_key("authentication"));
        assert!(!hits[0].headers.contains_key("x-skypetoken"));
    }

    /// Chat-family headers still ride the transport (unchanged behavior).
    #[tokio::test]
    async fn media_chat_headers_reach_server() {
        let (base, hits, task) = start_stub(vec![plain("200 OK", "image/png", b"PNG!")]).await;
        let http = reqwest::Client::new();
        let headers = super::super::media::auth_headers(
            "https://amer.ng.msg.teams.microsoft.com/v1/objects/0-abc/views/imgo",
            "T",
        );
        TeamsClient::media_fetch(&http, &(base + "/views/imgo"), &headers)
            .await
            .expect("stub fetch");
        task.await.expect("stub drains");
        let hits = hits.lock().expect("hit log");
        assert_eq!(hits.len(), 1);
        assert_eq!(
            hits[0].headers.get("authentication").map(String::as_str),
            Some("skypetoken=T")
        );
        assert_eq!(
            hits[0].headers.get("x-skypetoken").map(String::as_str),
            Some("T")
        );
    }

    /// Redirect leg: same-host 302 is followed to the bytes.
    #[tokio::test]
    async fn media_redirect_followed() {
        let (base, hits, task) = start_stub(vec![
            b"HTTP/1.1 302 Found\r\nLocation: /final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                .to_vec(),
            plain("200 OK", "image/jpeg", b"JPEG!"),
        ])
        .await;
        let http = reqwest::Client::new();
        let mb = TeamsClient::media_fetch(&http, &(base + "/start"), &[])
            .await
            .expect("redirect followed");
        assert_eq!(mb.data, b"JPEG!");
        assert_eq!(mb.content_type.as_deref(), Some("image/jpeg"));
        task.await.expect("stub drains");
        let hits = hits.lock().expect("hit log");
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[1].path, "/final");
    }

    /// 401 leg: auth failures surface the status, never empty bytes.
    #[tokio::test]
    async fn media_401_surfaces_status() {
        let (base, _, task) =
            start_stub(vec![plain("401 Unauthorized", "text/plain", b"nope")]).await;
        let http = reqwest::Client::new();
        let err = TeamsClient::media_fetch(&http, &(base + "/views/imgo"), &[])
            .await
            .expect_err("401 must fail");
        assert!(format!("{err:#}").contains("401"), "says 401: {err:#}");
        task.await.expect("stub drains");
    }

    /// Shape leg: non-image 200s pass through with their content type —
    /// the embedder (Swift `NSImage(data:)`) owns image validation.
    #[tokio::test]
    async fn media_shape_passes_through() {
        let (base, _, task) = start_stub(vec![plain(
            "200 OK",
            "application/json",
            br#"{"error":"gone"}"#,
        )])
        .await;
        let http = reqwest::Client::new();
        let mb = TeamsClient::media_fetch(&http, &(base + "/views/imgo"), &[])
            .await
            .expect("shape passes through");
        assert_eq!(mb.data, br#"{"error":"gone"}"#);
        assert_eq!(mb.content_type.as_deref(), Some("application/json"));
        task.await.expect("stub drains");
    }

    /// Over-cap payloads are rejected, never truncated.
    #[tokio::test]
    async fn media_over_cap_rejected() {
        let big = vec![b'x'; super::super::media::MAX_BYTES + 1];
        let (base, _, task) =
            start_stub(vec![plain("200 OK", "image/png", &big)]).await;
        let http = reqwest::Client::new();
        let err = TeamsClient::media_fetch(&http, &(base + "/big"), &[])
            .await
            .expect_err("over-cap must fail");
        assert!(
            format!("{err:#}").contains("exceeds"),
            "says exceeds: {err:#}"
        );
        task.await.expect("stub drains");
    }
}
