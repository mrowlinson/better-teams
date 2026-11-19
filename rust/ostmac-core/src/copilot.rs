//! COPILOT-BUILD FFI: Copilot chat turns + licence status for Swift.
//!
//! Turn streaming follows the trouter shape (background task + polled
//! channel): `chat_start` spawns one `ost` turn on the shared runtime
//! and returns a turn id; `chat_poll` drains it (latest cumulative
//! text wins); `chat_stop` cancels. Licence status is a blocking
//! Taiger read like the recap AI notes.
//!
//! Every failure is `{ok:false,error,code?}` (never an empty
//! success): `code:"auth"` = sign in first, `code:"license"` = the
//! Taiger gate, else the transport/server text. Swift turns these
//! into the honest disabled-with-reason state.

use std::collections::HashMap;
use std::os::raw::c_char;
use std::sync::{mpsc, Mutex, OnceLock};

use serde_json::{json, Value};

use crate::{cstr_to_string, err_json, rt, string_to_c};
use ost::api as cop;

/// One turn's channel event (sender: the spawned task).
#[derive(Debug)]
enum TurnEvent {
    Text(String),
    Progress(String),
    Done(cop::CopilotAnswer),
    Error(String),
}

struct TurnState {
    rx: mpsc::Receiver<TurnEvent>,
    task: tokio::task::JoinHandle<()>,
    last_text: String,
    progress: Option<String>,
    answer: Option<cop::CopilotAnswer>,
    error: Option<String>,
    finished: bool,
}

fn turns() -> &'static Mutex<HashMap<String, TurnState>> {
    static T: OnceLock<Mutex<HashMap<String, TurnState>>> = OnceLock::new();
    T.get_or_init(|| Mutex::new(HashMap::new()))
}

fn lock() -> std::sync::MutexGuard<'static, HashMap<String, TurnState>> {
    turns().lock().unwrap_or_else(|e| e.into_inner())
}

/// Start arg: `{"prompt":…, "conversation_id"?}` or a bare prompt.
/// Pure (tests pin it).
pub fn parse_start_arg(raw: &str) -> (String, Option<String>) {
    if let Ok(v) = serde_json::from_str::<Value>(raw) {
        if let Some(p) = v.get("prompt").and_then(Value::as_str) {
            let c = v.get("conversation_id").and_then(Value::as_str).map(str::to_string);
            return (p.to_string(), c);
        }
    }
    (raw.to_string(), None)
}

fn has_cached_auth() -> bool {
    ost::config::Config::load_cached().is_ok()
}

/// `copilot_chat_start`: `{ok, turn_id}` or `{ok:false,error,code}`.
pub fn copilot_chat_start_json(raw: &str) -> String {
    let (prompt, conversation_id) = parse_start_arg(raw);
    if prompt.trim().is_empty() {
        return err_json("arg", "empty prompt");
    }
    // Fail fast without usable auth (else the task mints forever).
    if !has_cached_auth() {
        return json!({"ok": false, "code": "auth", "error": "sign in to use Copilot"}).to_string();
    }
    let runtime = match rt() {
        Ok(r) => r,
        Err(e) => return err_json("runtime", e),
    };
    let turn_id = format!("{:032x}", rand::random::<u128>());
    let (tx, rx) = mpsc::channel::<TurnEvent>();
    let mut turn = cop::ChatTurn::free_tier(&prompt);
    if let Some(c) = conversation_id {
        if !c.trim().is_empty() {
            turn.conversation_id = c;
            turn.is_start_of_session = false;
        }
    }
    let profile = ost::config::active_profile();
    let task = runtime.spawn(async move {
        let send = |e: TurnEvent| {
            let _ = tx.send(e);
        };
        let token = match cop::sydney_token_for(&profile).await {
            Ok(t) => t,
            Err(e) => {
                send(TurnEvent::Error(format!("Copilot token failed: {:#}", e)));
                return;
            }
        };
        let url = cop::hub_url_2026(
            cop::HUB_DEFAULT,
            &turn.conversation_id,
            &token,
            cop::SOURCE_TEAMSHUB,
            cop::SCENARIO_TEAMSHUB,
            &cop::HubQuery::default(),
        );
        // Drop the token before any logging happens downstream.
        drop(token);
        match cop::run_turn(&url, &turn, |p| match p {
            cop::TurnProgress::Text(t) => send(TurnEvent::Text(t)),
            cop::TurnProgress::Progress(p) => send(TurnEvent::Progress(p)),
            cop::TurnProgress::Done(_) => {}
        })
        .await
        {
            Ok(a) => send(TurnEvent::Done(a)),
            Err(e) => send(TurnEvent::Error(format!("{:#}", e))),
        }
    });
    lock().insert(
        turn_id.clone(),
        TurnState {
            rx,
            task,
            last_text: String::new(),
            progress: None,
            answer: None,
            error: None,
            finished: false,
        },
    );
    json!({"ok": true, "turn_id": turn_id}).to_string()
}

/// Drain one turn's queued events into the poll envelope. Pure over
/// the event list (tests pin it); the live path drains the receiver.
pub fn poll_envelope(turn_id: &str, events: &[TurnEvent], state: &PollState) -> Value {
    let mut text = state.text.clone();
    let mut progress = state.progress.clone();
    let mut answer: Option<Value> = state.answer.clone();
    let mut error = state.error.clone();
    let mut done = state.done;
    for e in events {
        match e {
            TurnEvent::Text(t) => text = t.clone(),
            TurnEvent::Progress(p) => progress = Some(p.clone()),
            TurnEvent::Done(a) => {
                answer = serde_json::to_value(a).ok();
                done = true;
            }
            TurnEvent::Error(e) => {
                error = Some(e.clone());
                done = true;
            }
        }
    }
    let mut out = json!({"ok": true, "turn_id": turn_id, "text": text, "done": done});
    if let Some(p) = &progress {
        out["progress"] = json!(p);
    }
    if let Some(a) = &answer {
        out["answer"] = a.clone();
    }
    if let Some(e) = &error {
        out["error"] = json!(e);
    }
    out
}

/// Carried poll state between drains.
#[derive(Debug, Clone, Default)]
pub struct PollState {
    pub text: String,
    pub progress: Option<String>,
    pub answer: Option<Value>,
    pub error: Option<String>,
    pub done: bool,
}

/// `copilot_chat_poll`: `{ok, turn_id, text, done, progress?,
/// answer?, error?}`. Unknown turn id → `{ok:false}`.
pub fn copilot_chat_poll_json(turn_id: &str) -> String {
    let mut guard = lock();
    let st = match guard.get_mut(turn_id) {
        Some(st) => st,
        None => return err_json("arg", "unknown turn"),
    };
    let mut events = Vec::new();
    while let Ok(e) = st.rx.try_recv() {
        events.push(e);
    }
    let state = PollState {
        text: st.last_text.clone(),
        progress: st.progress.clone(),
        answer: st.answer.as_ref().and_then(|a| serde_json::to_value(a).ok()),
        error: st.error.clone(),
        done: st.finished,
    };
    let out = poll_envelope(turn_id, &events, &state);
    // Carry the merged state for the next poll.
    st.last_text = out["text"].as_str().unwrap_or("").to_string();
    st.progress = out.get("progress").and_then(Value::as_str).map(str::to_string);
    st.error = out.get("error").and_then(Value::as_str).map(str::to_string);
    st.finished = out["done"].as_bool().unwrap_or(false);
    if st.answer.is_none() {
        if let Some(a) = out.get("answer") {
            st.answer = serde_json::from_value(a.clone()).ok();
        }
    }
    // Keep finished turns for one last read, then drop.
    if st.finished && events.is_empty() {
        guard.remove(turn_id);
    }
    out.to_string()
}

/// `copilot_chat_stop`: cancel + drop. Unknown turn id is still ok
/// (stop is idempotent).
pub fn copilot_chat_stop_json(turn_id: &str) -> String {
    if let Some(st) = lock().remove(turn_id) {
        st.task.abort();
    }
    json!({"ok": true}).to_string()
}

/// Licence envelope from a parsed status (pure; tests pin it).
pub fn license_envelope(s: &cop::LicenseStatus) -> Value {
    let mut out = json!({
        "ok": true,
        "status": s.status,
        "is_eap": s.is_eap,
        "is_debug": s.is_debug,
        "licensed": cop::licensed(&s.status),
    });
    if let Some(r) = cop::license_reason(&s.status) {
        out["reason"] = json!(r);
    }
    if let Some(e) = s.error_text() {
        out["error"] = json!(e);
    }
    out
}

/// `copilot_license_status`: blocking Taiger read.
pub fn copilot_license_json() -> String {
    if !has_cached_auth() {
        return json!({"ok": false, "code": "auth", "error": "sign in to use Copilot"}).to_string();
    }
    let run = || -> Result<String, String> {
        rt()?.block_on(async {
            let profile = ost::config::active_profile();
            let scope = format!("{}/.default", cop::TAIGER_BASE);
            let grant = ost::auth::oauth::token_for_scope_for(&profile, &scope)
                .await
                .map_err(|e| format!("Copilot token failed: {:#}", e))?;
            // Sydney JWE is opaque; Taiger needs oid/tid for anchor
            // headers. JWT family carries them; else the cached
            // account is the fallback (CAPTURE-PIN for phase 2).
            let (oid, tid) = cop::jwt_oid_tid(&grant.access_token)
                .ok_or_else(|| "token has no oid/tid".to_string())?;
            Ok(license_envelope(&cop::license_status(&grant.access_token, &oid, &tid).await).to_string())
        })
    };
    run().unwrap_or_else(|e| err_json("license", e))
}

#[no_mangle]
pub extern "C" fn ostmac_copilot_license_status() -> *mut c_char {
    string_to_c(copilot_license_json())
}

#[no_mangle]
pub extern "C" fn ostmac_copilot_chat_start(prompt: *const c_char) -> *mut c_char {
    string_to_c(match cstr_to_string(prompt) {
        Ok(p) => copilot_chat_start_json(&p),
        Err(e) => err_json("arg", e),
    })
}

#[no_mangle]
pub extern "C" fn ostmac_copilot_chat_poll(turn_id: *const c_char) -> *mut c_char {
    string_to_c(match cstr_to_string(turn_id) {
        Ok(t) => copilot_chat_poll_json(&t),
        Err(e) => err_json("arg", e),
    })
}

#[no_mangle]
pub extern "C" fn ostmac_copilot_chat_stop(turn_id: *const c_char) -> *mut c_char {
    string_to_c(match cstr_to_string(turn_id) {
        Ok(t) => copilot_chat_stop_json(&t),
        Err(e) => err_json("arg", e),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn start_arg_json_or_bare_prompt() {
        let (p, c) = parse_start_arg("hello");
        assert_eq!(p.as_str(), "hello");
        assert_eq!(c, None);
        let (p, c) = parse_start_arg(r#"{"prompt":"hi","conversation_id":"c1"}"#);
        assert_eq!(p, "hi");
        assert_eq!(c.as_deref(), Some("c1"));
        let (p, _) = parse_start_arg(r#"{"nope":1}"#);
        assert_eq!(p, r#"{"nope":1}"#);
    }

    #[test]
    fn empty_prompt_rejected_before_auth() {
        let v: Value = serde_json::from_str(&copilot_chat_start_json("  ")).unwrap();
        assert_eq!(v["ok"], false);
    }

    #[test]
    fn unknown_turn_poll_is_arg_error_stop_is_ok() {
        let v: Value = serde_json::from_str(&copilot_chat_poll_json("nope")).unwrap();
        assert_eq!(v["ok"], false);
        let v: Value = serde_json::from_str(&copilot_chat_stop_json("nope")).unwrap();
        assert_eq!(v["ok"], true);
    }

    #[test]
    fn poll_envelope_merges_cumulative_text_and_finish() {
        let ev = vec![
            TurnEvent::Progress("Taking a look…".to_string()),
            TurnEvent::Text("Hel".to_string()),
            TurnEvent::Text("Hello".to_string()),
        ];
        let out = poll_envelope("t", &ev, &PollState::default());
        assert_eq!(out["text"], "Hello");
        assert_eq!(out["progress"], "Taking a look…");
        assert_eq!(out["done"], false);
        let mut ans = cop::CopilotAnswer::default();
        ans.text = "Hello".to_string();
        ans.suggestions = vec!["More?".to_string()];
        let out = poll_envelope("t", &[TurnEvent::Done(ans)], &PollState::default());
        assert_eq!(out["done"], true);
        assert_eq!(out["answer"]["suggestions"][0], "More?");
        let out = poll_envelope("t", &[TurnEvent::Error("OutOfCredits".to_string())], &PollState::default());
        assert_eq!(out["done"], true);
        assert_eq!(out["error"], "OutOfCredits");
    }

    #[test]
    fn license_envelope_carries_gate_and_reason() {
        let s = cop::LicenseStatus {
            status: "UNLICENSED".to_string(),
            is_eap: false,
            is_debug: false,
            error: None,
        };
        let out = license_envelope(&s);
        assert_eq!(out["licensed"], false);
        assert!(out["reason"].as_str().unwrap().contains("isn't licensed"));
        let s = cop::LicenseStatus { status: "COPILOT_LICENSE".to_string(), ..Default::default() };
        let out = license_envelope(&s);
        assert_eq!(out["licensed"], true);
        assert!(out.get("reason").is_none());
    }
}
