//! Catch Up tag bridge (§GRAPH2): the signed-in user's Teams tags from the
//! CSA service (`ost::api::tags`), as JSON over FFI. A read only. Every
//! failure (no sign-in, HTTP error, unreadable answer) reports
//! `{"ok":false,"error":"tags","detail":…}` so the UI can show it; an
//! empty `tags` list only ever means the service answered "none".

use std::os::raw::c_char;

use serde_json::json;

use crate::{err_json, rt, string_to_c};

/// Lowercased, de-duplicated tag names as `{"ok":true,"tags":[…]}`.
pub fn catchup_tags_json() -> String {
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new().await.map_err(|e| format!("{:#}", e))?;
            let cards = ost::api::tags::my_tag_cards_data(&client).await.map_err(|e| format!("{:#}", e))?;
            Ok(tags_ok_json(&cards))
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("tags", e),
    }
}

/// Answer JSON for a parsed card list. Pure.
pub fn tags_ok_json(cards: &[ost::api::tags::TagCardInfo]) -> String {
    let mut names: Vec<String> = cards.iter().map(|c| c.name.trim().to_lowercase()).filter(|n| !n.is_empty()).collect();
    names.sort();
    names.dedup();
    json!({"ok": true, "tags": names}).to_string()
}

/// The signed-in user's tag names (requires sign-in). Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_catchup_tags() -> *mut c_char {
    string_to_c(catchup_tags_json())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ost::api::tags::TagCardInfo;

    #[test]
    fn names_are_lowercased_sorted_and_deduped() {
        let c = |n: &str| TagCardInfo { team_id: "t".into(), tag_id: "i".into(), name: n.into() };
        let v: serde_json::Value =
            serde_json::from_str(&tags_ok_json(&[c("Designers"), c(" QA "), c("designers")])).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["tags"], json!(["designers", "qa"]));
        let none: serde_json::Value = serde_json::from_str(&tags_ok_json(&[])).unwrap();
        assert_eq!(none["tags"], json!([]));
    }
}
