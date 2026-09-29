//! Test-only fake transport: a loopback HTTP server that records every
//! request (method, path, lowercased headers, body) and answers from a
//! route table, plus a [`TeamsClient`] whose middle tier, chat service,
//! CSA and Graph roots all point at it. Lets the write paths run end to
//! end (URL building, auth headers, JSON body) with no tenant contact.
//! Tokens here are inert placeholders.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::client::TeamsClient;
use crate::auth::TokenStore;
use crate::config::Config;

pub const AAD: &str = "test-aad-token";
pub const SKYPE: &str = "test-skype-token";
pub const GRAPH: &str = "test-graph-token";

/// One request the fake saw.
#[derive(Debug, Clone)]
pub struct Recorded {
    pub method: String,
    pub path: String,
    pub headers: HashMap<String, String>,
    pub body: String,
}

impl Recorded {
    pub fn json(&self) -> serde_json::Value {
        serde_json::from_str(&self.body).unwrap_or(serde_json::Value::Null)
    }
    /// Every header value plus the path and body, for "no secret leaked
    /// to the wrong service" checks.
    pub fn haystack(&self) -> String {
        let mut h: Vec<String> = self.headers.iter().map(|(k, v)| format!("{k}: {v}")).collect();
        h.sort();
        format!("{} {}\n{}\n{}", self.method, self.path, h.join("\n"), self.body)
    }
}

/// (method, path prefix, status, body). First match wins; no match = 404.
pub type Route = (&'static str, &'static str, u16, String);

pub struct Fake {
    pub base: String,
    log: Arc<Mutex<Vec<Recorded>>>,
}

impl Fake {
    pub async fn start(routes: Vec<Route>) -> Fake {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("fake binds");
        let base = format!("http://{}", listener.local_addr().expect("fake addr"));
        let log: Arc<Mutex<Vec<Recorded>>> = Arc::new(Mutex::new(Vec::new()));
        let seen = log.clone();
        tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else { break };
                let mut buf: Vec<u8> = Vec::new();
                let mut tmp = [0u8; 4096];
                let head_end = loop {
                    if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        break Some(i + 4);
                    }
                    let n = sock.read(&mut tmp).await.unwrap_or(0);
                    if n == 0 || buf.len() > 1 << 20 {
                        break None;
                    }
                    buf.extend_from_slice(&tmp[..n]);
                };
                let Some(head_end) = head_end else { continue };
                let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
                let mut lines = head.split("\r\n");
                let mut first = lines.next().unwrap_or("").split_whitespace();
                let method = first.next().unwrap_or("").to_string();
                let path = first.next().unwrap_or("").to_string();
                let mut headers = HashMap::new();
                for line in lines {
                    if let Some((k, v)) = line.split_once(':') {
                        headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
                    }
                }
                let want: usize = headers.get("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
                while buf.len() < head_end + want {
                    let n = sock.read(&mut tmp).await.unwrap_or(0);
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&tmp[..n]);
                }
                let body = String::from_utf8_lossy(&buf[head_end.min(buf.len())..]).to_string();
                let (status, answer) = routes
                    .iter()
                    .find(|(m, p, _, _)| *m == method && path.starts_with(p))
                    .map(|(_, _, s, b)| (*s, b.clone()))
                    .unwrap_or((404, String::new()));
                seen.lock().expect("fake log").push(Recorded { method, path, headers, body });
                // A body starting `@location:<url>\n` answers a Location header.
                let (extra, answer) = match answer.strip_prefix("@location:") {
                    Some(r) => {
                        let (l, rest) = r.split_once('\n').unwrap_or((r, ""));
                        (format!("location: {}\r\n", l.trim()), rest.to_string())
                    }
                    None => (String::new(), answer),
                };
                let reply = format!(
                    "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\n{extra}content-length: {}\r\nconnection: close\r\n\r\n{answer}",
                    answer.len()
                );
                sock.write_all(reply.as_bytes()).await.ok();
                sock.shutdown().await.ok();
            }
        });
        Fake { base, log }
    }

    /// A client whose service roots all live under this fake.
    pub fn client(&self) -> TeamsClient {
        let mut c = Config::default();
        c.set_access_token(AAD.to_string(), Some(3600));
        c.set_skype_token(SKYPE.to_string(), Some(3600));
        c.set_graph_token(GRAPH.to_string(), Some(3600));
        c.set_region_gtms(serde_json::json!({
            "middleTier": format!("{}/mt/", self.base),
            "chatService": format!("{}/chat", self.base),
            "graphBase": format!("{}/graph", self.base),
            "csaBase": format!("{}/csa", self.base),
        }));
        TeamsClient::for_test(c)
    }

    pub fn requests(&self) -> Vec<Recorded> {
        self.log.lock().expect("fake log").clone()
    }
}
