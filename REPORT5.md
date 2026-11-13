# MEETFIX-B-RERUN3 verdict: BLOCKED (scope gate, see notes REPORT5.md / PLAN2.md)

R0 per-step probe committed (bd1ca7f2, test-only). R1 calendar probe
PASS 1/1. R2 live session 1/1 spent: solo "test" created + deleted (net zero
writes); JOIN catch named CoreCallError auth "no tenant_id; sign in first"
(rust calls.rs:1447, tenant gate before any network), yet XCTest still
attributes the failure to CalendarGraph.swift:97 Graph HTTP 404 — same error
value from :97 cannot have passed the probe's catches; mechanism unknown.
0 guests, 0 admit ops. R3/R4 gated. Zero product edits this lane.
