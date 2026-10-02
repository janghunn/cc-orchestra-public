# Tool-result retention replay — aggregate evidence

Run command: python3 eval/compaction-replay/replay.py --projects "$CC_ORCH_CLAUDE_PROJECTS" --out "$REPLAY_OUT" --seed 20261002 --bootstrap 2000 --p3 local --p3-model "$REPLAY_MODEL" --p3-server "$REPLAY_SERVER" --note "$REPLAY_NOTE" --criteria-commit 34380fafac8d5d7c2350c3f3fdbb2a8dfc4fb257
Criteria commit: 34380fafac8d5d7c2350c3f3fdbb2a8dfc4fb257
P3 status: P3 skipped: model file missing
Runtime seconds: 95.808
Peak RSS MiB: 64.922
Source hash check: 20/20 unchanged

## Corpus and normalization

| count | value |
|---|---:|
| copied_records | 11 |
| dup_conflicts | 25 |
| dup_records_in_file | 45 |
| excluded_records | 1938 |
| files_discovered | 442 |
| files_evaluated | 377 |
| files_skipped_copy | 1 |
| main_files | 95 |
| nontext_result_blocks | 849 |
| parse_errors | 0 |
| records | 191181 |
| subagent_files | 346 |

## Retention by policy and stratum

Counts pool file/cut units; files are counted once within each cell.

| arm | stratum | files | cuts | bytes total | bytes removed | removed share | 95% CI | lost agentIds |
|---|---|---:|---:|---:|---:|---:|---|---:|
| P0 | pooled | 377 | 1136 | 153960562 | 0 | 0.000000 | [0.000000, 0.000000] | 0 |
| P0 | file_kind:main | 49 | 150 | 17040612 | 0 | 0.000000 | [0.000000, 0.000000] | 0 |
| P0 | file_kind:subagent | 328 | 986 | 136919950 | 0 | 0.000000 | [0.000000, 0.000000] | 0 |
| P0 | cut_kind:real | 11 | 14 | 6056858 | 0 | 0.000000 | [0.000000, 0.000000] | 0 |
| P0 | cut_kind:synthetic | 374 | 1122 | 147903704 | 0 | 0.000000 | [0.000000, 0.000000] | 0 |
| P0 | size_bucket:50-199 | 179 | 537 | 86659979 | 0 | 0.000000 | [0.000000, 0.000000] | 0 |
| P0 | size_bucket:8-49 | 161 | 483 | 30175779 | 0 | 0.000000 | [0.000000, 0.000000] | 0 |
| P0 | size_bucket:<8 | 3 | 3 | 0 | 0 | n/a | n/a | 0 |
| P0 | size_bucket:>=200 | 34 | 113 | 37124804 | 0 | 0.000000 | [0.000000, 0.000000] | 0 |
| P1 | pooled | 377 | 1136 | 153960562 | 119692128 | 0.777421 | [0.750287, 0.801224] | 26 |
| P1 | file_kind:main | 49 | 150 | 17040612 | 11192697 | 0.656825 | [0.471087, 0.776647] | 3 |
| P1 | file_kind:subagent | 328 | 986 | 136919950 | 108499431 | 0.792430 | [0.769511, 0.813243] | 23 |
| P1 | cut_kind:real | 11 | 14 | 6056858 | 5959061 | 0.983854 | [0.976018, 0.990007] | 0 |
| P1 | cut_kind:synthetic | 374 | 1122 | 147903704 | 113733067 | 0.768967 | [0.743984, 0.791769] | 26 |
| P1 | size_bucket:50-199 | 179 | 537 | 86659979 | 72296019 | 0.834249 | [0.818889, 0.848019] | 22 |
| P1 | size_bucket:8-49 | 161 | 483 | 30175779 | 11832234 | 0.392110 | [0.352747, 0.429851] | 0 |
| P1 | size_bucket:<8 | 3 | 3 | 0 | 0 | n/a | n/a | 0 |
| P1 | size_bucket:>=200 | 34 | 113 | 37124804 | 35563875 | 0.957955 | [0.949771, 0.965120] | 4 |
| P2 | pooled | 377 | 1136 | 153960562 | 45636146 | 0.296415 | [0.276280, 0.315598] | 0 |
| P2 | file_kind:main | 49 | 150 | 17040612 | 3908562 | 0.229367 | [0.165180, 0.286170] | 0 |
| P2 | file_kind:subagent | 328 | 986 | 136919950 | 41727584 | 0.304759 | [0.283265, 0.325379] | 0 |
| P2 | cut_kind:real | 11 | 14 | 6056858 | 1925646 | 0.317928 | [0.274133, 0.373097] | 0 |
| P2 | cut_kind:synthetic | 374 | 1122 | 147903704 | 43710500 | 0.295534 | [0.274562, 0.316246] | 0 |
| P2 | size_bucket:50-199 | 179 | 537 | 86659979 | 29190436 | 0.336839 | [0.306947, 0.366736] | 0 |
| P2 | size_bucket:8-49 | 161 | 483 | 30175779 | 4453681 | 0.147591 | [0.130240, 0.165004] | 0 |
| P2 | size_bucket:<8 | 3 | 3 | 0 | 0 | n/a | n/a | 0 |
| P2 | size_bucket:>=200 | 34 | 113 | 37124804 | 11992029 | 0.323019 | [0.290012, 0.352239] | 0 |

| arm | stratum | class | needed | retained | recall | 95% CI | rederivable | resurfaced | not_used |
|---|---|---|---:|---:|---:|---|---:|---:|---:|
| P0 | pooled | agentid | 50 | 50 | 1.000000 | [1.000000, 1.000000] | 424 | 61 | 968 |
| P0 | pooled | path | 8052 | 8052 | 1.000000 | [1.000000, 1.000000] | 39700 | 14027 | 144859 |
| P0 | pooled | sha | 1149 | 1149 | 1.000000 | [1.000000, 1.000000] | 3712 | 1982 | 16387 |
| P0 | pooled | error | 106 | 106 | 1.000000 | [1.000000, 1.000000] | 210 | 1075 | 26005 |
| P0 | file_kind:main | agentid | 7 | 7 | 1.000000 | [1.000000, 1.000000] | 283 | 10 | 32 |
| P0 | file_kind:main | path | 807 | 807 | 1.000000 | [1.000000, 1.000000] | 6503 | 1537 | 19262 |
| P0 | file_kind:main | sha | 132 | 132 | 1.000000 | [1.000000, 1.000000] | 1038 | 205 | 2460 |
| P0 | file_kind:main | error | 12 | 12 | 1.000000 | [1.000000, 1.000000] | 39 | 178 | 3286 |
| P0 | file_kind:subagent | agentid | 43 | 43 | 1.000000 | [1.000000, 1.000000] | 141 | 51 | 936 |
| P0 | file_kind:subagent | path | 7245 | 7245 | 1.000000 | [1.000000, 1.000000] | 33197 | 12490 | 125597 |
| P0 | file_kind:subagent | sha | 1017 | 1017 | 1.000000 | [1.000000, 1.000000] | 2674 | 1777 | 13927 |
| P0 | file_kind:subagent | error | 94 | 94 | 1.000000 | [1.000000, 1.000000] | 171 | 897 | 22719 |
| P0 | cut_kind:real | agentid | 1 | 1 | 1.000000 | [1.000000, 1.000000] | 128 | 2 | 21 |
| P0 | cut_kind:real | path | 38 | 38 | 1.000000 | [1.000000, 1.000000] | 2619 | 272 | 6276 |
| P0 | cut_kind:real | sha | 5 | 5 | 1.000000 | [1.000000, 1.000000] | 378 | 34 | 789 |
| P0 | cut_kind:real | error | 0 | 0 | n/a | n/a | 11 | 50 | 664 |
| P0 | cut_kind:synthetic | agentid | 49 | 49 | 1.000000 | [1.000000, 1.000000] | 296 | 59 | 947 |
| P0 | cut_kind:synthetic | path | 8014 | 8014 | 1.000000 | [1.000000, 1.000000] | 37081 | 13755 | 138583 |
| P0 | cut_kind:synthetic | sha | 1144 | 1144 | 1.000000 | [1.000000, 1.000000] | 3334 | 1948 | 15598 |
| P0 | cut_kind:synthetic | error | 106 | 106 | 1.000000 | [1.000000, 1.000000] | 199 | 1025 | 25341 |
| P0 | size_bucket:50-199 | agentid | 41 | 41 | 1.000000 | [1.000000, 1.000000] | 113 | 33 | 754 |
| P0 | size_bucket:50-199 | path | 4317 | 4317 | 1.000000 | [1.000000, 1.000000] | 20317 | 7501 | 78250 |
| P0 | size_bucket:50-199 | sha | 591 | 591 | 1.000000 | [1.000000, 1.000000] | 1694 | 1129 | 8474 |
| P0 | size_bucket:50-199 | error | 30 | 30 | 1.000000 | [1.000000, 1.000000] | 100 | 464 | 13403 |
| P0 | size_bucket:8-49 | agentid | 0 | 0 | n/a | n/a | 13 | 6 | 82 |
| P0 | size_bucket:8-49 | path | 3004 | 3004 | 1.000000 | [1.000000, 1.000000] | 5325 | 3717 | 27374 |
| P0 | size_bucket:8-49 | sha | 496 | 496 | 1.000000 | [1.000000, 1.000000] | 603 | 536 | 3646 |
| P0 | size_bucket:8-49 | error | 74 | 74 | 1.000000 | [1.000000, 1.000000] | 20 | 272 | 7734 |
| P0 | size_bucket:<8 | agentid | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P0 | size_bucket:<8 | path | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P0 | size_bucket:<8 | sha | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P0 | size_bucket:<8 | error | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P0 | size_bucket:>=200 | agentid | 9 | 9 | 1.000000 | [1.000000, 1.000000] | 298 | 22 | 132 |
| P0 | size_bucket:>=200 | path | 731 | 731 | 1.000000 | [1.000000, 1.000000] | 14058 | 2809 | 39235 |
| P0 | size_bucket:>=200 | sha | 62 | 62 | 1.000000 | [1.000000, 1.000000] | 1415 | 317 | 4267 |
| P0 | size_bucket:>=200 | error | 2 | 2 | 1.000000 | [1.000000, 1.000000] | 90 | 339 | 4868 |
| P1 | pooled | agentid | 50 | 24 | 0.480000 | [0.319552, 0.863636] | 424 | 61 | 968 |
| P1 | pooled | path | 8052 | 3593 | 0.446225 | [0.412582, 0.483434] | 39700 | 14027 | 144859 |
| P1 | pooled | sha | 1149 | 562 | 0.489121 | [0.437078, 0.544016] | 3712 | 1982 | 16387 |
| P1 | pooled | error | 106 | 62 | 0.584906 | [0.467350, 0.709320] | 210 | 1075 | 26005 |
| P1 | file_kind:main | agentid | 7 | 4 | 0.571429 | [0.000000, 1.000000] | 283 | 10 | 32 |
| P1 | file_kind:main | path | 807 | 617 | 0.764560 | [0.630903, 0.879014] | 6503 | 1537 | 19262 |
| P1 | file_kind:main | sha | 132 | 121 | 0.916667 | [0.812488, 0.983607] | 1038 | 205 | 2460 |
| P1 | file_kind:main | error | 12 | 11 | 0.916667 | [0.666667, 1.000000] | 39 | 178 | 3286 |
| P1 | file_kind:subagent | agentid | 43 | 20 | 0.465116 | [0.310324, 0.937500] | 141 | 51 | 936 |
| P1 | file_kind:subagent | path | 7245 | 2976 | 0.410766 | [0.374855, 0.446486] | 33197 | 12490 | 125597 |
| P1 | file_kind:subagent | sha | 1017 | 441 | 0.433628 | [0.378720, 0.490993] | 2674 | 1777 | 13927 |
| P1 | file_kind:subagent | error | 94 | 51 | 0.542553 | [0.422015, 0.680416] | 171 | 897 | 22719 |
| P1 | cut_kind:real | agentid | 1 | 1 | 1.000000 | [1.000000, 1.000000] | 128 | 2 | 21 |
| P1 | cut_kind:real | path | 38 | 8 | 0.210526 | [0.065565, 0.468750] | 2619 | 272 | 6276 |
| P1 | cut_kind:real | sha | 5 | 4 | 0.800000 | [0.750000, 1.000000] | 378 | 34 | 789 |
| P1 | cut_kind:real | error | 0 | 0 | n/a | n/a | 11 | 50 | 664 |
| P1 | cut_kind:synthetic | agentid | 49 | 23 | 0.469388 | [0.310345, 0.857143] | 296 | 59 | 947 |
| P1 | cut_kind:synthetic | path | 8014 | 3585 | 0.447342 | [0.411921, 0.483783] | 37081 | 13755 | 138583 |
| P1 | cut_kind:synthetic | sha | 1144 | 558 | 0.487762 | [0.436787, 0.545374] | 3334 | 1948 | 15598 |
| P1 | cut_kind:synthetic | error | 106 | 62 | 0.584906 | [0.470169, 0.707376] | 199 | 1025 | 25341 |
| P1 | size_bucket:50-199 | agentid | 41 | 19 | 0.463415 | [0.310345, 1.000000] | 113 | 33 | 754 |
| P1 | size_bucket:50-199 | path | 4317 | 1311 | 0.303683 | [0.267659, 0.338853] | 20317 | 7501 | 78250 |
| P1 | size_bucket:50-199 | sha | 591 | 205 | 0.346870 | [0.267856, 0.439088] | 1694 | 1129 | 8474 |
| P1 | size_bucket:50-199 | error | 30 | 17 | 0.566667 | [0.371402, 0.760000] | 100 | 464 | 13403 |
| P1 | size_bucket:8-49 | agentid | 0 | 0 | n/a | n/a | 13 | 6 | 82 |
| P1 | size_bucket:8-49 | path | 3004 | 2097 | 0.698069 | [0.655364, 0.740346] | 5325 | 3717 | 27374 |
| P1 | size_bucket:8-49 | sha | 496 | 339 | 0.683468 | [0.621715, 0.743275] | 603 | 536 | 3646 |
| P1 | size_bucket:8-49 | error | 74 | 45 | 0.608108 | [0.454519, 0.791667] | 20 | 272 | 7734 |
| P1 | size_bucket:<8 | agentid | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P1 | size_bucket:<8 | path | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P1 | size_bucket:<8 | sha | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P1 | size_bucket:<8 | error | 0 | 0 | n/a | n/a | 0 | 0 | 0 |
| P1 | size_bucket:>=200 | agentid | 9 | 5 | 0.555556 | [0.000000, 1.000000] | 298 | 22 | 132 |
| P1 | size_bucket:>=200 | path | 731 | 185 | 0.253078 | [0.150757, 0.368345] | 14058 | 2809 | 39235 |
| P1 | size_bucket:>=200 | sha | 62 | 18 | 0.290323 | [0.156847, 0.439439] | 1415 | 317 | 4267 |
| P1 | size_bucket:>=200 | error | 2 | 0 | 0.000000 | [0.000000, 0.000000] | 90 | 339 | 4868 |
| P2 | pooled | agentid | 50 | 50 | 1.000000 | [1.000000, 1.000000] | 424 | 61 | 968 |
| P2 | pooled | path | 8052 | 7315 | 0.908470 | [0.885677, 0.927706] | 39700 | 14027 | 144859 |
| P2 | pooled | sha | 1149 | 1074 | 0.934726 | [0.907357, 0.957877] | 3712 | 1982 | 16387 |
| P2 | pooled | error | 106 | 106 | 1.000000 | [1.000000, 1.000000] | 210 | 1075 | 26005 |
| P2 | file_kind:main | agentid | 7 | 7 | 1.000000 | [1.000000, 1.000000] | 283 | 10 | 32 |
| P2 | file_kind:main | path | 807 | 779 | 0.965304 | [0.935102, 0.989078] | 6503 | 1537 | 19262 |
| P2 | file_kind:main | sha | 132 | 115 | 0.871212 | [0.787397, 0.952390] | 1038 | 205 | 2460 |
| P2 | file_kind:main | error | 12 | 12 | 1.000000 | [1.000000, 1.000000] | 39 | 178 | 3286 |
| P2 | file_kind:subagent | agentid | 43 | 43 | 1.000000 | [1.000000, 1.000000] | 141 | 51 | 936 |
| P2 | file_kind:subagent | path | 7245 | 6536 | 0.902139 | [0.878191, 0.922494] | 33197 | 12490 | 125597 |
| P2 | file_kind:subagent | sha | 1017 | 959 | 0.942970 | [0.916132, 0.967183] | 2674 | 1777 | 13927 |
| P2 | file_kind:subagent | error | 94 | 94 | 1.000000 | [1.000000, 1.000000] | 171 | 897 | 22719 |
| P2 | cut_kind:real | agentid | 1 | 1 | 1.000000 | [1.000000, 1.000000] | 128 | 2 | 21 |
| P2 | cut_kind:real | path | 38 | 29 | 0.763158 | [0.666667, 0.863636] | 2619 | 272 | 6276 |
| P2 | cut_kind:real | sha | 5 | 2 | 0.400000 | [0.250000, 1.000000] | 378 | 34 | 789 |
| P2 | cut_kind:real | error | 0 | 0 | n/a | n/a | 11 | 50 | 664 |
| P2 | cut_kind:synthetic | agentid | 49 | 49 | 1.000000 | [1.000000, 1.000000] | 296 | 59 | 947 |
| P2 | cut_kind:synthetic | path | 8014 | 7286 | 0.909159 | [0.887706, 0.927901] | 37081 | 13755 | 138583 |
| P2 | cut_kind:synthetic | sha | 1144 | 1072 | 0.937063 | [0.911762, 0.959782] | 3334 | 1948 | 15598 |
| P2 | cut_kind:synthetic | error | 106 | 106 | 1.000000 | [1.000000, 1.000000] | 199 | 1025 | 25341 |
| P2 | size_bucket:50-199 | agentid | 41 | 41 | 1.000000 | [1.000000, 1.000000] | 113 | 33 | 754 |
| P2 | size_bucket:50-199 | path | 4317 | 3798 | 0.879778 | [0.842307, 0.910695] | 20317 | 7501 | 78250 |
| P2 | size_bucket:50-199 | sha | 591 | 564 | 0.954315 | [0.921272, 0.980253] | 1694 | 1129 | 8474 |
| P2 | size_bucket:50-199 | error | 30 | 30 | 1.000000 | [1.000000, 1.000000] | 100 | 464 | 13403 |
| P2 | size_bucket:8-49 | agentid | 0 | 0 | n/a | n/a | 13 | 6 | 82 |
| P2 | size_bucket:8-49 | path | 3004 | 2912 | 0.969374 | [0.953727, 0.982354] | 5325 | 3717 | 27374 |
| P2 | size_bucket:8-49 | sha | 496 | 455 | 0.917339 | [0.871681, 0.957450] | 603 | 536 | 3646 |
| P2 | size_bucket:8-49 | error | 74 | 74 | 1.000000 | [1.000000, 1.000000] | 20 | 272 | 7734 |
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
