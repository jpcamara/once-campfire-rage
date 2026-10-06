#!/usr/bin/env python3
"""Medians (and ranges) over every run-*/APP-*.json under a results directory.

    script/bench_summary.py RESULTS_DIR
"""
import glob, json, statistics, sys

root = sys.argv[1]
apps = {}
for path in sorted(glob.glob(f"{root}/run-*/*.json")):
    data = json.load(open(path))
    apps.setdefault(data["app"], []).append(data)

routes = ["room_show", "messages_page", "sidebar", "search", "post_message", "avatar", "static_css", "up"]
for conc in (1, 16, 64):
    print(f"\n## HTTP req/s at {conc} clients (median [min-max] of {max(len(v) for v in apps.values())} runs)\n")
    print("| app | " + " | ".join(routes) + " |")
    print("|---" * (len(routes) + 1) + "|")
    for app, runs in apps.items():
        cells = []
        for route in routes:
            values = [r["rps"] for run in runs for r in run["http"] if r["route"] == route and r["conc"] == conc]
            errors = sum(r["errors"] for run in runs for r in run["http"] if r["route"] == route and r["conc"] == conc)
            cells.append(f"{statistics.median(values):.0f} [{min(values):.0f}-{max(values):.0f}]" + (f" err {errors}" if errors else "") if values else "-")
        print(f"| {app} | " + " | ".join(cells) + " |")

print("\n## Cable fan-out (median of runs)\n")
print("| app | clients | ready | delivery p50 ms | p99 ms | delivered msg/s | complete |")
print("|---|---|---|---|---|---|---|")
for app, runs in apps.items():
    for clients in (100, 500, 1000):
        rows = [c for run in runs for c in run["cable"] if c["clients"] == clients]
        if not rows:
            continue
        med = lambda f: statistics.median(f(c) for c in rows)
        print(f"| {app} | {clients} | {med(lambda c: c['ready']):.0f} | {med(lambda c: c['latency']['all_clients'].get('p50_ms', 0)):.1f} | "
              f"{med(lambda c: c['latency']['all_clients'].get('p99_ms', 0)):.1f} | {med(lambda c: c['throughput']['delivered_msgs_per_sec']):.1f} | "
              f"{sum(c['throughput']['complete'] for c in rows)}/{sum(c['throughput']['posted'] for c in rows)} |")

print("\n## Upload, memory, cold start (median)\n")
print("| app | upload ms | idle MB | peak MB | cold start ms |")
print("|---|---|---|---|---|")
for app, runs in apps.items():
    med = lambda f: statistics.median(f(r) for r in runs)
    print(f"| {app} | {med(lambda r: r['upload'].get('median_total_ms') or 0):.1f} | {med(lambda r: r['memory']['idle_current_mb']):.0f} | "
          f"{med(lambda r: r['memory'].get('cgroup_peak_mb', 0)):.0f} | {med(lambda r: r['cold_start_ms']):.0f} |")
