# Tool-result retention replay — aggregate evidence

Run command: python3 eval/compaction-replay/replay.py --projects "$CC_ORCH_CLAUDE_PROJECTS" --out "$REPLAY_OUT" --seed 20261002 --bootstrap 2000 --p3 local --p3-model "$REPLAY_MODEL" --p3-server "$REPLAY_SERVER" --note "$REPLAY_NOTE" --criteria-commit 34380fafac8d5d7c2350c3f3fdbb2a8dfc4fb257
Criteria commit: 34380fafac8d5d7c2350c3f3fdbb2a8dfc4fb257
P3 status: P3 skipped: model file missing
Runtime seconds: 95.226
Peak RSS MiB: 62.348
Source hash check: 20/20 unchanged

## Corpus and normalization

| count | value |
|---|---:|
| copied_records | 11 |
| dup_conflicts | 25 |
| dup_records_in_file | 45 |
| excluded_records | 1923 |
| files_discovered | 439 |
| files_evaluated | 376 |
| files_skipped_copy | 1 |
| main_files | 94 |
| nontext_result_blocks | 849 |
| parse_errors | 0 |
| records | 190711 |
| subagent_files | 344 |

## Retention by policy and stratum

Counts pool file/cut units; files are counted once within each cell.

| arm | stratum | files | cuts | bytes total | bytes removed | removed share | 95% CI | lost agentIds |
|---|---|---:|---:|---:|---:|---:|---|---:|
| P0 | pooled | 376 | 1135 | 153648332 | 0 | 0.000000 | [0.000000, 0.000000] | 0 |
| P0 | file_kind:main | 48 | 149 | 17040612 | 0 | 0.000000 | [0.000000, 0.000000] | 0 |
| P0 | file_kind:subagent | 328 | 986 | 136607720 | 0 | 0.000000 | [0.000000, 0.000000] | 0 |
| P0 | cut_kind:real | 10 | 13 | 6056858 | 0 | 0.000000 | [0.000000, 0.000000] | 0 |
| P0 | cut_kind:synthetic | 374 | 1122 | 147591474 | 0 | 0.000000 | [0.000000, 0.000000] | 0 |
| P0 | size_bucket:50-199 | 177 | 531 | 85839430 | 0 | 0.000000 | [0.000000, 0.000000] | 0 |
| P0 | size_bucket:8-49 | 163 | 489 | 30684098 | 0 | 0.000000 | [0.000000, 0.000000] | 0 |
| P0 | size_bucket:<8 | 2 | 2 | 0 | 0 | n/a | n/a | 0 |
| P0 | size_bucket:>=200 | 34 | 113 | 37124804 | 0 | 0.000000 | [0.000000, 0.000000] | 0 |
| P1 | pooled | 376 | 1135 | 153648332 | 119339684 | 0.776707 | [0.750709, 0.801746] | 26 |
| P1 | file_kind:main | 48 | 149 | 17040612 | 11192697 | 0.656825 | [0.471790, 0.770444] | 3 |
| P1 | file_kind:subagent | 328 | 986 | 136607720 | 108146987 | 0.791661 | [0.768230, 0.812711] | 23 |
| P1 | cut_kind:real | 10 | 13 | 6056858 | 5959061 | 0.983854 | [0.976309, 0.989893] | 0 |
| P1 | cut_kind:synthetic | 374 | 1122 | 147591474 | 113380623 | 0.768206 | [0.743312, 0.791130] | 26 |
| P1 | size_bucket:50-199 | 177 | 531 | 85839430 | 71712019 | 0.835420 | [0.820235, 0.849497] | 22 |
| P1 | size_bucket:8-49 | 163 | 489 | 30684098 | 12063790 | 0.393161 | [0.354113, 0.430726] | 0 |
| P1 | size_bucket:<8 | 2 | 2 | 0 | 0 | n/a | n/a | 0 |
| P1 | size_bucket:>=200 | 34 | 113 | 37124804 | 35563875 | 0.957955 | [0.949771, 0.965120] | 4 |
| P2 | pooled | 376 | 1135 | 153648332 | 45608649 | 0.296838 | [0.276736, 0.317723] | 0 |
| P2 | file_kind:main | 48 | 149 | 17040612 | 3908562 | 0.229367 | [0.165830, 0.284971] | 0 |
| P2 | file_kind:subagent | 328 | 986 | 136607720 | 41700087 | 0.305254 | [0.283759, 0.325901] | 0 |
| P2 | cut_kind:real | 10 | 13 | 6056858 | 1925646 | 0.317928 | [0.273761, 0.370623] | 0 |
| P2 | cut_kind:synthetic | 374 | 1122 | 147591474 | 43683003 | 0.295972 | [0.275159, 0.316895] | 0 |
| P2 | size_bucket:50-199 | 177 | 531 | 85839430 | 29073885 | 0.338701 | [0.310459, 0.369991] | 0 |
| P2 | size_bucket:8-49 | 163 | 489 | 30684098 | 4542735 | 0.148049 | [0.131388, 0.165544] | 0 |
| P2 | size_bucket:<8 | 2 | 2 | 0 | 0 | n/a | n/a | 0 |
| P2 | size_bucket:>=200 | 34 | 113 | 37124804 | 11992029 | 0.323019 | [0.290012, 0.352239] | 0 |

| arm | stratum | class | needed | retained | recall | 95% CI | rederivable | resurfaced | not_used |
|---|---|---|---:|---:|---:|---|---:|---:|---:|
| P0 | pooled | agentid | 50 | 50 | 1.000000 | [1.000000, 1.000000] | 424 | 62 | 967 |
| P0 | pooled | path | 8075 | 8075 | 1.000000 | [1.000000, 1.000000] | 39571 | 14045 | 144658 |
| P0 | pooled | sha | 1147 | 1147 | 1.000000 | [1.000000, 1.000000] | 3658 | 1989 | 16293 |
| P0 | pooled | error | 106 | 106 | 1.000000 | [1.000000, 1.000000] | 209 | 1074 | 25938 |
| P0 | file_kind:main | agentid | 7 | 7 | 1.000000 | [1.000000, 1.000000] | 283 | 10 | 32 |
| P0 | file_kind:main | path | 807 | 807 | 1.000000 | [1.000000, 1.000000] | 6503 | 1537 | 19262 |
| P0 | file_kind:main | sha | 132 | 132 | 1.000000 | [1.000000, 1.000000] | 1038 | 205 | 2460 |
| P0 | file_kind:main | error | 12 | 12 | 1.000000 | [1.000000, 1.000000] | 39 | 178 | 3286 |
| P0 | file_kind:subagent | agentid | 43 | 43 | 1.000000 | [1.000000, 1.000000] | 141 | 52 | 935 |
| P0 | file_kind:subagent | path | 7268 | 7268 | 1.000000 | [1.000000, 1.000000] | 33068 | 12508 | 125396 |
| P0 | file_kind:subagent | sha | 1015 | 1015 | 1.000000 | [1.000000, 1.000000] | 2620 | 1784 | 13833 |
| P0 | file_kind:subagent | error | 94 | 94 | 1.000000 | [1.000000, 1.000000] | 170 | 896 | 22652 |
| P0 | cut_kind:real | agentid | 1 | 1 | 1.000000 | [1.000000, 1.000000] | 128 | 2 | 21 |
| P0 | cut_kind:real | path | 38 | 38 | 1.000000 | [1.000000, 1.000000] | 2619 | 272 | 6276 |
| P0 | cut_kind:real | sha | 5 | 5 | 1.000000 | [1.000000, 1.000000] | 378 | 34 | 789 |
| P0 | cut_kind:real | error | 0 | 0 | n/a | n/a | 11 | 50 | 664 |
| P0 | cut_kind:synthetic | agentid | 49 | 49 | 1.000000 | [1.000000, 1.000000] | 296 | 60 | 946 |
| P0 | cut_kind:synthetic | path | 8037 | 8037 | 1.000000 | [1.000000, 1.000000] | 36952 | 13773 | 138382 |
| P0 | cut_kind:synthetic | sha | 1142 | 1142 | 1.000000 | [1.000000, 1.000000] | 3280 | 1955 | 15504 |
| P0 | cut_kind:synthetic | error | 106 | 106 | 1.000000 | [1.000000, 1.000000] | 198 | 1024 | 25274 |
| P0 | size_bucket:50-199 | agentid | 41 | 41 | 1.000000 | [1.000000, 1.000000] | 113 | 33 | 753 |
| P0 | size_bucket:50-199 | path | 4301 | 4301 | 1.000000 | [1.000000, 1.000000] | 20030 | 7452 | 77414 |
| P0 | size_bucket:50-199 | sha | 552 | 552 | 1.000000 | [1.000000, 1.000000] | 1591 | 1104 | 8312 |
| P0 | size_bucket:50-199 | error | 29 | 29 | 1.000000 | [1.000000, 1.000000] | 97 | 462 | 13250 |
| P0 | size_bucket:8-49 | agentid | 0 | 0 | n/a | n/a | 13 | 7 | 82 |
| P0 | size_bucket:8-49 | path | 3043 | 3043 | 1.000000 | [1.000000, 1.000000] | 5483 | 3784 | 28009 |
| P0 | size_bucket:8-49 | sha | 533 | 533 | 1.000000 | [1.000000, 1.000000] | 652 | 568 | 3714 |
| P0 | size_bucket:8-49 | error | 75 | 75 | 1.000000 | [1.000000, 1.000000] | 22 | 273 | 7820 |
| P0 | size_bucket:<8 | agentid | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P0 | size_bucket:<8 | path | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P0 | size_bucket:<8 | sha | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P0 | size_bucket:<8 | error | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P0 | size_bucket:>=200 | agentid | 9 | 9 | 1.000000 | [1.000000, 1.000000] | 298 | 22 | 132 |
| P0 | size_bucket:>=200 | path | 731 | 731 | 1.000000 | [1.000000, 1.000000] | 14058 | 2809 | 39235 |
| P0 | size_bucket:>=200 | sha | 62 | 62 | 1.000000 | [1.000000, 1.000000] | 1415 | 317 | 4267 |
| P0 | size_bucket:>=200 | error | 2 | 2 | 1.000000 | [1.000000, 1.000000] | 90 | 339 | 4868 |
| P1 | pooled | agentid | 50 | 24 | 0.480000 | [0.321429, 0.863712] | 424 | 62 | 967 |
| P1 | pooled | path | 8075 | 3626 | 0.449040 | [0.413840, 0.486447] | 39571 | 14045 | 144658 |
| P1 | pooled | sha | 1147 | 562 | 0.489974 | [0.438526, 0.545628] | 3658 | 1989 | 16293 |
| P1 | pooled | error | 106 | 62 | 0.584906 | [0.469020, 0.715913] | 209 | 1074 | 25938 |
| P1 | file_kind:main | agentid | 7 | 4 | 0.571429 | [0.000000, 1.000000] | 283 | 10 | 32 |
| P1 | file_kind:main | path | 807 | 617 | 0.764560 | [0.634786, 0.876491] | 6503 | 1537 | 19262 |
| P1 | file_kind:main | sha | 132 | 121 | 0.916667 | [0.813007, 0.982609] | 1038 | 205 | 2460 |
| P1 | file_kind:main | error | 12 | 11 | 0.916667 | [0.666667, 1.000000] | 39 | 178 | 3286 |
| P1 | file_kind:subagent | agentid | 43 | 20 | 0.465116 | [0.310324, 0.937500] | 141 | 52 | 935 |
| P1 | file_kind:subagent | path | 7268 | 3009 | 0.414007 | [0.378305, 0.449456] | 33068 | 12508 | 125396 |
| P1 | file_kind:subagent | sha | 1015 | 441 | 0.434483 | [0.379478, 0.492020] | 2620 | 1784 | 13833 |
| P1 | file_kind:subagent | error | 94 | 51 | 0.542553 | [0.422015, 0.680416] | 170 | 896 | 22652 |
| P1 | cut_kind:real | agentid | 1 | 1 | 1.000000 | [1.000000, 1.000000] | 128 | 2 | 21 |
| P1 | cut_kind:real | path | 38 | 8 | 0.210526 | [0.068946, 0.444540] | 2619 | 272 | 6276 |
| P1 | cut_kind:real | sha | 5 | 4 | 0.800000 | [0.750000, 1.000000] | 378 | 34 | 789 |
| P1 | cut_kind:real | error | 0 | 0 | n/a | n/a | 11 | 50 | 664 |
| P1 | cut_kind:synthetic | agentid | 49 | 23 | 0.469388 | [0.310345, 0.857143] | 296 | 60 | 946 |
| P1 | cut_kind:synthetic | path | 8037 | 3618 | 0.450168 | [0.414769, 0.486485] | 36952 | 13773 | 138382 |
| P1 | cut_kind:synthetic | sha | 1142 | 558 | 0.488616 | [0.438041, 0.546105] | 3280 | 1955 | 15504 |
| P1 | cut_kind:synthetic | error | 106 | 62 | 0.584906 | [0.470169, 0.707376] | 198 | 1024 | 25274 |
| P1 | size_bucket:50-199 | agentid | 41 | 19 | 0.463415 | [0.312500, 1.000000] | 113 | 33 | 753 |
| P1 | size_bucket:50-199 | path | 4301 | 1310 | 0.304580 | [0.268531, 0.341859] | 20030 | 7452 | 77414 |
| P1 | size_bucket:50-199 | sha | 552 | 169 | 0.306159 | [0.254083, 0.359934] | 1591 | 1104 | 8312 |
| P1 | size_bucket:50-199 | error | 29 | 16 | 0.551724 | [0.347826, 0.750000] | 97 | 462 | 13250 |
| P1 | size_bucket:8-49 | agentid | 0 | 0 | n/a | n/a | 13 | 7 | 82 |
| P1 | size_bucket:8-49 | path | 3043 | 2131 | 0.700296 | [0.659060, 0.740819] | 5483 | 3784 | 28009 |
| P1 | size_bucket:8-49 | sha | 533 | 375 | 0.703565 | [0.634614, 0.765328] | 652 | 568 | 3714 |
| P1 | size_bucket:8-49 | error | 75 | 46 | 0.613333 | [0.467334, 0.786894] | 22 | 273 | 7820 |
| P1 | size_bucket:<8 | agentid | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P1 | size_bucket:<8 | path | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P1 | size_bucket:<8 | sha | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P1 | size_bucket:<8 | error | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P1 | size_bucket:>=200 | agentid | 9 | 5 | 0.555556 | [0.000000, 1.000000] | 298 | 22 | 132 |
| P1 | size_bucket:>=200 | path | 731 | 185 | 0.253078 | [0.150757, 0.368345] | 14058 | 2809 | 39235 |
| P1 | size_bucket:>=200 | sha | 62 | 18 | 0.290323 | [0.156847, 0.439439] | 1415 | 317 | 4267 |
| P1 | size_bucket:>=200 | error | 2 | 0 | 0.000000 | [0.000000, 0.000000] | 90 | 339 | 4868 |
| P2 | pooled | agentid | 50 | 50 | 1.000000 | [1.000000, 1.000000] | 424 | 62 | 967 |
| P2 | pooled | path | 8075 | 7333 | 0.908111 | [0.886598, 0.926842] | 39571 | 14045 | 144658 |
| P2 | pooled | sha | 1147 | 1071 | 0.933740 | [0.906526, 0.956785] | 3658 | 1989 | 16293 |
| P2 | pooled | error | 106 | 106 | 1.000000 | [1.000000, 1.000000] | 209 | 1074 | 25938 |
| P2 | file_kind:main | agentid | 7 | 7 | 1.000000 | [1.000000, 1.000000] | 283 | 10 | 32 |
| P2 | file_kind:main | path | 807 | 779 | 0.965304 | [0.937883, 0.988184] | 6503 | 1537 | 19262 |
| P2 | file_kind:main | sha | 132 | 115 | 0.871212 | [0.787033, 0.953125] | 1038 | 205 | 2460 |
| P2 | file_kind:main | error | 12 | 12 | 1.000000 | [1.000000, 1.000000] | 39 | 178 | 3286 |
| P2 | file_kind:subagent | agentid | 43 | 43 | 1.000000 | [1.000000, 1.000000] | 141 | 52 | 935 |
| P2 | file_kind:subagent | path | 7268 | 6554 | 0.901761 | [0.877531, 0.922483] | 33068 | 12508 | 125396 |
| P2 | file_kind:subagent | sha | 1015 | 956 | 0.941872 | [0.914867, 0.966554] | 2620 | 1784 | 13833 |
| P2 | file_kind:subagent | error | 94 | 94 | 1.000000 | [1.000000, 1.000000] | 170 | 896 | 22652 |
| P2 | cut_kind:real | agentid | 1 | 1 | 1.000000 | [1.000000, 1.000000] | 128 | 2 | 21 |
| P2 | cut_kind:real | path | 38 | 29 | 0.763158 | [0.666667, 0.863636] | 2619 | 272 | 6276 |
| P2 | cut_kind:real | sha | 5 | 2 | 0.400000 | [0.250000, 1.000000] | 378 | 34 | 789 |
| P2 | cut_kind:real | error | 0 | 0 | n/a | n/a | 11 | 50 | 664 |
| P2 | cut_kind:synthetic | agentid | 49 | 49 | 1.000000 | [1.000000, 1.000000] | 296 | 60 | 946 |
| P2 | cut_kind:synthetic | path | 8037 | 7304 | 0.908797 | [0.887505, 0.927589] | 36952 | 13773 | 138382 |
| P2 | cut_kind:synthetic | sha | 1142 | 1069 | 0.936077 | [0.910976, 0.959002] | 3280 | 1955 | 15504 |
| P2 | cut_kind:synthetic | error | 106 | 106 | 1.000000 | [1.000000, 1.000000] | 198 | 1024 | 25274 |
| P2 | size_bucket:50-199 | agentid | 41 | 41 | 1.000000 | [1.000000, 1.000000] | 113 | 33 | 753 |
| P2 | size_bucket:50-199 | path | 4301 | 3790 | 0.881190 | [0.842756, 0.912582] | 20030 | 7452 | 77414 |
| P2 | size_bucket:50-199 | sha | 552 | 528 | 0.956522 | [0.921474, 0.983727] | 1591 | 1104 | 8312 |
| P2 | size_bucket:50-199 | error | 29 | 29 | 1.000000 | [1.000000, 1.000000] | 97 | 462 | 13250 |
| P2 | size_bucket:8-49 | agentid | 0 | 0 | n/a | n/a | 13 | 7 | 82 |
| P2 | size_bucket:8-49 | path | 3043 | 2938 | 0.965495 | [0.948248, 0.979676] | 5483 | 3784 | 28009 |
| P2 | size_bucket:8-49 | sha | 533 | 488 | 0.915572 | [0.872526, 0.952635] | 652 | 568 | 3714 |
| P2 | size_bucket:8-49 | error | 75 | 75 | 1.000000 | [1.000000, 1.000000] | 22 | 273 | 7820 |
| P2 | size_bucket:<8 | agentid | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P2 | size_bucket:<8 | path | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P2 | size_bucket:<8 | sha | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P2 | size_bucket:<8 | error | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P2 | size_bucket:>=200 | agentid | 9 | 9 | 1.000000 | [1.000000, 1.000000] | 298 | 22 | 132 |
| P2 | size_bucket:>=200 | path | 731 | 605 | 0.827633 | [0.742811, 0.897571] | 14058 | 2809 | 39235 |
| P2 | size_bucket:>=200 | sha | 62 | 55 | 0.887097 | [0.755535, 1.000000] | 1415 | 317 | 4267 |
| P2 | size_bucket:>=200 | error | 2 | 2 | 1.000000 | [1.000000, 1.000000] | 90 | 339 | 4868 |

## Verdict

| arm | verdict | reasons / insufficient cells |
|---|---|---|
| P1 | do not pursue | agentId lost; INSUFFICIENT DATA: main:error |
| P2 | do not pursue | pooled:path recall; pooled:sha recall; main:sha recall; subagent:path recall; subagent:sha recall; pooled:removed_share; INSUFFICIENT DATA: main:error |

Overall verdict: do not pursue

Bootstrap intervals are descriptive, resampling whole files with replacement.
A pass never authorises a live hook.
