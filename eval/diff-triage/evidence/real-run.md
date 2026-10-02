command: python3 run_eval.py --seed 20260921 --s3 auto (path arguments elided)
criteria.md commit: 4174cde186411891da8c83b549db31a3ea6c5f43
primary: usable diffs = 12
primary S0 mean metrics: {"first_rank": 2.5155, "normalized_first_rank": 0.3029342261904762, "recall@1": 0.14789444444444444, "recall@3": 0.4397555555555555, "recall@k20": 0.2626111111111111}
primary S1 mean metrics: {"first_rank": 1.4166666666666667, "normalized_first_rank": 0.09444444444444444, "recall@1": 0.33888888888888885, "recall@3": 0.8055555555555555, "recall@k20": 0.5111111111111111}
primary S2 mean metrics: {"first_rank": 1.4166666666666667, "normalized_first_rank": 0.11666666666666665, "recall@1": 0.32222222222222224, "recall@3": 0.6361111111111111, "recall@k20": 0.49444444444444446}
primary S2 - S1: {"high": 0.20555555555555557, "low": -0.1722222222222222, "mean": -0.016666666666666663}
primary S2 - S0: {"high": 0.4090284722222222, "low": 0.062136805555555556, "mean": 0.23183333333333334}
high-only: usable diffs = 3
high-only S0 mean metrics: {"first_rank": 2.3713333333333337, "normalized_first_rank": 0.2950888888888889, "recall@1": 0.15733333333333333, "recall@3": 0.4657222222222222, "recall@k20": 0.24344444444444444}
high-only S1 mean metrics: {"first_rank": 1.6666666666666667, "normalized_first_rank": 0.16666666666666666, "recall@1": 0.1111111111111111, "recall@3": 0.8333333333333334, "recall@k20": 0.38888888888888884}
high-only S2 mean metrics: {"first_rank": 2.0, "normalized_first_rank": 0.27777777777777773, "recall@1": 0.1111111111111111, "recall@3": 0.4444444444444444, "recall@k20": 0.27777777777777773}
high-only: INSUFFICIENT DATA
sensitivity: usable diffs = 16
sensitivity S0 mean metrics: {"first_rank": 2.953625, "normalized_first_rank": 0.2722727220695971, "recall@1": 0.11161354166666666, "recall@3": 0.32978229166666667, "recall@k20": 0.23787395833333333}
sensitivity S1 mean metrics: {"first_rank": 1.8125, "normalized_first_rank": 0.11982600732600733, "recall@1": 0.22395833333333334, "recall@3": 0.5458333333333333, "recall@k20": 0.41875}
sensitivity S2 mean metrics: {"first_rank": 2.3125, "normalized_first_rank": 0.15977564102564104, "recall@1": 0.24479166666666666, "recall@3": 0.509375, "recall@k20": 0.45}
sensitivity S2 - S1: {"high": 0.140625, "low": -0.046875, "mean": 0.031249999999999997}
sensitivity S2 - S0: {"high": 0.36459986979166653, "low": 0.06726059895833333, "mean": 0.21212604166666668}
series J: usable diffs = 5
series J S0 mean metrics: {"first_rank": 2.682, "normalized_first_rank": 0.2947783333333333, "recall@1": 0.13389333333333334, "recall@3": 0.39886666666666665, "recall@k20": 0.24453333333333332}
series J S1 mean metrics: {"first_rank": 1.4, "normalized_first_rank": 0.10666666666666666, "recall@1": 0.30666666666666664, "recall@3": 0.8133333333333332, "recall@k20": 0.48}
series J S2 mean metrics: {"first_rank": 1.6, "normalized_first_rank": 0.17333333333333334, "recall@1": 0.30666666666666664, "recall@3": 0.5133333333333333, "recall@k20": 0.4133333333333333}
series J: INSUFFICIENT DATA
series C: usable diffs = 5
series C S0 mean metrics: {"first_rank": 2.2622, "normalized_first_rank": 0.2839738095238095, "recall@1": 0.15725333333333333, "recall@3": 0.47128, "recall@k20": 0.26306666666666667}
series C S1 mean metrics: {"first_rank": 1.0, "normalized_first_rank": 0.0, "recall@1": 0.44000000000000006, "recall@3": 0.9199999999999999, "recall@k20": 0.6133333333333333}
series C S2 mean metrics: {"first_rank": 1.2, "normalized_first_rank": 0.06666666666666667, "recall@1": 0.4, "recall@3": 0.7466666666666667, "recall@k20": 0.5066666666666666}
series C: INSUFFICIENT DATA
series S: usable diffs = 2
series S S0 mean metrics: {"first_rank": 2.7325, "normalized_first_rank": 0.37072499999999997, "recall@1": 0.1595, "recall@3": 0.4631666666666666, "recall@k20": 0.30666666666666664}
series S S1 mean metrics: {"first_rank": 2.5, "normalized_first_rank": 0.3, "recall@1": 0.16666666666666666, "recall@3": 0.5, "recall@k20": 0.3333333333333333}
series S S2 mean metrics: {"first_rank": 1.5, "normalized_first_rank": 0.1, "recall@1": 0.16666666666666666, "recall@3": 0.6666666666666666, "recall@k20": 0.6666666666666666}
series S: INSUFFICIENT DATA
verdict: inconclusive (primary thresholds not resolved)
S3 skipped: configured GGUF absent; llama-server unavailable; GPU with at least 12288 MiB free unavailable
fingerprint before: {"corpus": {"0": "2c874529d069e78c719ebf8174d6c0caddf84a58301eb0869e4f800255e617e2", "1": "7f5935c9d18561e746ef67d000d14928c02586c98f9a16d6a0f138047cc812a0"}, "head": "2e59193f87c52d010797fab3d5eba2febbaa85f2", "refs": "23c92345e944432e7605afa832d957c3666a06d4d62018300bb771f17ede2e0a", "status": "8e21efe38ccebffaede7ddce52f0a28e1e29f5a634d06aa1b81d7cdecc189913"}
fingerprint after: {"corpus": {"0": "2c874529d069e78c719ebf8174d6c0caddf84a58301eb0869e4f800255e617e2", "1": "7f5935c9d18561e746ef67d000d14928c02586c98f9a16d6a0f138047cc812a0"}, "head": "2e59193f87c52d010797fab3d5eba2febbaa85f2", "refs": "23c92345e944432e7605afa832d957c3666a06d4d62018300bb771f17ede2e0a", "status": "8e21efe38ccebffaede7ddce52f0a28e1e29f5a634d06aa1b81d7cdecc189913"}
unchanged: yes
runtime seconds: 1.165860
peak RSS SELF KiB: 31036
peak RSS CHILDREN KiB: 31036
