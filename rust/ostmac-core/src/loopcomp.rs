//! Loop/Fluid component FFI (lanes/loopbuild).
//!
//! Thin JSON wrappers over `ost::api::loopcomp`: request shapes
//! (pure, offline), create (C1), page create (C4), embed send (E1),
//! page read (S1). Every failed call returns `{ok:false}` (never an
//! empty success). Transports are LIVE-UNPROVEN (phase-2 plan).

use std::os::raw::c_char;

use serde_json::json;

use crate::{cmid_or_new, cstr_to_string, err_json, opt_cstr_to_string, rt, sent_json, string_to_c};

// -- shapes (pure, offline) --------------------------------------------------------

/// E1 request shapes for one component URL + text (pure, no
/// network/auth): `{ok, cards, body}`. The composer's preview and
/// the offline verification vehicle.
pub fn shapes_json(component_url: &str, text: &str) -> String {
    let cards = ost::api::embed_cards_json(component_url);
    let body = ost::api::embed_message_body(text, &cards);
    json!({"ok": true, "cards": cards, "body": body, "body_string": body.to_string()}).to_string()
}

/// FFI: E1 shapes. NULL-tolerant args. Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_loop_shapes(
    component_url: *const c_char,
    text: *const c_char,
) -> *mut c_char {
    let args = (|| {
        Ok::<_, String>((
            opt_cstr_to_string(component_url)?.unwrap_or_default(),
            opt_cstr_to_string(text)?.unwrap_or_default(),
        ))
    })();
    match args {
        Ok((u, t)) => string_to_c(shapes_json(&u, &t)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

// -- send (E1) ---------------------------------------------------------------------

fn send_inner(chat_id: &str, component_url: &str, text: &str, client_message_id: &str) -> String {
    let cmid = cmid_or_new(client_message_id);
    if chat_id.trim().is_empty() {
        return err_json("arg", "empty chat_id");
    }
    if component_url.trim().is_empty() {
        return err_json("arg", "empty component_url");
    }
    let run = || -> Result<String, String> {
        let runtime = rt()?;
        runtime.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let sent = ost::api::send_loop_embed(&client, chat_id, text, component_url, &cmid)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(sent_json(chat_id, &sent))
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("send", e),
    }
}

/// FFI: post a message carrying the Loop card (E1, cards-first).
/// Same idempotency contract as `ostmac_send_idem`. Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_loop_send_idem(
    chat_id: *const c_char,
    component_url: *const c_char,
    text: *const c_char,
    client_message_id: *const c_char,
) -> *mut c_char {
    let args = (|| {
        Ok::<_, String>((
            cstr_to_string(chat_id)?,
            cstr_to_string(component_url)?,
            opt_cstr_to_string(text)?.unwrap_or_default(),
            cstr_to_string(client_message_id)?,
        ))
    })();
    match args {
        Ok((id, u, t, c)) => string_to_c(send_inner(&id, &u, &t, &c)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

// -- create (C1) -------------------------------------------------------------------

fn create_inner(
    site: &str,
    drive_id: &str,
    folder: &str,
    file_name: &str,
    snapshot_body: &str,
    share_query: Option<&str>,
) -> String {
    for (name, v) in [("site", site), ("drive_id", drive_id), ("file_name", file_name)] {
        if v.trim().is_empty() {
            return err_json("arg", format!("empty {}", name));
        }
    }
    let run = || -> Result<String, String> {
        let runtime = rt()?;
        runtime.block_on(async {
            let c = ost::api::create_snapshot(site, drive_id, folder, file_name, snapshot_body, share_query)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let mut v = serde_json::to_value(&c).map_err(|e| format!("bad answer: {}", e))?;
            v["ok"] = json!(true);
            Ok(v.to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("loop_create", e),
    }
}

/// FFI: create a Fluid file + container (C1). `share_query`
/// NULL-tolerant. Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_loop_create(
    site: *const c_char,
    drive_id: *const c_char,
    folder: *const c_char,
    file_name: *const c_char,
    snapshot_body: *const c_char,
    share_query: *const c_char,
) -> *mut c_char {
    let args = (|| {
        Ok::<_, String>((
            cstr_to_string(site)?,
            cstr_to_string(drive_id)?,
            opt_cstr_to_string(folder)?.unwrap_or_else(|| "Loop".to_string()),
            cstr_to_string(file_name)?,
            opt_cstr_to_string(snapshot_body)?.unwrap_or_default(),
            opt_cstr_to_string(share_query)?,
        ))
    })();
    match args {
        Ok((s, d, f, n, b, q)) => string_to_c(create_inner(&s, &d, &f, &n, &b, q.as_deref())),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

// -- page create (C4) + page read (S1) -----------------------------------------------

fn page_create_inner(
    site: &str,
    drive_id: &str,
    title: &str,
    content_type: &str,
    content_value: &str,
    path: &str,
) -> String {
    if site.trim().is_empty() || drive_id.trim().is_empty() {
        return err_json("arg", "empty site/drive_id");
    }
    let run = || -> Result<String, String> {
        let runtime = rt()?;
        runtime.block_on(async {
            let link =
                ost::api::create_loop_page(site, drive_id, title, content_type, content_value, path)
                    .await
                    .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "link": link}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("loop_page_create", e),
    }
}

/// FFI: create a Loop page (C4). Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_loop_page_create(
    site: *const c_char,
    drive_id: *const c_char,
    title: *const c_char,
    content_type: *const c_char,
    content_value: *const c_char,
    path: *const c_char,
) -> *mut c_char {
    let args = (|| {
        Ok::<_, String>((
            cstr_to_string(site)?,
            cstr_to_string(drive_id)?,
            opt_cstr_to_string(title)?.unwrap_or_default(),
            opt_cstr_to_string(content_type)?.unwrap_or_else(|| "html".to_string()),
            opt_cstr_to_string(content_value)?.unwrap_or_default(),
            opt_cstr_to_string(path)?.unwrap_or_else(|| "/".to_string()),
        ))
    })();
    match args {
        Ok((s, d, t, ct, cv, p)) => string_to_c(page_create_inner(&s, &d, &t, &ct, &cv, &p)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

fn page_read_inner(host: &str, drive_id: &str, item_id: &str) -> String {
    if host.trim().is_empty() || drive_id.trim().is_empty() || item_id.trim().is_empty() {
        return err_json("arg", "empty host/drive_id/item_id");
    }
    let run = || -> Result<String, String> {
        let runtime = rt()?;
        runtime.block_on(async {
            let html = ost::api::read_loop_page(host, drive_id, item_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "html": html}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("loop_page_read", e),
    }
}

/// FFI: read a Loop page HTML snapshot (S1). Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_loop_page_read(
    host: *const c_char,
    drive_id: *const c_char,
    item_id: *const c_char,
) -> *mut c_char {
    let args = (|| {
        Ok::<_, String>((
            cstr_to_string(host)?,
            cstr_to_string(drive_id)?,
            cstr_to_string(item_id)?,
        ))
    })();
    match args {
        Ok((h, d, i)) => string_to_c(page_read_inner(&h, &d, &i)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shapes_pin_e1_request() {
        let v: serde_json::Value =
            serde_json::from_str(&shapes_json("https://t/x?nav=abc", "hi")).unwrap();
        assert_eq!(v["ok"], true);
        let cards: serde_json::Value = serde_json::from_str(v["cards"].as_str().unwrap()).unwrap();
        assert_eq!(cards[0]["contentType"], ost::api::FLUID_EMBED_CARD_CT);
        assert_eq!(v["body"]["cards"], v["cards"]);
        assert_eq!(v["body"]["messagetype"], "RichText/Html");
    }

    #[test]
    fn inners_reject_bad_args_without_network() {
        for v in [
            send_inner("", "u", "t", "c"),
            send_inner("id", "", "t", "c"),
            create_inner("", "d", "f", "n", "b", None),
            page_create_inner("", "d", "t", "ct", "cv", "/"),
            page_read_inner("h", "", "i"),
        ] {
            let parsed: serde_json::Value = serde_json::from_str(&v).unwrap();
            assert_eq!(parsed["ok"], false);
            assert_eq!(parsed["error"], "arg");
        }
    }
}
