//! Planner boards over FFI — plans per team, buckets + tasks per plan.
//!
//! Om-planner lane. JSON envelopes mirror the om-remind lane:
//! `{ok,plans}`, `{ok,plan_id,buckets}`, `{ok,plan_id,tasks}`,
//! `{ok,task}`. Complete/reopen round-trip the task `etag` for the
//! required `If-Match` header (see `ost::api::planner`).

use std::ffi::CStr;
use std::os::raw::{c_char, c_int};

use serde_json::json;

use crate::{cstr_to_string, err_json, rt, string_to_c};

/// Reject a Graph path-segment id before any network. Mirrors the ost
/// guard; the FFI must never send a caller-controlled `/`/`?`/`#`.
fn planner_id_ok(what: &str, id: &str) -> Result<(), String> {
    if id.trim().is_empty() {
        return Err(err_json("arg", format!("empty {}", what)));
    }
    if id.contains('/')
        || id.contains('?')
        || id.contains('#')
        || id.chars().any(|c| c.is_whitespace())
    {
        return Err(err_json(
            "arg",
            format!("{} must not contain '/', '?', '#' or whitespace", what),
        ));
    }
    Ok(())
}

fn plan_to_json(p: &ost::api::PlanInfo) -> serde_json::Value {
    json!({
        "id": p.id,
        "title": p.title,
    })
}

fn bucket_to_json(b: &ost::api::BucketInfo) -> serde_json::Value {
    json!({
        "id": b.id,
        "plan_id": b.plan_id,
        "name": b.name,
    })
}

fn task_to_json(t: &ost::api::PlannerTaskInfo) -> serde_json::Value {
    json!({
        "id": t.id,
        "plan_id": t.plan_id,
        "bucket_id": t.bucket_id,
        "title": t.title,
        "percent": t.percent_complete,
        "completed": t.completed,
        "priority": t.priority,
        "due": t.due,
        "etag": t.etag,
        "assignees": t.assignee_ids,
    })
}

/// A team's plans as JSON. Requires sign-in; unsigned yields `{ok:false}`.
pub fn planner_plans_json(group_id: &str) -> String {
    if let Err(e) = planner_id_ok("group_id", group_id) {
        return e;
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let plans = ost::api::list_plans_data(&client, group_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = plans.iter().map(plan_to_json).collect();
            Ok(json!({"ok": true, "group_id": group_id, "plans": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_plans", e),
    }
}

/// One plan's buckets as JSON. Bad `plan_id` rejected before any network.
pub fn planner_buckets_json(plan_id: &str) -> String {
    if let Err(e) = planner_id_ok("plan_id", plan_id) {
        return e;
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let buckets = ost::api::list_buckets_data(&client, plan_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = buckets.iter().map(bucket_to_json).collect();
            Ok(json!({"ok": true, "plan_id": plan_id, "buckets": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_buckets", e),
    }
}

/// One plan's tasks as JSON. Bad `plan_id` rejected before any network.
pub fn planner_tasks_json(plan_id: &str, limit: usize) -> String {
    if let Err(e) = planner_id_ok("plan_id", plan_id) {
        return e;
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let tasks = ost::api::list_tasks_data(&client, plan_id, limit)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = tasks.iter().map(task_to_json).collect();
            Ok(json!({"ok": true, "plan_id": plan_id, "tasks": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_tasks", e),
    }
}

/// Create one task in a bucket. Returns `{ok:true, task}` or `{ok:false}`.
/// Empty ids/title are rejected before any network.
pub fn planner_add_json(plan_id: &str, bucket_id: &str, title: &str) -> String {
    if let Err(e) = planner_id_ok("plan_id", plan_id) {
        return e;
    }
    if let Err(e) = planner_id_ok("bucket_id", bucket_id) {
        return e;
    }
    if title.trim().is_empty() {
        return err_json("arg", "empty title");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let task = ost::api::create_task_data(&client, plan_id, bucket_id, title)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "task": task_to_json(&task)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_add", e),
    }
}

/// Complete (`complete=true`) or reopen one task. Returns `{ok:true, task}`
/// or `{ok:false}`. Bad ids / empty etag rejected before any network.
/// `TeamsClient::new` runs first so the token cache the `If-Match` PATCH
/// reads is refreshed.
pub fn planner_set_json(task_id: &str, etag: &str, complete: bool) -> String {
    if let Err(e) = planner_id_ok("task_id", task_id) {
        return e;
    }
    if etag.trim().is_empty() {
        return err_json("arg", "empty etag");
    }
    if etag.chars().any(|c| c == '\r' || c == '\n') {
        return err_json("arg", "etag must not contain CR or LF");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            // Refresh-first; the PATCH below reads the cached Graph token.
            let _ = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let task = ost::api::set_task_complete_data(task_id, etag, complete)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "task": task_to_json(&task)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_set", e),
    }
}

/// Assign (`assign=true`) or unassign one user on one task. Returns
/// `{ok:true, task}` or `{ok:false}`. Bad ids / empty etag rejected
/// before any network (same refresh-first contract as
/// [`planner_set_json`]).
pub fn planner_assign_json(task_id: &str, etag: &str, user_id: &str, assign: bool) -> String {
    if let Err(e) = planner_id_ok("task_id", task_id) {
        return e;
    }
    if let Err(e) = planner_id_ok("user_id", user_id) {
        return e;
    }
    if etag.trim().is_empty() {
        return err_json("arg", "empty etag");
    }
    if etag.chars().any(|c| c == '\r' || c == '\n') {
        return err_json("arg", "etag must not contain CR or LF");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let _ = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let task = ost::api::set_task_assignee_data(task_id, etag, user_id, assign)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "task": task_to_json(&task)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_assign", e),
    }
}

// ---------------------------------------------------------------------------
// C ABI. Caller frees every return with `ostmac_free`.
// ---------------------------------------------------------------------------

/// A team's plans JSON (requires sign-in). See [`planner_plans_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_plans(group_id: *const c_char) -> *mut c_char {
    match cstr_to_string(group_id) {
        Ok(g) => string_to_c(planner_plans_json(&g)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// One plan's buckets JSON. See [`planner_buckets_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_buckets(plan_id: *const c_char) -> *mut c_char {
    match cstr_to_string(plan_id) {
        Ok(p) => string_to_c(planner_buckets_json(&p)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// One plan's tasks JSON. See [`planner_tasks_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_tasks(
    plan_id: *const c_char,
    limit: c_int,
) -> *mut c_char {
    let lim = if limit <= 0 { 100 } else { limit as usize };
    match cstr_to_string(plan_id) {
        Ok(p) => string_to_c(planner_tasks_json(&p, lim)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Create one task in a bucket. See [`planner_add_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_add(
    plan_id: *const c_char,
    bucket_id: *const c_char,
    title: *const c_char,
) -> *mut c_char {
    let plan = match cstr_to_string(plan_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let bucket = match cstr_to_string(bucket_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(title) {
        Ok(t) => string_to_c(planner_add_json(&plan, &bucket, &t)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Mark one task completed (100). See [`planner_set_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_done(
    task_id: *const c_char,
    etag: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(task_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(etag) {
        Ok(e) => string_to_c(planner_set_json(&id, &e, true)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Reopen one task (0). See [`planner_set_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_reopen(
    task_id: *const c_char,
    etag: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(task_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(etag) {
        Ok(e) => string_to_c(planner_set_json(&id, &e, false)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Assign (`assign != 0`) or unassign one user on one task. See
/// [`planner_assign_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_assign(
    task_id: *const c_char,
    etag: *const c_char,
    user_id: *const c_char,
    assign: c_int,
) -> *mut c_char {
    let id = match cstr_to_string(task_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let tag = match cstr_to_string(etag) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(user_id) {
        Ok(u) => string_to_c(planner_assign_json(&id, &tag, &u, assign != 0)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    fn read_and_free(p: *mut c_char) -> serde_json::Value {
        assert!(!p.is_null());
        let s = unsafe { CStr::from_ptr(p).to_string_lossy().into_owned() };
        crate::ostmac_free(p);
        serde_json::from_str(&s).unwrap()
    }

    #[test]
    fn id_guard_rejects_path_breaking_before_network() {
        for bad in ["", "   ", "a/b", "a?b", "a#b", "a b"] {
            let v: serde_json::Value =
                serde_json::from_str(&planner_plans_json(bad)).unwrap();
            assert_eq!(v["error"], "arg", "group {:?}", bad);
            let v: serde_json::Value =
                serde_json::from_str(&planner_buckets_json(bad)).unwrap();
            assert_eq!(v["error"], "arg", "plan {:?}", bad);
            let v: serde_json::Value =
                serde_json::from_str(&planner_tasks_json(bad, 10)).unwrap();
            assert_eq!(v["error"], "arg", "tasks {:?}", bad);
        }
    }

    #[test]
    fn add_rejects_empty_title_and_bad_ids_before_network() {
        let v: serde_json::Value =
            serde_json::from_str(&planner_add_json("p1", "b1", "  ")).unwrap();
        assert_eq!(v["error"], "arg");
        let v: serde_json::Value =
            serde_json::from_str(&planner_add_json("p/", "b1", "x")).unwrap();
        assert_eq!(v["error"], "arg");
        let v: serde_json::Value =
            serde_json::from_str(&planner_add_json("p1", "b/", "x")).unwrap();
        assert_eq!(v["error"], "arg");
    }

    #[test]
    fn set_rejects_empty_etag_and_crlf_before_network() {
        let v: serde_json::Value =
            serde_json::from_str(&planner_set_json("t1", "", true)).unwrap();
        assert_eq!(v["error"], "arg");
        let v: serde_json::Value =
            serde_json::from_str(&planner_set_json("t1", "a\r\nb", false)).unwrap();
        assert_eq!(v["error"], "arg");
        let v: serde_json::Value =
            serde_json::from_str(&planner_set_json("t/", "W/\"e\"", true)).unwrap();
        assert_eq!(v["error"], "arg");
        for (task, etag, user) in [("t1", "W/\"e\"", "u/1"), ("t1", "", "u1"), ("t/", "W/\"e\"", "u1")] {
            let v: serde_json::Value =
                serde_json::from_str(&planner_assign_json(task, etag, user, true)).unwrap();
            assert_eq!(v["error"], "arg", "{:?}", (task, etag, user));
        }
    }

    #[test]
    fn ffi_nulls_are_arg_errors() {
        unsafe {
            let v = read_and_free(ostmac_planner_plans(std::ptr::null()));
            assert_eq!(v["error"], "arg");
            let v = read_and_free(ostmac_planner_buckets(std::ptr::null()));
            assert_eq!(v["error"], "arg");
            let v = read_and_free(ostmac_planner_tasks(std::ptr::null(), 10));
            assert_eq!(v["error"], "arg");
            let id = CString::new("p1").unwrap();
            let v = read_and_free(ostmac_planner_add(
                id.as_ptr(),
                std::ptr::null(),
                id.as_ptr(),
            ));
            assert_eq!(v["error"], "arg");
            let v = read_and_free(ostmac_planner_done(std::ptr::null(), id.as_ptr()));
            assert_eq!(v["error"], "arg");
            let v = read_and_free(ostmac_planner_reopen(id.as_ptr(), std::ptr::null()));
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_bad_ids_are_arg_errors_without_network() {
        let bad = CString::new("a/b").unwrap();
        unsafe {
            let v = read_and_free(ostmac_planner_plans(bad.as_ptr()));
            assert_eq!(v["error"], "arg");
            let v = read_and_free(ostmac_planner_tasks(bad.as_ptr(), 0));
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn converters_shape_wire_json() {
        let t = ost::api::PlannerTaskInfo {
            id: "T1".into(),
            plan_id: "P1".into(),
            bucket_id: "B1".into(),
            title: "Ship it".into(),
            percent_complete: 50,
            completed: false,
            priority: Some(1),
            due: Some("2026-10-02T12:00:00Z".into()),
            etag: "W/\"e1\"".into(),
            assignee_ids: vec!["u1".into()],
        };
        let v = task_to_json(&t);
        assert_eq!(v["assignees"], serde_json::json!(["u1"]));
        assert_eq!(v["id"], "T1");
        assert_eq!(v["percent"], 50);
        assert_eq!(v["completed"], false);
        assert_eq!(v["etag"], "W/\"e1\"");
        let b = ost::api::BucketInfo {
            id: "B1".into(),
            plan_id: "P1".into(),
            name: "To do".into(),
        };
        assert_eq!(bucket_to_json(&b)["name"], "To do");
        let p = ost::api::PlanInfo {
            id: "P1".into(),
            title: "Sprint".into(),
        };
        assert_eq!(plan_to_json(&p)["title"], "Sprint");
    }
}
