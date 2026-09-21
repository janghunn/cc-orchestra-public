#!/usr/bin/env python3
"""Run private, cached lint and synthetic scan requests with explicit live consent."""

import argparse
from dataclasses import asdict
import json
import math
import os
from pathlib import Path
import time

import adapter
from common import (OutOfTreeError, assert_out_of_tree, read_jsonl, sha256_text,
                    state_dir, write_jsonl)
from secrets import scan_record


INJECTION_SET = Path(__file__).parent / "injection-set.jsonl"


def cache_key(task, mode, text):
    return sha256_text(adapter.ADAPTER_VERSION + "\0" + task + "\0" + mode + "\0" + text)


def requests_for(records, injections, task, limit=None):
    requests = []
    if task in ("lint", "both"):
        requests += [{"id": row["id"], "task": "lint", "text": row["brief_text"]}
                     for row in records]
    if task in ("scan", "both"):
        requests += [{"id": row["id"], "task": "scan", "text": row["text"]}
                     for row in injections]
    return requests if limit is None else requests[:limit]


def execute(requests, *, mode, cache, out, rpm=60, dry_run=False):
    if not 0 < rpm <= 300:
        raise ValueError("rpm must be in the range 1..300")
    cache = assert_out_of_tree(cache)
    assert_out_of_tree(out)
    # Validate every cache artifact before making any request or creating a file.
    paths = [assert_out_of_tree(cache / (cache_key(r["task"], mode, r["text"]) + ".json"))
             for r in requests]
    if Path(out).resolve() in paths:
        raise ValueError("responses and cache entries must have distinct paths")
    stats = {"requests": len(requests), "adapter_calls": 0, "cache_hits": 0,
             "skipped_secret_shaped": 0, "estimated_input_tokens": 0,
             "estimated_input_cost_usd": 0.0}
    responses, next_call = [], None
    for request, path in zip(requests, paths):
        text = request["text"]
        response = {"id": request["id"], "task": request["task"], "mode": mode,
                    "adapter_version": adapter.ADAPTER_VERSION,
                    "input_sha256": sha256_text(text)}
        # Also applied in mock mode so the gate is exercised without live access.
        skip, number = scan_record(text)
        if skip:
            stats["skipped_secret_shaped"] += 1
            response.update(status="skipped_secret_shaped", first_hit_line_no=number)
        else:
            stats["estimated_input_tokens"] += len(text) / 4
            if dry_run:
                continue
            if path.is_file():
                result = json.loads(path.read_text(encoding="utf-8"))
                stats["cache_hits"] += 1
            else:
                if mode == "live":
                    now = time.monotonic()
                    if next_call is not None and now < next_call:
                        time.sleep(next_call - now)
                    next_call = time.monotonic() + 60.0 / rpm
                call = adapter.lint_brief if request["task"] == "lint" else adapter.scan_text
                result = asdict(call(text, mode=mode))
                # Validate before persisting an adapter response.
                validate_result(result)
                assert_out_of_tree(path)
                path.parent.mkdir(parents=True, exist_ok=True)
                temporary = assert_out_of_tree(path.with_suffix(".pending"))
                temporary.write_text(json.dumps(result, sort_keys=True), encoding="utf-8")
                temporary.replace(path)
                stats["adapter_calls"] += 1
            validate_result(result)
            response.update(status="ok", **result)
        responses.append(response)
    stats["estimated_input_cost_usd"] = stats["estimated_input_tokens"] * 0.042 / 1_000_000
    stats["sendable_requests"] = stats["requests"] - stats["skipped_secret_shaped"]
    if not dry_run:
        write_jsonl(out, responses)
    return stats


def validate_result(result):
    value = result["score"]
    if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or not 0 <= value <= 1:
        raise ValueError("adapter score must be finite and in [0, 1]")
    if not isinstance(result["flagged"], bool) or not isinstance(result["findings"], list):
        raise ValueError("invalid adapter result")
    if "raw" not in result:
        raise ValueError("adapter result lacks raw output")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    directory = state_dir() / "jev-eval"
    parser.add_argument("--mode", choices=("mock", "live"), default="mock")
    parser.add_argument("--task", choices=("lint", "scan", "both"), default="both")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--rpm", type=int, default=60)
    parser.add_argument("--dataset", type=Path, default=directory / "dataset.jsonl")
    parser.add_argument("--cache", type=Path, default=directory / "cache")
    parser.add_argument("--out", type=Path, default=directory / "responses.jsonl")
    parser.add_argument("--limit", type=int)
    args = parser.parse_args(argv)
    if args.mode == "live" and not args.live:
        parser.exit(2, "run_eval.py: live mode requires --live\n")
    if args.live and not os.environ.get("TYPESAFE_API_KEY"):
        parser.exit(2, "run_eval.py: --live requires TYPESAFE_API_KEY\n")
    try:
        assert_out_of_tree(args.cache)
        assert_out_of_tree(args.out)
        if args.limit is not None and args.limit < 0:
            raise ValueError("limit must be nonnegative")
        if args.out.resolve() == args.dataset.resolve():
            raise ValueError("responses must not overwrite the dataset")
        records = read_jsonl(args.dataset) if args.task in ("lint", "both") else []
        injections = read_jsonl(INJECTION_SET) if args.task in ("scan", "both") else []
        requests = requests_for(records, injections, args.task, args.limit)
        stats = execute(requests, mode=args.mode, cache=args.cache, out=args.out,
                        rpm=args.rpm, dry_run=args.dry_run)
        print(json.dumps(stats, sort_keys=True))
        if args.dry_run:
            print(f"dry-run: requests={stats['requests']} sendable={stats['sendable_requests']} "
                  f"estimated_input_cost=${stats['estimated_input_cost_usd']:.8f} "
                  "(len(text)/4 tokens, $0.042 per million input tokens)")
    except adapter.AdapterNotReady as error:
        parser.exit(2, f"run_eval.py: {error}\n")
    except (OSError, ValueError, KeyError, TypeError) as error:
        message = str(error) if isinstance(error, OutOfTreeError) else "invalid run input or output"
        parser.exit(2, f"run_eval.py: {message}\n")


if __name__ == "__main__":
    main()
