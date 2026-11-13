# MEETFIX-B-RERUN verdict: BLOCKED (scope gate, see notes REPORT3.md / PLAN2.md)

R1 calendar probe PASS 1/1 (auth back). R2 live session 1/1 spent: solo
"test" created + deleted (net zero writes), join threw Graph HTTP 404
(object not found in store) at CalendarGraph.swift:97 before any guest
join; 0 admit ops. Throw site irreconcilable with probe control flow,
no guess. R3/R4 gated. Zero source edits this lane.
