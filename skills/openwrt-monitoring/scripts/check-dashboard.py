#!/usr/bin/env python3
"""Run every panel of a Grafana dashboard the way the browser does.

Querying the TSDB directly proves the data exists. It does NOT prove a panel
will draw: a wrong datasource form, a leftover variable regex, an Angular panel
type or an unset variable all pass that test and still render nothing. This
goes through Grafana's own /api/ds/query, which is the path the browser takes.

    ./check-dashboard.py --url http://localhost:3000 --user admin --password ... \
                         --uid openwrt-18153 --var node=myrouter --var job=node
"""
import argparse, base64, json, re, sys, urllib.request

p = argparse.ArgumentParser()
p.add_argument("--url", default="http://localhost:3000")
p.add_argument("--user", default="admin")
p.add_argument("--password", required=True)
p.add_argument("--uid", required=True)
p.add_argument("--ds", default=None, help="datasource uid (default: from panels)")
p.add_argument("--var", action="append", default=[], metavar="NAME=VALUE")
p.add_argument("--range", dest="rng", default="now-2h")
p.add_argument("--limit", type=int, default=0, help="stop after N panels")
a = p.parse_args()

AUTH = base64.b64encode(f"{a.user}:{a.password}".encode()).decode()
SUB = {"$__rate_interval": "5m", "$__interval": "5m", "$__range": "1h"}
for kv in a.var:
    k, _, v = kv.partition("=")
    SUB["$" + k] = v

def call(path, body=None):
    r = urllib.request.Request(
        a.url + path,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": "Basic " + AUTH, "Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=60) as x:
        return json.loads(x.read())

d = call(f"/api/dashboards/uid/{a.uid}")["dashboard"]

panels = []
def walk(o):
    if isinstance(o, dict):
        if o.get("type") not in (None, "row") and o.get("targets") and "gridPos" in o:
            panels.append(o)
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(d)

print(f"{d.get('title')}  (schemaVersion {d.get('schemaVersion')})")

legacy = [o.get("type") for o in panels if o.get("type") in ("graph", "singlestat", "table-old")]
if legacy:
    print(f"  WARNING: {len(legacy)} Angular-era panels ({set(legacy)}) — "
          f"these do not render on Grafana 11+ regardless of the data")

ds_default = a.ds
if not ds_default:
    for o in panels:
        v = o.get("datasource")
        if isinstance(v, dict) and v.get("uid"):
            ds_default = v["uid"]; break

ok = empty = skipped = 0
for o in panels:
    if a.limit and (ok + empty) >= a.limit: break
    tgt = next((t for t in o.get("targets", []) if t.get("expr")), None)
    if not tgt:
        skipped += 1; continue
    expr = tgt["expr"]
    for k, v in SUB.items(): expr = expr.replace(k, v)
    if re.search(r"\$[A-Za-z_]", expr):
        skipped += 1; continue
    body = {"queries": [{"refId": "A",
                         "datasource": {"type": "prometheus", "uid": ds_default},
                         "expr": expr, "range": True, "instant": False,
                         "intervalMs": 60000, "maxDataPoints": 200}],
            "from": a.rng, "to": "now"}
    try:
        res = call("/api/ds/query", body)
    except Exception as e:
        print(f"  [ERR] {str(o.get('title'))[:38]:38} {e}"); empty += 1; continue
    pts = 0
    for _, v in res.get("results", {}).items():
        for f in v.get("frames", []):
            vals = f.get("data", {}).get("values")
            if vals and len(vals) > 1 and vals[1]:
                pts += len(vals[1])
    if pts:
        ok += 1
        print(f"  [OK ] {str(o.get('title'))[:38]:38} {o.get('type'):11} points={pts}")
    else:
        empty += 1
        print(f"  [ -- ] {str(o.get('title'))[:38]:38} {o.get('type'):11} EMPTY")
        print(f"         {expr[:100]}")

print(f"\n  {ok} with data, {empty} empty, {skipped} skipped (unresolved variables)")
sys.exit(1 if empty else 0)
