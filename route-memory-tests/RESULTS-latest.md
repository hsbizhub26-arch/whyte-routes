# Route Memory acceptance results

Run f059a4 on whyte-routes-test-93ee0 - 2026-11-25T03:26:07.893Z

**23 PASS / 0 FAIL**

- **PASS** 1. 3 visits (6, 8, 10 min) -> predicts 8 min, 'avg of last 3 visits'
- **PASS** 2. new property, sizeTier double -> 9 min, 'estimate'
- **PASS** 3. run summary: total = sum, finish = start + total, 'service time only', heavy snow +30%
- **PASS** 4. finished run appears in Shift History with correct counts, total and per-stop detail
- **PASS** 5. CSV export: one row per stop with the same figures
- **PASS** 6. Company B never sees Company A (stats, history, predictions) - incl. hand-crafted queries
- **PASS** 7. avg 5 min, complete at 10 min -> flagged, '2.00x usual' in run detail and visit history
- **PASS** 8. same property, complete at 6 min -> NOT flagged
- **PASS** 9. avg 3 min, complete at 5 min (overrun exactly 120 s) -> NOT flagged
- **PASS** 10. reason chip saved + shown with the flag and in CSV; Complete never blocked by chips
- **PASS** 11. BOUNDARY avg 4 min, complete at exactly 6:00 -> NOT flagged
- **PASS** 12. BOUNDARY avg 4 min, complete at 6:01 -> flagged
- **PASS** 13. SNAPSHOT: later visits change the average, old flag + '2.00x usual' unchanged
- **PASS** 14. IDEMPOTENCY: same completion twice / retried -> stats apply once
- **PASS** 15. ELIGIBILITY: skipped + incomplete (+ recovered-from-logs) never touch average, prediction or flags
- **PASS** 16. DST: visit across 14 Mar 2027 spring-forward (America/Toronto), UTC storage, no 1-hour drift
- **PASS** 17. CONCURRENCY: two drivers complete at the same property at once (x3 rounds) - both counted once, stats consistent
- **PASS** 18. SNOW ISOLATION: Heavy snow run stores snowFactorActive; stats hold only real durations
- **PASS** 19. SCALE: 200 historical visits recompute without limit errors; last-5 average correct
- **PASS** 20. BASIS LABEL: 20 completed visits -> average of the 5 most recent, 'avg of last 5 visits'
- **PASS** 21. OWNER CORRECTION: recalculates that visit + property, others untouched, audit record, driver denied
- **PASS** D10. Decision 10: managers read ALL shift history + runs (read-only); drivers only their own
- **PASS** D9. Decision 9: recovered_from_logs + owner-ticked (no arrival) visits are excluded from stats