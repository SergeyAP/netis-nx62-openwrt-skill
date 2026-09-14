# A blank Grafana panel: five causes, one symptom

Every failure below looks identical from the outside — an empty panel, no
error. Work through them **in this order**. Guessing is expensive: each one
individually makes the whole board blank, so fixing four of five changes
nothing visible.

## 0. First, prove the data exists

```sh
curl -s -u admin:PASS -G --data-urlencode 'query=node_load1{host="ROUTER"}' \
  'http://localhost:3000/api/datasources/proxy/uid/DS_UID/api/v1/query'
```

Data present → the problem is between Grafana and the panel, i.e. one of the
five below. Data absent → the exporter or the transport, not the dashboard.

## 1. Panel types your Grafana can no longer render

```sh
curl -s -u admin:PASS http://localhost:3000/api/dashboards/uid/UID \
 | python3 -c "import json,sys,collections; d=json.load(sys.stdin)['dashboard']; \
c=collections.Counter(o['type'] for o in d['panels'] if 'type' in o); \
print('schema', d.get('schemaVersion'), dict(c))"
```

`graph` and `singlestat` are Angular. Grafana 11 ships Angular disabled and has
removed `singlestat` outright. A schemaVersion-19 board is typically 80–90 %
those types and **cannot draw at all**, whatever the queries say.

Confirm what your instance still has:

```sh
curl -s -u admin:PASS http://localhost:3000/api/frontend/settings \
 | python3 -c "import json,sys; d=json.load(sys.stdin); \
print('angular:', d.get('angularSupportEnabled')); \
print('singlestat:', 'singlestat' in d.get('panels',{}))"
```

Fix: convert `graph` → `timeseries`, `singlestat` → `stat`, bump
`schemaVersion`. Or use a board authored on 37+.

## 2. Datasource as a string instead of an object

```json
"datasource": { "type": "prometheus", "uid": "vm-system" }    correct
"datasource": "vm-system"                                      broken
```

The string form is read as a datasource **name**. Replacing `${DS_PROMETHEUS}`
with your *uid* puts a uid where a name is expected; Grafana finds nothing and
resolves every query to empty, without an error.

## 3. A leftover `regex` on the variable

```json
"regex": "/([^:]+):.*/"
```

Upstream this extracted the host from an `instance` like `1.2.3.4:9100`. With
bare hostnames it matches nothing and **discards the entire list** — the picker
empties, and every panel behind it goes blank. The variable's query tests
perfectly clean, which is what makes this one so hard to see.

Prove it: fetch the raw values, then apply the board's regex to them by hand.

## 4. Label shape mismatch

Boards written for pull setups filter on `instance=~"$node:$port"`. Push agents
usually set `instance` to a bare hostname. Rewrite to the label you actually
have and drop the `$port` variable.

## 5. Variables with no default

`"current": {}` means nothing is selected on load, so panels filter on an empty
string — and **in PromQL an empty regex matches series that lack the label
entirely**. An unrelated job can therefore appear to work while the correct one
shows nothing, which is worse than blank. Pin a default; if only one value is
ever valid, make it a hidden `constant`.

## Verify the way the browser does

```sh
curl -s -u admin:PASS -X POST http://localhost:3000/api/ds/query \
  -H 'Content-Type: application/json' -d '{
    "queries":[{"refId":"A","datasource":{"type":"prometheus","uid":"DS_UID"},
                "expr":"node_load1{host=\"ROUTER\"}","range":true,
                "intervalMs":60000,"maxDataPoints":200}],
    "from":"now-2h","to":"now"}'
```

`scripts/check-dashboard.py` does this for a whole board and reports points per
panel. Testing the TSDB directly is the trap: all five failures above pass it.
