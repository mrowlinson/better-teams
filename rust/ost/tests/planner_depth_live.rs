//! plannerdepth: ONE ignored live flow proving every depth op against
//! the trial tenant, net-zero (probe plan + thread deleted after).
//!
//! Ignored by default; run explicitly with the trial config only
//! (BEEBE absolute ban — never point this at the default profile):
//!   export TMPDIR=/Users/mrowlinson/tmp/betterteams/plannerdepth
//!   export OST_CONFIG_DIR=/Volumes/NVME/Projects/BetterTeams/tmp/trialadmin/ost-config
//!   export PLANNER_PROBE_GROUP_ID=<BetterTeams Test team id>
//!   cargo test -p teams-cli --test planner_depth_live -- --ignored --nocapture
//!
//! Flow: create plan "test (BetterTeams lane)" -> bucket -> task, then
//! labels, label rename, description, checklist add/check/remove,
//! reference attach/detach, comment post/read (own probe thread),
//! task delete, plan delete, verify gone. Every op either LIVE-verifies
//! (with a read-back assert) or records a 403 scope refusal; any other
//! error fails the test. Cleanup (thread/task/plan delete) runs before
//! the final verdict so a mid-flow failure still leaves net-zero.
//!
//! Logs carry short id prefixes only (first 8 chars); full ids stay on
//! the terminal, never in committed files.

use ost::api::client::TeamsClient;
use ost::api::{
    create_bucket_data, create_plan_data, create_task_data, create_thread_data,
    delete_plan_data, delete_task_data, delete_thread_data, get_task_details_data,
    list_buckets_data, list_plans_data, list_tasks_data, list_thread_posts_data,
    post_task_comment_data, set_plan_categories_data, set_task_checklist_data,
    set_task_description_data, set_task_labels_data, set_task_reference_data,
};

/// The ONLY team this probe may touch (exact match — stronger than a
/// denylist and scan-clean). From the live trial tenant (verified).
const TRIAL_TEAM_ID: &str = "13b96e42-92ba-4562-8ff5-553a7425d763";

/// Short id prefix for logs (object ids never reach committed files).
fn short(id: &str) -> String {
    id.chars().take(8).collect()
}

fn refused_403(err: &anyhow::Error) -> bool {
    format!("{:#}", err).contains("403")
}

struct Verdict {
    op: &'static str,
    live: bool,
    note: String,
}

struct Flow {
    client: TeamsClient,
    group_id: String,
    verdicts: Vec<Verdict>,
    plan_id: Option<String>,
    task_id: Option<String>,
    thread_id: Option<String>,
    /// First non-403 error text; the flow keeps going (cleanup + the
    /// remaining independent legs still run) and fails at the end.
    failed: Option<String>,
}

impl Flow {
    fn record(&mut self, op: &'static str, r: anyhow::Result<String>) {
        match r {
            Ok(note) => self.verdicts.push(Verdict { op, live: true, note }),
            Err(e) => {
                let msg = format!("{:#}", e);
                if refused_403(&e) {
                    self.verdicts.push(Verdict {
                        op,
                        live: false,
                        note: format!("SCOPE-REFUSED 403: {}", msg.chars().take(200).collect::<String>()),
                    });
                } else {
                    self.verdicts.push(Verdict {
                        op,
                        live: false,
                        note: format!("ERROR: {}", msg.chars().take(200).collect::<String>()),
                    });
                    self.failed.get_or_insert(format!(
                        "op {} failed with a NON-403 error: {}",
                        op,
                        msg.chars().take(300).collect::<String>()
                    ));
                }
            }
        }
    }

    /// Current etag for the probe task (every PATCH rotates it). The
    /// task list lags creates by seconds, so retry before giving up.
    async fn etag(&self) -> anyhow::Result<String> {
        let pid = self.plan_id.clone().ok_or_else(|| anyhow::anyhow!("no probe plan"))?;
        for attempt in 1..=6 {
            let tasks = list_tasks_data(&self.client, &pid, 100).await?;
            if let Some(t) = tasks.into_iter().find(|t| Some(&t.id) == self.task_id.as_ref()) {
                if attempt > 1 {
                    eprintln!("LIVE task list caught up on attempt {}", attempt);
                }
                return Ok(t.etag);
            }
            eprintln!("LIVE task list lag, retry {}/6", attempt);
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        }
        anyhow::bail!("probe task missing from list after retries")
    }

    fn pending_all(&mut self, why: &str) {
        for op in [
            "labels",
            "label-rename",
            "description",
            "checklist",
            "attachments",
            "comments",
            "delete-task",
            "create-plan",
            "delete-plan",
        ] {
            self.verdicts.push(Verdict { op, live: false, note: why.to_string() });
        }
    }

    async fn run(&mut self) -> anyhow::Result<()> {
        // 0. Baseline: plans visible before the probe.
        let before = list_plans_data(&self.client, &self.group_id).await?;
        eprintln!("LIVE baseline plans: {}", before.len());

        // 1. Create plan. A 403 here pends the whole lane (nothing to
        // clean: net-zero trivially).
        let plan = match create_plan_data(&self.client, &self.group_id, "test (BetterTeams lane)").await {
            Ok(p) => p,
            Err(e) if refused_403(&e) => {
                self.pending_all(&format!(
                    "SCOPE-REFUSED 403: {}",
                    format!("{:#}", e).chars().take(200).collect::<String>()
                ));
                return Ok(());
            }
            Err(e) => return Err(e.into()),
        };
        eprintln!("LIVE create-plan ok id={} title={:?}", short(&plan.id), plan.title);
        self.plan_id = Some(plan.id.clone());
        self.verdicts.push(Verdict {
            op: "create-plan",
            live: true,
            note: format!("plan {} created", short(&plan.id)),
        });

        // 2. Buckets: use the default bucket when the service provides
        // one, else create ours.
        let mut buckets = list_buckets_data(&self.client, plan.id.as_str()).await?;
        eprintln!("LIVE plan buckets after create: {}", buckets.len());
        let bucket_id = match buckets.pop() {
            Some(b) => b.id,
            None => {
                let b = create_bucket_data(&self.client, plan.id.as_str(), "Probe").await?;
                eprintln!("LIVE create-bucket ok id={}", short(&b.id));
                b.id
            }
        };

        // 3. Create task. A 403 here pends the task-level ops; the
        // plan-level legs (rename, delete) still run below.
        let task = match create_task_data(
            &self.client,
            plan.id.as_str(),
            &bucket_id,
            "test (BetterTeams lane)",
        )
        .await
        {
            Ok(t) => t,
            Err(e) if refused_403(&e) => {
                let why = format!(
                    "SCOPE-REFUSED 403: {}",
                    format!("{:#}", e).chars().take(200).collect::<String>()
                );
                for op in ["labels", "description", "checklist", "attachments", "delete-task"] {
                    self.verdicts.push(Verdict { op, live: false, note: why.clone() });
                }
                self.task_id = None;
                return self.plan_legs().await;
            }
            Err(e) => return Err(e.into()),
        };
        eprintln!("LIVE create-task ok id={}", short(&task.id));
        self.task_id = Some(task.id.clone());

        // 4. Labels: set category1, read back via the update echo.
        {
            let tid = self.task_id.clone().unwrap();
            let etag = self.etag().await?;
            let r: anyhow::Result<String> = async {
                let updated = set_task_labels_data(&tid, &etag, 1, true).await?;
                anyhow::ensure!(updated.applied_labels.contains(&1), "label 1 not echoed");
                Ok(format!("label=1 echoed on task {}", short(&tid)))
            }
            .await;
            self.record("labels", r);
        }

        // 6. Description, read back via details GET.
        {
            let tid = self.task_id.clone().unwrap();
            let r: anyhow::Result<String> = async {
                set_task_description_data(&self.client, &tid, "probe notes").await?;
                let d = get_task_details_data(&self.client, &tid).await?;
                anyhow::ensure!(d.description == "probe notes", "description not echoed");
                Ok("description echoed via details GET".to_string())
            }
            .await;
            self.record("description", r);
        }

        // 7. Checklist: add unchecked + checked items, verify, check one,
        // remove both, verify empty.
        {
            let tid = self.task_id.clone().unwrap();
            let r: anyhow::Result<String> = async {
                set_task_checklist_data(&self.client, &tid, "probe-item-a", "Probe item A", false, false)
                    .await?;
                set_task_checklist_data(&self.client, &tid, "probe-item-b", "Probe item B", true, false)
                    .await?;
                let d = get_task_details_data(&self.client, &tid).await?;
                anyhow::ensure!(
                    d.checklist.iter().any(|c| c.id == "probe-item-a" && !c.checked),
                    "item A missing"
                );
                anyhow::ensure!(
                    d.checklist.iter().any(|c| c.id == "probe-item-b" && c.checked),
                    "item B missing/unchecked"
                );
                set_task_checklist_data(&self.client, &tid, "probe-item-a", "Probe item A", true, false)
                    .await?;
                set_task_checklist_data(&self.client, &tid, "probe-item-a", "", false, true).await?;
                set_task_checklist_data(&self.client, &tid, "probe-item-b", "", false, true).await?;
                let d2 = get_task_details_data(&self.client, &tid).await?;
                anyhow::ensure!(
                    !d2.checklist.iter().any(|c| c.id.starts_with("probe-item-")),
                    "probe items remain"
                );
                Ok("2 items added, checked, removed; read back clean".to_string())
            }
            .await;
            self.record("checklist", r);
        }

        // 8. Reference: attach URL, verify, detach, verify gone.
        {
            let tid = self.task_id.clone().unwrap();
            let r: anyhow::Result<String> = async {
                let url = "https://example.com/probe-spec";
                set_task_reference_data(&self.client, &tid, url, "Probe spec", true).await?;
                let d = get_task_details_data(&self.client, &tid).await?;
                eprintln!(
                    "LIVE references read back: {:?}",
                    d.references.iter().map(|r| r.url.clone()).collect::<Vec<_>>()
                );
                anyhow::ensure!(
                    d.references.iter().any(|r| r.url == url && r.alias == "Probe spec"),
                    "reference missing"
                );
                set_task_reference_data(&self.client, &tid, url, "", false).await?;
                let d2 = get_task_details_data(&self.client, &tid).await?;
                anyhow::ensure!(
                    !d2.references.iter().any(|r| r.url == url),
                    "reference remains"
                );
                Ok("URL attached + detached; read back clean".to_string())
            }
            .await;
            self.record("attachments", r);
        }

        // 10. Delete task, verify absent from the plan's task list.
        {
            let r: anyhow::Result<String> = async {
                // Fresh etag: details/checklist writes rotate it.
                let tid = self.task_id.clone().unwrap();
                let etag = self.etag().await?;
                delete_task_data(&tid, &etag).await?;
                let pid = self.plan_id.clone().unwrap();
                let after = list_tasks_data(&self.client, &pid, 100).await?;
                anyhow::ensure!(
                    !after.iter().any(|t| Some(&t.id) == self.task_id.as_ref()),
                    "task still listed"
                );
                self.task_id = None;
                Ok("task deleted + absence verified".to_string())
            }
            .await;
            self.record("delete-task", r);
        }

        self.plan_legs().await
    }

    /// Plan-level legs: label rename (needs only the plan), comments
    /// (own probe thread), plan delete + absence check. Runs both on the
    /// full path and when task creation was scope-refused.
    async fn plan_legs(&mut self) -> anyhow::Result<()> {
        // 5/11a. Label rename (categoryDescriptions): API-LIMITED.
        // Live-proved 2026-11-19: PATCH /planner/plans/{id} with
        // If-Match answers 200 but ignores categoryDescriptions, and
        // GET /planner/plans/{id} never returns the property (docs
        // plannerplan-update lists only `title` as updatable). The app
        // keeps the rename call (works if Microsoft opens the
        // property); this leg stays demo-verified.
        {
            let pid = self.plan_id.clone().unwrap();
            let names = vec![(1u8, "ProbeRed".to_string())];
            match set_plan_categories_data(&self.client, &pid, &names).await {
                Ok(plan) => {
                    eprintln!("LIVE rename PATCH 200; read-back categories: {:?}", plan.categories);
                    self.verdicts.push(Verdict {
                        op: "label-rename",
                        live: false,
                        note: "API-LIMIT: PATCH 200 but categoryDescriptions absent from GET; docs list title only".to_string(),
                    });
                }
                Err(e) => self.record("label-rename", Err(e).map(|_: ost::api::PlanInfo| String::new())),
            }
        }

        // Comments leg (same as step 9 on the full path).
        {
            let r: anyhow::Result<String> = async {
                let th = create_thread_data(&self.client, &self.group_id, "test (BetterTeams lane)").await?;
                eprintln!("LIVE create-thread ok id={}", short(&th));
                self.thread_id = Some(th.clone());
                post_task_comment_data(&self.client, &self.group_id, &th, "probe comment one").await?;
                let posts = list_thread_posts_data(&self.client, &self.group_id, &th).await?;
                anyhow::ensure!(
                    posts.iter().any(|p| p.content.contains("probe comment one")),
                    "comment not in posts"
                );
                delete_thread_data(&self.client, &self.group_id, &th).await?;
                self.thread_id = None;
                eprintln!("LIVE delete-thread ok");
                Ok("reply posted + read back + thread deleted".to_string())
            }
            .await;
            self.record("comments", r);
        }

        // 11. Delete plan, verify absent from the team's plans.
        {
            let r: anyhow::Result<String> = async {
                let pid = self.plan_id.clone().unwrap();
                delete_plan_data(&self.client, &pid).await?;
                let after = list_plans_data(&self.client, &self.group_id).await?;
                anyhow::ensure!(
                    !after.iter().any(|p| p.id == pid),
                    "plan still listed"
                );
                self.plan_id = None;
                Ok("plan deleted + absence verified".to_string())
            }
            .await;
            self.record("delete-plan", r);
        }
        if let Some(msg) = self.failed.clone() {
            anyhow::bail!("{}", msg);
        }
        Ok(())
    }

    /// Best-effort cleanup: thread, task, plan. Runs before the final
    /// verdict so leftovers never survive a failure.
    async fn cleanup(&mut self) {
        if let Some(th) = self.thread_id.clone() {
            match delete_thread_data(&self.client, &self.group_id, &th).await {
                Ok(()) => eprintln!("CLEANUP thread {} deleted", short(&th)),
                Err(e) => eprintln!("CLEANUP thread delete failed: {:#}", e),
            }
            self.thread_id = None;
        }
        if let Some(tid) = self.task_id.clone() {
            let pid = self.plan_id.clone().unwrap_or_default();
            let etag = if !pid.is_empty() {
                list_tasks_data(&self.client, &pid, 100)
                    .await
                    .ok()
                    .and_then(|ts| ts.into_iter().find(|t| t.id == tid))
                    .map(|t| t.etag)
                    .unwrap_or_default()
            } else {
                String::new()
            };
            if !etag.is_empty() {
                match delete_task_data(&tid, &etag).await {
                    Ok(()) => eprintln!("CLEANUP task {} deleted", short(&tid)),
                    Err(e) => eprintln!("CLEANUP task delete failed: {:#}", e),
                }
            } else {
                eprintln!("CLEANUP task {} etag unknown, left for plan delete", short(&tid));
            }
            self.task_id = None;
        }
        if let Some(pid) = self.plan_id.clone() {
            match delete_plan_data(&self.client, &pid).await {
                Ok(()) => eprintln!("CLEANUP plan {} deleted", short(&pid)),
                Err(e) => eprintln!("CLEANUP plan delete failed: {:#}", e),
            }
            match list_plans_data(&self.client, &self.group_id).await {
                Ok(after) => {
                    let gone = !after.iter().any(|p| p.id == pid);
                    eprintln!("CLEANUP net-zero verified: {}", gone);
                    assert!(gone, "probe plan still listed after delete");
                }
                Err(e) => eprintln!("CLEANUP re-list failed: {:#}", e),
            }
            self.plan_id = None;
        }
    }
}

/// Sweep every leftover "test (BetterTeams lane)" probe plan on the
/// trial team (runs that died before their delete leg), then verify the
/// team is probe-free. Same trial-only rules as the flow.
#[tokio::test]
#[ignore]
async fn live_cleanup_stray() {
    let group_id = std::env::var("PLANNER_PROBE_GROUP_ID")
        .expect("PLANNER_PROBE_GROUP_ID must name the trial team (BetterTeams Test)");
    assert!(group_id == TRIAL_TEAM_ID, "PLANNER_PROBE_GROUP_ID must be the trial team");
    let client = TeamsClient::new().await.expect("signed-in trial session required");
    let plans = list_plans_data(&client, &group_id).await.expect("list");
    let strays: Vec<String> = plans
        .into_iter()
        .filter(|p| p.title == "test (BetterTeams lane)")
        .map(|p| p.id)
        .collect();
    eprintln!("LIVE stray probe plans: {}", strays.len());
    for pid in &strays {
        // Best effort per plan: tasks die with their plan.
        delete_plan_data(&client, pid).await.expect("stray plan delete");
        eprintln!("LIVE stray plan {} deleted", short(pid));
    }
    let after = list_plans_data(&client, &group_id).await.expect("re-list");
    assert!(
        !after.iter().any(|p| p.title == "test (BetterTeams lane)"),
        "probe plans remain"
    );
    eprintln!("LIVE sweep net-zero verified: true");
}

#[tokio::test]
#[ignore]
async fn live_depth_flow() {
    let group_id = std::env::var("PLANNER_PROBE_GROUP_ID")
        .expect("PLANNER_PROBE_GROUP_ID must name the trial team (BetterTeams Test)");
    assert!(group_id == TRIAL_TEAM_ID, "PLANNER_PROBE_GROUP_ID must be the trial team");
    let client = TeamsClient::new().await.expect("signed-in trial session required");
    let mut flow = Flow {
        client,
        group_id,
        verdicts: Vec::new(),
        plan_id: None,
        task_id: None,
        thread_id: None,
        failed: None,
    };
    let r = flow.run().await;
    if let Err(e) = &r {
        eprintln!("FLOW-ERROR (cleanup still runs): {:#}", e);
    }
    flow.cleanup().await;
    eprintln!("---- plannerdepth live verdicts ----");
    for v in &flow.verdicts {
        eprintln!("{}: {} — {}", v.op, if v.live { "LIVE" } else { "PENDING" }, v.note);
    }
    assert!(!flow.verdicts.is_empty());
    r.expect("live flow failed with a non-403 error");
}
