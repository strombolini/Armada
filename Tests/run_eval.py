#!/usr/bin/env python3
"""Grounded evaluation of Armada's search.

Each case names a target file/folder (chosen first, by hand) and a natural-language description written without
telling the engine what the target is. The engine is run through the app's own CLI (--search --json) so the exact
shipped code is measured. Reports top-1 / top-3 / top-10 hit rates, MRR, latency and token cost, per style.

    python3 Tests/run_eval.py [--app PATH] [--set Tests/eval_set.json] [--fast|--balanced|--thorough] [--only substring] [--repeat N]
"""
import argparse, fnmatch, glob, json, os, re, statistics, subprocess, sys, time

HOME = os.path.expanduser("~")
DEFAULT_APP = "/Applications/Armada.app/Contents/MacOS/Armada"


def resolve_targets(case):
    """Return the set of absolute paths that count as a correct answer, and whether any exist."""
    out = set()
    for t in case.get("targets", []):
        out.add(t if t.startswith("/") else os.path.join(HOME, t))
    if g := case.get("targets_glob"):
        for p in glob.glob(os.path.join(HOME, g)):
            out.add(p)
    return out


def norm(p):
    # Finder writes narrow no-break spaces into "Screen Recording … at 7.05.24 PM.mov"; compare on plain spaces.
    return re.sub(r"[\u202f\u00a0\s]+", " ", p)


def matches(case, targets, path):
    if path in targets or norm(path) in {norm(t) for t in targets}:
        return True
    if case.get("same_name_ok"):
        names = {os.path.basename(norm(t)) for t in targets}
        if os.path.basename(norm(path)) in names:
            return True
    if rx := case.get("targets_regex"):
        rel = os.path.relpath(path, HOME)
        return re.search(rx, rel) is not None
    return False


def run_case(app, case, depth_flag):
    t = time.time()
    proc = subprocess.run([app, "--search", case["query"], "--json"] + ([depth_flag] if depth_flag else []),
                          capture_output=True, text=True, timeout=120)
    wall = time.time() - t
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"error": (proc.stderr or proc.stdout)[-300:], "wall": wall}
    data["wall"] = wall
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", default=DEFAULT_APP)
    ap.add_argument("--set", default=os.path.join(os.path.dirname(__file__), "eval_set.json"))
    ap.add_argument("--fast", action="store_const", const="--fast", dest="depth")
    ap.add_argument("--balanced", action="store_const", const="--balanced", dest="depth")
    ap.add_argument("--thorough", action="store_const", const="--thorough", dest="depth")
    ap.add_argument("--only", default=None, help="run only cases whose query contains this substring")
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--out", default=None, help="write per-case JSON results here")
    args = ap.parse_args()

    cases = json.load(open(args.set))
    if args.only:
        cases = [c for c in cases if args.only.lower() in c["query"].lower()]
    rows = []
    for case in cases:
        targets = {t for t in resolve_targets(case) if os.path.exists(t)} if "targets" in case else resolve_targets(case)
        if not targets and not case.get("targets_regex") and "calc" not in case:
            rows.append({**case, "skipped": "target missing on this Mac"})
            print(f"SKIP  (missing target) {case['query']!r}")
            continue
        for _ in range(args.repeat):
            res = run_case(args.app, case, args.depth)
            if "error" in res:
                rows.append({**case, "error": res["error"]})
                print(f"ERR   {case['query']!r}: {res['error']}")
                continue
            paths = [r["path"] for r in res["results"]]
            if "calc" in case:
                rank = 1 if res.get("calc") == case["calc"] else None
            else:
                rank = next((i + 1 for i, p in enumerate(paths) if matches(case, targets, p)), None)
            top = [os.path.relpath(p, HOME) for p in paths[:3]]
            row = {**case, "rank": rank, "ms": res["ms"], "requests": res["requests"], "tokens": res["tokens"], "top3": top,
                   "scores": [round(r["score"], 3) for r in res["results"][:3]]}
            rows.append(row)
            mark = "PASS" if rank == 1 else ("ok  " if rank and rank <= 3 else ("weak" if rank else "MISS"))
            print(f"{mark}  rank={rank if rank else '-':<3} {res['ms']:>5} ms {res['tokens']:>6} tok  {case['query']!r}")
            if rank != 1:
                for p, s in zip(top, row["scores"]):
                    print(f"          {s:5.2f}  {p}")
            sys.stdout.flush()

    scored = [r for r in rows if "rank" in r]
    if not scored:
        return
    n = len(scored)
    top1 = sum(1 for r in scored if r["rank"] == 1)
    top3 = sum(1 for r in scored if r["rank"] and r["rank"] <= 3)
    top10 = sum(1 for r in scored if r["rank"] and r["rank"] <= 10)
    mrr = sum(1 / r["rank"] for r in scored if r["rank"]) / n
    lat = [r["ms"] for r in scored]
    toks = [r["tokens"] for r in scored]
    print("\n==== SUMMARY ====")
    print(f"cases: {n}   top-1: {top1}/{n} ({top1/n:.0%})   top-3: {top3}/{n} ({top3/n:.0%})   top-10: {top10}/{n} ({top10/n:.0%})   MRR: {mrr:.3f}")
    print(f"latency: median {statistics.median(lat):.0f} ms, mean {statistics.mean(lat):.0f} ms, p90 {sorted(lat)[int(0.9*(n-1))]:.0f} ms, max {max(lat)} ms")
    print(f"tokens/search: median {statistics.median(toks):.0f}, mean {statistics.mean(toks):.0f}   requests/search: mean {statistics.mean(r['requests'] for r in scored):.1f}")
    print("\nby style:")
    for style in sorted({r["style"] for r in scored}):
        rs = [r for r in scored if r["style"] == style]
        t1 = sum(1 for r in rs if r["rank"] == 1); t3 = sum(1 for r in rs if r["rank"] and r["rank"] <= 3)
        print(f"  {style:<13} n={len(rs):<3} top-1 {t1}/{len(rs)}   top-3 {t3}/{len(rs)}")
    misses = [r for r in scored if r["rank"] != 1]
    if misses:
        print("\nnot top-1:")
        for r in misses:
            print(f"  rank={r['rank']}  {r['query']!r}  -> {r['top3'][:1]}")
    if args.out:
        json.dump(rows, open(args.out, "w"), indent=1)


if __name__ == "__main__":
    main()
