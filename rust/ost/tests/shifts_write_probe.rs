//! shifts-write lane: ONE live round-trip against the trial tenant.
//!
//! Ignored by default; run explicitly with the lane's isolated trial
//! config only (never the old tenant):
//!   OST_CONFIG_DIR=/Volumes/NVME/Projects/BetterTeams/tmp/trialadmin/ost-config \
//!   cargo test --test shifts_write_probe -- --ignored --nocapture
//!
//! Reads: schedule header + time-off reasons (GETs). Write: ONE
//! time-off REQUEST with a far-future range and a `test
//! (BetterTeams lane)` message. A 200 is immediately declined again
//! (net-zero: nothing persists); a 403 is the expected scope-pending
//! evidence (`Schedule.ReadWrite.All` is not in the trial token).

use ost::api::client::TeamsClient;
use ost::api::{
    create_timeoff_request_data, decide_change_request_data, is_missing_scope,
    list_change_requests_data, list_schedule_data, list_timeoff_reasons_data,
};

/// Trial tenant team under test (BetterTeams Test).
const TEAM: &str = "13b96e42-92ba-4562-8ff5-553a7425d763";

#[tokio::test]
#[ignore]
async fn shifts_write_probe() {
    let client = TeamsClient::new()
        .await
        .expect("trial sign-in (OST_CONFIG_DIR must point at the trial profile)");

    let schedule = list_schedule_data(&client, TEAM).await.expect("GET schedule");
    println!(
        "PROBE schedule enabled={} zone={:?} provision={:?}",
        schedule.enabled, schedule.time_zone, schedule.provision_status
    );

    let reasons = match list_timeoff_reasons_data(&client, TEAM).await {
        Ok(rs) => rs,
        Err(e) => {
            // Expected while Shifts is not provisioned: the collections
            // 404 (enabled=false, NotStarted above). Still attempt the
            // write below so its refusal names the missing scope.
            println!("PROBE GET timeOffReasons refused: {:#}", e);
            Vec::new()
        }
    };
    println!("PROBE reasons={}", reasons.len());
    for r in reasons.iter().take(5) {
        println!("PROBE reason id={} name={:?}", r.id, r.name);
    }

    // Far-future test range + lane subject: a leftover is unmistakable.
    // A placeholder reason still exercises the write path (the server
    // validates scope before the reason id).
    let reason = reasons.first().map(|r| r.id.clone()).unwrap_or_else(|| "probe-reason".to_string());
    let start = "2036-11-24T09:00:00";
    let end = "2036-11-24T17:00:00";
    match create_timeoff_request_data(&client, TEAM, &reason, start, end, Some("test (BetterTeams lane)")).await
    {
        Ok(id) => {
            println!("PROBE created time-off request id={}", id);
            decide_change_request_data(&client, TEAM, "timeoff", &id, false, Some("test (BetterTeams lane) cleanup"))
                .await
                .expect("decline the test request (net-zero)");
            let open = list_change_requests_data(&client, TEAM, "timeoff")
                .await
                .expect("re-list time-off requests");
            assert!(
                !open.iter().any(|r| r.id == id && r.state.as_deref() == Some("pending")),
                "test request {} still pending after decline (net-zero violated)",
                id
            );
            println!("PROBE declined {} again: net-zero, nothing persists", id);
        }
        Err(e) => {
            let text = format!("{:#}", e);
            println!("PROBE write refused: {}", text);
            assert!(
                is_missing_scope(&text),
                "write must fail with the missing-scope refusal, got: {}",
                text
            );
            println!("PROBE scope-pending confirmed (Schedule.ReadWrite.All not granted)");
        }
    }
}
