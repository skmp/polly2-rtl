# readme_scores.txt: the dreamcast-tests README's per-test scores of refsw3 (refsw3-offline against the console's archived
# pages, compare2.py <test> ref off: regions equal / regions) at the revision recorded in docs/PLAN.md (nulldc3 4f3efe15,
# dreamcast-tests a932980). tools/gate/refsw3_known.sh --expect must reproduce each exactly (make refglue-selftest).
#   faredge: README "faredge, modvol, hugepos: the edge unit past 2^128" (2026-11-20): "faredge 1340 of 1340"
#   hugepos_rules, hugepos_v5: README "r8 round 1" (nulldc3 1040c4aa .. 4f3efe15): "every regress test is exact
#   (hugepos_rules and hugepos_v5 too)"; 3,590 and 2,399 at 708fb8cd (PLAN M5)
faredge         1340/1340
hugepos_rules   3600/3600
hugepos_v5      2400/2400
