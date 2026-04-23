"""Connect to Supabase via PostgREST and inspect every table. No writes —
just HEAD/GET queries to verify our new customer_credit_notes and
customer_advances tables exist and match expected shape.

Reads credentials from env.json (service role for schema visibility).
"""
import json
import sys
import urllib.request
import urllib.error

sys.stdout.reconfigure(encoding='utf-8', errors='replace')

with open('env.json', 'r', encoding='utf-8') as f:
    env = json.load(f)

URL = env['SUPABASE_URL'].rstrip('/')
KEY = env.get('SUPABASE_SERVICE_ROLE_KEY') or env['SUPABASE_ANON_KEY']

def rest_get(path, **params):
    qs = '&'.join(f'{k}={v}' for k, v in params.items())
    full = f'{URL}/rest/v1/{path}'
    if qs:
        full = f'{full}?{qs}'
    req = urllib.request.Request(full)
    req.add_header('apikey', KEY)
    req.add_header('Authorization', f'Bearer {KEY}')
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode('utf-8', errors='replace'), dict(r.headers)

def rest_head(path):
    full = f'{URL}/rest/v1/{path}?select=*'
    req = urllib.request.Request(full, method='HEAD')
    req.add_header('apikey', KEY)
    req.add_header('Authorization', f'Bearer {KEY}')
    req.add_header('Prefer', 'count=exact')
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers)

# Step 1 — fetch OpenAPI spec to list all exposed tables
print(f"→ {URL}/rest/v1/")
spec_body, _ = rest_get('')
try:
    spec = json.loads(spec_body)
except Exception as e:
    print(f"Failed to parse OpenAPI: {e}")
    print(spec_body[:500])
    sys.exit(1)

paths = spec.get('paths', {}) or {}
defs = spec.get('definitions', {}) or spec.get('components', {}).get('schemas', {}) or {}

tables = sorted(
    name.lstrip('/').split('?')[0]
    for name in paths.keys()
    if name.startswith('/') and name.lstrip('/') and '/' not in name.lstrip('/')
)

print(f"\n=== TABLES EXPOSED VIA POSTGREST ({len(tables)}) ===")
for t in tables:
    print(f"  {t}")

# Step 2 — specifically verify the two new tables
TARGETS = ['customer_credit_notes', 'customer_advances']
print(f"\n=== SCHEMA CHECK FOR NEW TABLES ===")
for t in TARGETS:
    schema = defs.get(t) or {}
    props = schema.get('properties') or {}
    if not props:
        print(f"\n  {t}: NOT FOUND or no schema in OpenAPI spec")
        continue
    print(f"\n  {t}:")
    for col, info in props.items():
        t_type = info.get('type') or info.get('format') or '?'
        fmt = info.get('format') or ''
        default = info.get('default')
        nullable = 'NULL' if 'null' in (info.get('type') or []) or info.get('nullable') else ''
        print(f"    {col:<25} {t_type:<10} {fmt:<15} {nullable:<5} {('default='+str(default)) if default is not None else ''}")

# Step 3 — actual rowcount + 1-row sample for each new table
print(f"\n=== ROWCOUNT + SAMPLE FOR NEW TABLES ===")
for t in TARGETS:
    try:
        status, headers = rest_head(t)
        count_range = headers.get('content-range') or headers.get('Content-Range') or ''
        print(f"\n  {t}: HEAD status={status}  content-range={count_range!r}")
        if status == 200:
            body, _ = rest_get(t, limit=1)
            rows = json.loads(body)
            print(f"    sample row: {rows[0] if rows else '(empty table)'}")
    except Exception as e:
        print(f"  {t}: ERROR {e}")

# Step 4 — also peek at customer_bills + customer_receipts for comparison
print(f"\n=== EXISTING TABLES (for pattern comparison) ===")
for t in ['customer_bills', 'customer_receipts', 'customer_receipt_bills', 'customer_billed_items']:
    try:
        status, headers = rest_head(t)
        count_range = headers.get('content-range') or headers.get('Content-Range') or ''
        print(f"  {t}: status={status}  content-range={count_range!r}")
    except Exception as e:
        print(f"  {t}: ERROR {e}")
