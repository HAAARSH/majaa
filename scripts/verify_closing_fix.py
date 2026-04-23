"""Verify that the CN-exclusion fix in export_billed_collected() produces
CLOSING_BALANCE values matching TRIAL07 for the customers where the
banner was firing (Divya, Gulati) and doesn't regress anyone else.
"""
import os
import sys
from collections import defaultdict
from dbfread import DBF

sys.stdout.reconfigure(encoding='utf-8', errors='replace')

Y207 = r"E:\screenshot\DUAJAG\Y207"

def rows(name):
    return list(DBF(os.path.join(Y207, name), encoding='cp437',
                    ignore_missing_memofile=True, char_decode_errors='ignore'))

acmast = {r['ACCODE']: r for r in rows("ACMAST07.DBF")}
inv = rows("INV07.DBF")
ledger = rows("LEDGER07.DBF")
crn = rows("CRN07.DBF")
trial = {r['ACCODE']: r for r in rows("TRIAL07.DBF")}

# billed (INV TYPE != CN)
billed = defaultdict(float)
for r in inv:
    billed[r['ACCODE']] += (r.get('BILLAMOUNT') or 0)

# OLD broken formula — collected includes CN entries
collected_old = defaultdict(float)
for r in ledger:
    if r.get('TYPE') == 'C':
        collected_old[r['ACCODE']] += (r.get('AMOUNT') or 0)

# NEW formula — excludes CN-book rows
collected_new = defaultdict(float)
for r in ledger:
    if r.get('TYPE') == 'C' and (r.get('BOOK') or '').upper() != 'CN':
        collected_new[r['ACCODE']] += (r.get('AMOUNT') or 0)

credit_notes = defaultdict(float)
for r in crn:
    credit_notes[r['ACCODE']] += (r.get('BILLAMOUNT') or 0)

# Compare for a sample of customers, especially known problem cases
sample_accodes = [1201, 658, 875, 1892, 249, 2618]  # Divya, Gulati, Ashok, etc.

# Also pull every customer who has CN and check math
cn_accodes = set(credit_notes.keys())

all_acs = set(billed.keys()) | set(collected_old.keys()) | cn_accodes
customer_acs = {ac for ac in all_acs if (acmast.get(ac, {}).get('ALIE') == 'A' and ac > 100)}

print(f"Total customers: {len(customer_acs)}  |  With CN: {len(cn_accodes & customer_acs)}")

def compute(ac, coll_map):
    rec = acmast.get(ac, {})
    opening = rec.get('AMOUNT', 0) or 0
    bill = billed.get(ac, 0)
    cn = credit_notes.get(ac, 0)
    coll = coll_map.get(ac, 0)
    return round(opening + bill - cn - coll, 2), opening, bill, cn, coll

print("\n=== PROBLEM CUSTOMERS (with CN, expect OLD≠TRIAL, NEW=TRIAL) ===")
print(f"{'ACCODE':<7} {'NAME':<38} {'TRIAL':>8} {'OLD':>8} {'NEW':>8} {'Δ_new':>8}  VERDICT")
matches_new = 0
matches_old = 0
for ac in sorted(cn_accodes & customer_acs):
    rec = acmast.get(ac, {})
    name = (rec.get('ACNAME') or '').strip()[:36]
    trial_bal = trial.get(ac, {}).get('AMOUNT', 0) or 0
    trial_type = trial.get(ac, {}).get('TYPE', '')
    trial_signed = trial_bal if trial_type == 'D' else -trial_bal
    new_val, *_ = compute(ac, collected_new)
    old_val, *_ = compute(ac, collected_old)
    delta_new = round(new_val - trial_signed, 2)
    delta_old = round(old_val - trial_signed, 2)
    verdict = '✓' if abs(delta_new) < 1.0 else '✗'
    if abs(delta_new) < 1.0:
        matches_new += 1
    if abs(delta_old) < 1.0:
        matches_old += 1
    print(f"{ac:<7} {name:<38} {trial_signed:>8.0f} {old_val:>8.0f} {new_val:>8.0f} {delta_new:>8.1f}  {verdict}")

print(f"\nSUMMARY for {len(cn_accodes & customer_acs)} customers with CN:")
print(f"  OLD formula matches TRIAL07: {matches_old}")
print(f"  NEW formula matches TRIAL07: {matches_new}")

# Also spot-check customers WITHOUT CN to confirm no regression
print("\n=== NON-CN CUSTOMERS (both OLD and NEW should match TRIAL07) ===")
non_cn_sample = [ac for ac in customer_acs if ac not in cn_accodes][:10]
mismatch_non_cn = 0
for ac in non_cn_sample:
    rec = acmast.get(ac, {})
    name = (rec.get('ACNAME') or '').strip()[:36]
    trial_bal = trial.get(ac, {}).get('AMOUNT', 0) or 0
    trial_type = trial.get(ac, {}).get('TYPE', '')
    trial_signed = trial_bal if trial_type == 'D' else -trial_bal
    new_val, *_ = compute(ac, collected_new)
    old_val, *_ = compute(ac, collected_old)
    delta = round(new_val - trial_signed, 2)
    if abs(delta) >= 1.0:
        mismatch_non_cn += 1
    print(f"{ac:<7} {name:<38} {trial_signed:>8.0f} {old_val:>8.0f} {new_val:>8.0f} {delta:>8.1f}")

print(f"\nNon-CN customers with mismatch (expect 0): {mismatch_non_cn}")
