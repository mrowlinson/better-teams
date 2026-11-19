//! Planner boards over FFI — plans per team, buckets + tasks per plan.
//!
//! Om-planner lane. JSON envelopes mirror the om-remind lane:
//! `{ok,plans}`, `{ok,plan_id,buckets}`, `{ok,plan_id,tasks}`,
//! `{ok,task}`. Complete/reopen round-trip the task `etag` for the
//! required `If-Match` header (see `ost::api::planner`).

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
    let categories: serde_json::Map<String, serde_json::Value> = p
        .categories
        .iter()
        .map(|(n, name)| (format!("category{}", n), json!(name)))
        .collect();
    json!({
        "id": p.id,
        "title": p.title,
        "categories": categories,
        "etag": p.etag,
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
        "labels": t.applied_labels,
        "thread": t.thread_id,
    })
}

fn details_to_json(d: &ost::api::PlannerTaskDetails) -> serde_json::Value {
    json!({
        "etag": d.etag,
        "description": d.description,
        "preview": d.preview_type,
        "checklist": d.checklist.iter().map(|c| json!({
            "id": c.id,
            "title": c.title,
            "checked": c.checked,
        })).collect::<Vec<_>>(),
        "references": d.references.iter().map(|r| json!({
            "url": r.url,
            "alias": r.alias,
        })).collect::<Vec<_>>(),
    })
}

fn posts_to_json(posts: &[ost::api::GroupPost]) -> serde_json::Value {
    posts
        .iter()
        .map(|p| {
            json!({
                "id": p.id,
                "kind": p.content_type,
                "content": p.content,
                "received": p.received,
            })
        })
        .collect()
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

/// Etag pre-check shared by the depth writers: non-empty, single line.
/// Mirrors the `set`/`assign` guards so bad etags never reach network.
fn etag_ok(etag: &str) -> Result<(), String> {
    if etag.trim().is_empty() {
        return Err(err_json("arg", "empty etag"));
    }
    if etag.chars().any(|c| c == '\r' || c == '\n') {
        return Err(err_json("arg", "etag must not contain CR or LF"));
    }
    Ok(())
}

/// Parse plan label names from a JSON object string, `{"1":"Red"}`:
/// keys 1-6, non-empty names. Rejects everything else before network.
fn parse_category_names(names_json: &str) -> Result<Vec<(u8, String)>, String> {
    let v: serde_json::Value = serde_json::from_str(names_json)
        .map_err(|e| err_json("arg", format!("bad names json: {}", e)))?;
    let obj = v
        .as_object()
        .ok_or_else(|| err_json("arg", "names must be an object"))?;
    if obj.is_empty() {
        return Err(err_json("arg", "no categories"));
    }
    let mut out = Vec::new();
    for (k, name) in obj {
        let n: u8 = k
            .parse()
            .map_err(|_| err_json("arg", format!("bad category {}", k)))?;
        if !(1..=6).contains(&n) {
            return Err(err_json("arg", format!("bad category {}", k)));
        }
        let name = name.as_str().ok_or_else(|| err_json("arg", "bad category name"))?;
        if name.trim().is_empty() {
            return Err(err_json("arg", "empty category name"));
        }
        out.push((n, name.to_string()));
    }
    Ok(out)
}

/// Set (`on != 0`) or clear one label (1-6) on a task. Returns
/// `{ok:true, task}` or `{ok:false}`. Bad ids / etag / category
/// rejected before any network.
pub fn planner_labels_json(task_id: &str, etag: &str, category: i32, on: bool) -> String {
    if let Err(e) = planner_id_ok("task_id", task_id) {
        return e;
    }
    if let Err(e) = etag_ok(etag) {
        return e;
    }
    if !(1..=6).contains(&category) {
        return err_json("arg", "category must be 1-6");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let _ = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let task = ost::api::set_task_labels_data(task_id, etag, category as u8, on)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "task": task_to_json(&task)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_labels", e),
    }
}

/// Rename plan labels from a `{"1":"Red"}` object string. Returns
/// `{ok:true, plan}` or `{ok:false}`.
pub fn planner_plan_categories_json(plan_id: &str, names_json: &str) -> String {
    if let Err(e) = planner_id_ok("plan_id", plan_id) {
        return e;
    }
    let names = match parse_category_names(names_json) {
        Ok(n) => n,
        Err(e) => return e,
    };
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let plan = ost::api::set_plan_categories_data(&client, plan_id, &names)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "plan": plan_to_json(&plan)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_plan_categories", e),
    }
}

/// Fetch one task's details. Returns `{ok:true, task_id, details}` or
/// `{ok:false}`. Bad ids rejected before any network.
pub fn planner_details_json(task_id: &str) -> String {
    if let Err(e) = planner_id_ok("task_id", task_id) {
        return e;
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let details = ost::api::get_task_details_data(&client, task_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "task_id": task_id, "details": details_to_json(&details)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_details", e),
    }
}

/// Add/update (`remove == 0`) or remove one checklist item. Empty
/// `item_id` creates (title required). Returns `{ok:true}` or
/// `{ok:false}`.
pub fn planner_checklist_json(
    task_id: &str,
    etag: &str,
    item_id: &str,
    title: &str,
    checked: bool,
    remove: bool,
) -> String {
    if let Err(e) = planner_id_ok("task_id", task_id) {
        return e;
    }
    if let Err(e) = etag_ok(etag) {
        return e;
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::set_task_checklist_data(&client, task_id, item_id, title, checked, remove)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_checklist", e),
    }
}

/// Set a task's description. Returns `{ok:true}` or `{ok:false}`.
pub fn planner_description_json(task_id: &str, etag: &str, description: &str) -> String {
    if let Err(e) = planner_id_ok("task_id", task_id) {
        return e;
    }
    if let Err(e) = etag_ok(etag) {
        return e;
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::set_task_description_data(&client, task_id, description)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_description", e),
    }
}

/// Attach (`attach != 0`) or detach one URL reference.
/// Returns `{ok:true}` or `{ok:false}`.
pub fn planner_reference_json(
    task_id: &str,
    etag: &str,
    url: &str,
    alias: &str,
    attach: bool,
) -> String {
    if let Err(e) = planner_id_ok("task_id", task_id) {
        return e;
    }
    if let Err(e) = etag_ok(etag) {
        return e;
    }
    if url.trim().is_empty() || url.chars().any(|c| c.is_whitespace()) {
        return err_json("arg", "bad url");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::set_task_reference_data(&client, task_id, url, alias, attach)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_reference", e),
    }
}

/// Delete one task (`If-Match` with the task etag). Returns `{ok:true}`
/// or `{ok:false}`.
pub fn planner_task_delete_json(task_id: &str, etag: &str) -> String {
    if let Err(e) = planner_id_ok("task_id", task_id) {
        return e;
    }
    if let Err(e) = etag_ok(etag) {
        return e;
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let _ = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::delete_task_data(task_id, etag)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_task_delete", e),
    }
}

/// Create one plan under a group (team). Returns `{ok:true, plan}` or
/// `{ok:false}`.
pub fn planner_plan_create_json(group_id: &str, title: &str) -> String {
    if let Err(e) = planner_id_ok("group_id", group_id) {
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
            let plan = ost::api::create_plan_data(&client, group_id, title)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "plan": plan_to_json(&plan)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_plan_create", e),
    }
}

/// Delete one plan. Returns `{ok:true}` or `{ok:false}`.
pub fn planner_plan_delete_json(plan_id: &str) -> String {
    if let Err(e) = planner_id_ok("plan_id", plan_id) {
        return e;
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::delete_plan_data(&client, plan_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_plan_delete", e),
    }
}

/// Create one bucket in a plan. Returns `{ok:true, bucket}` or
/// `{ok:false}`.
pub fn planner_bucket_create_json(plan_id: &str, name: &str) -> String {
    if let Err(e) = planner_id_ok("plan_id", plan_id) {
        return e;
    }
    if name.trim().is_empty() {
        return err_json("arg", "empty name");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let bucket = ost::api::create_bucket_data(&client, plan_id, name)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "bucket": bucket_to_json(&bucket)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_bucket_create", e),
    }
}

/// Post one Planner comment (reply to the task's group thread).
/// Returns `{ok:true}` or `{ok:false}`.
pub fn planner_comment_json(group_id: &str, thread_id: &str, text: &str) -> String {
    if let Err(e) = planner_id_ok("group_id", group_id) {
        return e;
    }
    if let Err(e) = planner_id_ok("thread_id", thread_id) {
        return e;
    }
    if text.trim().is_empty() {
        return err_json("arg", "empty text");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::post_task_comment_data(&client, group_id, thread_id, text)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_comment", e),
    }
}

/// Read a plan thread's posts (Planner comments). Returns
/// `{ok:true, posts}` or `{ok:false}`.
pub fn planner_comments_json(group_id: &str, thread_id: &str) -> String {
    if let Err(e) = planner_id_ok("group_id", group_id) {
        return e;
    }
    if let Err(e) = planner_id_ok("thread_id", thread_id) {
        return e;
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let posts = ost::api::list_thread_posts_data(&client, group_id, thread_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "group_id": group_id, "thread_id": thread_id,
                       "posts": posts_to_json(&posts)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("planner_comments", e),
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

/// Set (`on != 0`) or clear one label (1-6) on a task. See
/// [`planner_labels_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_labels(
    task_id: *const c_char,
    etag: *const c_char,
    category: c_int,
    on: c_int,
) -> *mut c_char {
    let id = match cstr_to_string(task_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(etag) {
        Ok(e) => string_to_c(planner_labels_json(&id, &e, category, on != 0)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Rename plan labels from a `{"1":"Red"}` object string. See
/// [`planner_plan_categories_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_plan_categories(
    plan_id: *const c_char,
    names_json: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(plan_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(names_json) {
        Ok(n) => string_to_c(planner_plan_categories_json(&id, &n)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// One task's details JSON. See [`planner_details_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_details(task_id: *const c_char) -> *mut c_char {
    match cstr_to_string(task_id) {
        Ok(t) => string_to_c(planner_details_json(&t)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Add/update (`remove == 0`) or remove one checklist item. See
/// [`planner_checklist_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_checklist(
    task_id: *const c_char,
    etag: *const c_char,
    item_id: *const c_char,
    title: *const c_char,
    checked: c_int,
    remove: c_int,
) -> *mut c_char {
    let id = match cstr_to_string(task_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let tag = match cstr_to_string(etag) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let item = match cstr_to_string(item_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(title) {
        Ok(t) => string_to_c(planner_checklist_json(&id, &tag, &item, &t, checked != 0, remove != 0)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Set a task's description. See [`planner_description_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_description(
    task_id: *const c_char,
    etag: *const c_char,
    description: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(task_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let tag = match cstr_to_string(etag) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(description) {
        Ok(d) => string_to_c(planner_description_json(&id, &tag, &d)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Attach (`attach != 0`) or detach one URL reference. See
/// [`planner_reference_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_reference(
    task_id: *const c_char,
    etag: *const c_char,
    url: *const c_char,
    alias: *const c_char,
    attach: c_int,
) -> *mut c_char {
    let id = match cstr_to_string(task_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let tag = match cstr_to_string(etag) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let u = match cstr_to_string(url) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(alias) {
        Ok(a) => string_to_c(planner_reference_json(&id, &tag, &u, &a, attach != 0)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Delete one task. See [`planner_task_delete_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_task_delete(
    task_id: *const c_char,
    etag: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(task_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(etag) {
        Ok(e) => string_to_c(planner_task_delete_json(&id, &e)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Create one plan under a group (team). See
/// [`planner_plan_create_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_plan_create(
    group_id: *const c_char,
    title: *const c_char,
) -> *mut c_char {
    let group = match cstr_to_string(group_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(title) {
        Ok(t) => string_to_c(planner_plan_create_json(&group, &t)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Delete one plan. See [`planner_plan_delete_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_plan_delete(plan_id: *const c_char) -> *mut c_char {
    match cstr_to_string(plan_id) {
        Ok(p) => string_to_c(planner_plan_delete_json(&p)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Create one bucket in a plan. See [`planner_bucket_create_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_bucket_create(
    plan_id: *const c_char,
    name: *const c_char,
) -> *mut c_char {
    let plan = match cstr_to_string(plan_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(name) {
        Ok(n) => string_to_c(planner_bucket_create_json(&plan, &n)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Post one Planner comment. See [`planner_comment_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_comment(
    group_id: *const c_char,
    thread_id: *const c_char,
    text: *const c_char,
) -> *mut c_char {
    let group = match cstr_to_string(group_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let thread = match cstr_to_string(thread_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(text) {
        Ok(t) => string_to_c(planner_comment_json(&group, &thread, &t)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Read a plan thread's posts. See [`planner_comments_json`].
#[no_mangle]
pub extern "C" fn ostmac_planner_comments(
    group_id: *const c_char,
    thread_id: *const c_char,
) -> *mut c_char {
    let group = match cstr_to_string(group_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(thread_id) {
        Ok(t) => string_to_c(planner_comments_json(&group, &t)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};

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
            applied_labels: vec![1, 3],
            thread_id: "thread-1".into(),
        };
        let v = task_to_json(&t);
        assert_eq!(v["assignees"], serde_json::json!(["u1"]));
        assert_eq!(v["id"], "T1");
        assert_eq!(v["percent"], 50);
        assert_eq!(v["completed"], false);
        assert_eq!(v["etag"], "W/\"e1\"");
        assert_eq!(v["labels"], serde_json::json!([1, 3]));
        assert_eq!(v["thread"], "thread-1");
        let b = ost::api::BucketInfo {
            id: "B1".into(),
            plan_id: "P1".into(),
            name: "To do".into(),
        };
        assert_eq!(bucket_to_json(&b)["name"], "To do");
        let p = ost::api::PlanInfo {
            id: "P1".into(),
            title: "Sprint".into(),
            categories: vec![(1, "Red".into())],
            etag: "W/\"p-etag\"".into(),
        };
        assert_eq!(plan_to_json(&p)["title"], "Sprint");
        assert_eq!(
            plan_to_json(&p)["categories"],
            serde_json::json!({ "category1": "Red" })
        );
    }

    #[test]
    fn depth_rejects_bad_args_before_network() {
        for (task, etag) in [("t/", "W/\"e\""), ("t1", ""), ("t1", "a\r\nb")] {
            let v: serde_json::Value =
                serde_json::from_str(&planner_labels_json(task, etag, 1, true)).unwrap();
            assert_eq!(v["error"], "arg", "{:?}", (task, etag));
            let v: serde_json::Value =
                serde_json::from_str(&planner_task_delete_json(task, etag)).unwrap();
            assert_eq!(v["error"], "arg", "{:?}", (task, etag));
        }
        // Category out of range (valid ids/etag: pure arg check).
        let v: serde_json::Value =
            serde_json::from_str(&planner_labels_json("t1", "W/\"e\"", 0, true)).unwrap();
        assert_eq!(v["error"], "arg");
        let v: serde_json::Value =
            serde_json::from_str(&planner_labels_json("t1", "W/\"e\"", 7, false)).unwrap();
        assert_eq!(v["error"], "arg");
        // Category names: bad JSON, empty, out-of-range key, blank name.
        for names in ["nope", "[]", "{}", "{\"0\":\"x\"}", "{\"7\":\"x\"}", "{\"1\":\" \"}", "{\"1\":1}"] {
            let v: serde_json::Value =
                serde_json::from_str(&planner_plan_categories_json("p1", names)).unwrap();
            assert_eq!(v["error"], "arg", "{}", names);
        }
        let v: serde_json::Value =
            serde_json::from_str(&planner_plan_categories_json("p/", "{\"1\":\"R\"}")).unwrap();
        assert_eq!(v["error"], "arg");
        // Details / description / reference / comment guards.
        let v: serde_json::Value =
            serde_json::from_str(&planner_details_json("t/")).unwrap();
        assert_eq!(v["error"], "arg");
        let v: serde_json::Value =
            serde_json::from_str(&planner_checklist_json("t1", "", "", "x", false, false)).unwrap();
        assert_eq!(v["error"], "arg");
        let v: serde_json::Value =
            serde_json::from_str(&planner_description_json("t/", "W/\"e\"", "d")).unwrap();
        assert_eq!(v["error"], "arg");
        let v: serde_json::Value =
            serde_json::from_str(&planner_reference_json("t1", "W/\"e\"", " ", "a", true)).unwrap();
        assert_eq!(v["error"], "arg");
        let v: serde_json::Value =
            serde_json::from_str(&planner_reference_json("t1", "W/\"e\"", "a b", "a", true)).unwrap();
        assert_eq!(v["error"], "arg");
        let v: serde_json::Value =
            serde_json::from_str(&planner_comment_json("g1", "th1", "  ")).unwrap();
        assert_eq!(v["error"], "arg");
        let v: serde_json::Value =
            serde_json::from_str(&planner_comments_json("g/", "th1")).unwrap();
        assert_eq!(v["error"], "arg");
        // Plan / bucket create guards.
        let v: serde_json::Value =
            serde_json::from_str(&planner_plan_create_json("g1", "  ")).unwrap();
        assert_eq!(v["error"], "arg");
        let v: serde_json::Value =
            serde_json::from_str(&planner_plan_create_json("g/", "Board")).unwrap();
        assert_eq!(v["error"], "arg");
        let v: serde_json::Value =
            serde_json::from_str(&planner_bucket_create_json("p1", " ")).unwrap();
        assert_eq!(v["error"], "arg");
        let v: serde_json::Value =
            serde_json::from_str(&planner_plan_delete_json("p/")).unwrap();
        assert_eq!(v["error"], "arg");
    }

    #[test]
    fn depth_ffi_nulls_are_arg_errors() {
        unsafe {
            let id = CString::new("x").unwrap();
            let v = read_and_free(ostmac_planner_labels(id.as_ptr(), std::ptr::null(), 1, 1));
            assert_eq!(v["error"], "arg");
            let v = read_and_free(ostmac_planner_details(std::ptr::null()));
            assert_eq!(v["error"], "arg");
            let v = read_and_free(ostmac_planner_task_delete(id.as_ptr(), std::ptr::null()));
            assert_eq!(v["error"], "arg");
            let v = read_and_free(ostmac_planner_plan_create(id.as_ptr(), std::ptr::null()));
            assert_eq!(v["error"], "arg");
            let v = read_and_free(ostmac_planner_plan_delete(std::ptr::null()));
            assert_eq!(v["error"], "arg");
            let v = read_and_free(ostmac_planner_comments(id.as_ptr(), std::ptr::null()));
            assert_eq!(v["error"], "arg");
        }
    }
}
