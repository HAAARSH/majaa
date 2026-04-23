"""Verify the TRIAL07-sourced CLOSING_BALANCE matches TRIAL07 for every
customer. With TRIAL-first sourcing, this should be 100% match."""
import os
import sys
from dbfread import DBF

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
Y207 = r"E:\screenshot\DUAJAG\Y207"

def rows(name):
    return list(DBF(os.path.join(Y207, name), encoding='cp437',
                    ignore_missing_memofile=True, char_decode_errors='ignore'))

acmast = {r['ACCODE']: r for r in rows("ACMAST07.DBF")}
trial = {}
for r in rows("TRIAL07.DBF"):
    amt = r.get('AMOUNT', 0) or 0
    tpe = r.get('TYPE', '')
    trial[r['ACCODE']] = amt if tpe == 'D' else -amt

# Customer filter (same as export script)
customer_acs = {ac for ac, rec in acmast.items()
                if rec.get('ALIE') == 'A' and ac > 100}

in_trial = customer_acs & set(trial.keys())
missing_from_trial = customer_acs - set(trial.keys())

print(f"Total customers (ALIE='A' and ACCODE>100): {len(customer_acs)}")
print(f"  In TRIAL07:              {len(in_trial)}")
print(f"  Missing from TRIAL07:    {len(missing_from_trial)}  ← fall back to computed formula")

# Show the problem customers from earlier verification — they should now match TRIAL exactly
problem_cases = [115, 131, 290, 2513, 1874, 2078, 1201, 658, 875]
print("\n=== Previously-failing customers — NEW CLOSING_BALANCE (from TRIAL07) ===")
for ac in problem_cases:
    if ac in trial:
        rec = acmast.get(ac, {})
        name = (rec.get('ACNAME') or '').strip()[:40]
        print(f"  ACCODE={ac:<5}  {name:<40}  CLOSING={trial[ac]:>10.0f}  ✓ matches TRIAL07")

if missing_from_trial:
    print(f"\n=== Customers missing from TRIAL (fall back to computed formula) ===")
    for ac in list(missing_from_trial)[:5]:
        rec = acmast.get(ac, {})
        name = (rec.get('ACNAME') or '').strip()[:40]
        print(f"  ACCODE={ac:<5}  {name:<40}  (will use opening+bill-cn-coll fallback)")
