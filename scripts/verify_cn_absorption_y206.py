"""Same verification as Y207 but against Y206 — full prior fiscal year.
Much bigger sample (CRN06 is ~1.7MB vs CRN07 at ~30KB).

If the theory holds at this scale, we're done.
"""
import os
import sys
from collections import defaultdict
from dbfread import DBF

sys.stdout.reconfigure(encoding='utf-8', errors='replace')

Y206 = r"E:\screenshot\DUAJAG\Y206"

def rows(name):
    path = os.path.join(Y206, name)
    if not os.path.exists(path):
        print(f"MISSING: {name}")
        return []
    return list(DBF(path, encoding='cp437',
                    ignore_missing_memofile=True, char_decode_errors='ignore'))

# Load
print("Loading Y206 (this may take a moment — LEDGER06 is 17MB)...")
crn = rows("CRN06.DBF")
adv = rows("ADV06.DBF")
rect = rows("RECT06.DBF")
rctbil = rows("RCTBIL06.DBF")
inv = rows("INV06.DBF")
opnbil = rows("OPNBIL06.DBF")
acmast = rows("ACMAST06.DBF")
print(f"Loaded: CRN={len(crn)}, ADV={len(adv)}, RECT={len(rect)}, "
      f"RCTBIL={len(rctbil)}, INV={len(inv)}, OPNBIL={len(opnbil)}")

acname = {r['ACCODE']: (r.get('ACNAME') or '').strip() for r in acmast}

adv_by_vno = defaultdict(list)
for a in adv:
    adv_by_vno[a.get('RECTVNO')].append(a)

rctbil_by_vno = defaultdict(list)
for b in rctbil:
    rctbil_by_vno[b.get('RECTVNO')].append(b)

case_a = 0
case_b = 0
case_c = 0
anomalies = []

# Sample tracking — keep the first 5 of each case for display
case_b_samples = []
case_c_samples = []

for cn in crn:
    rectvno = cn.get('RECTVNO') or cn.get('VNO')
    adv_rows = adv_by_vno.get(rectvno, [])
    adv_total = sum(a.get('AMOUNT', 0) for a in adv_rows)
    rctbil_rows = rctbil_by_vno.get(rectvno, [])
    rctbil_total = sum(b.get('AMOUNT', 0) for b in rctbil_rows)

    if adv_total == 0 and rctbil_total > 0:
        case_a += 1
    elif adv_total > 0 and rctbil_total == 0:
        case_b += 1
        if len(case_b_samples) < 5:
            case_b_samples.append((cn, adv_total))
    elif adv_total > 0 and rctbil_total > 0:
        case_c += 1
        if len(case_c_samples) < 5:
            case_c_samples.append((cn, adv_total, rctbil_total))
    else:
        anomalies.append((cn, adv_total, rctbil_total))

total = case_a + case_b + case_c + len(anomalies)
print(f"\n=== Y206 Credit-Note Classification ({total} total) ===")
print(f"  Case A (fully absorbed, no ADV row):     {case_a:>6}  ({100*case_a/total:.1f}%)")
print(f"  Case B (fully unallocated advance):      {case_b:>6}  ({100*case_b/total:.1f}%)")
print(f"  Case C (partial absorption + advance):   {case_c:>6}  ({100*case_c/total:.1f}%)")
print(f"  Anomalies (no ADV, no RCTBIL):           {len(anomalies):>6}  ({100*len(anomalies)/total:.1f}%)")

print("\n--- Case B samples (fully unallocated — need PDF line) ---")
for cn, adv_total in case_b_samples:
    accode = cn.get('ACCODE')
    print(f"  ACCODE={accode} {acname.get(accode, '?')[:35]:<35}  CN#{cn.get('CRNOTENO')}  NET={cn.get('NETAMOUNT')}  ADV_leftover={adv_total}")

print("\n--- Case C samples (partial absorption — render only leftover) ---")
if not case_c_samples:
    print("  (none)")
else:
    for cn, adv_total, rctbil_total in case_c_samples:
        accode = cn.get('ACCODE')
        print(f"  ACCODE={accode} {acname.get(accode, '?')[:35]:<35}  CN#{cn.get('CRNOTENO')}  NET={cn.get('NETAMOUNT')}  applied={rctbil_total}  leftover={adv_total}")

print("\n--- Anomaly samples (no ADV, no RCTBIL — CN in limbo) ---")
for cn, at, rt in anomalies[:5]:
    accode = cn.get('ACCODE')
    print(f"  ACCODE={accode} {acname.get(accode, '?')[:35]:<35}  CN#{cn.get('CRNOTENO')}  NET={cn.get('NETAMOUNT')}  DATE={cn.get('DATE')}")

# Receipts
rect_case_a = 0
rect_case_b = 0
rect_case_c = 0
rect_anom = 0
for r in rect:
    vno = r.get('VNO') or r.get('RECTVNO')
    adv_total = sum(a.get('AMOUNT', 0) for a in adv_by_vno.get(vno, []))
    rctbil_total = sum(b.get('AMOUNT', 0) for b in rctbil_by_vno.get(vno, []))
    if adv_total == 0 and rctbil_total > 0:
        rect_case_a += 1
    elif adv_total > 0 and rctbil_total == 0:
        rect_case_b += 1
    elif adv_total > 0 and rctbil_total > 0:
        rect_case_c += 1
    else:
        rect_anom += 1

print(f"\n=== Y206 Receipt Classification ({len(rect)} total) ===")
print(f"  Receipts fully applied (no ADV):       {rect_case_a:>6}  ({100*rect_case_a/len(rect):.1f}%)")
print(f"  Receipts fully unallocated (advance):  {rect_case_b:>6}  ({100*rect_case_b/len(rect):.1f}%)")
print(f"  Receipts partially applied:            {rect_case_c:>6}  ({100*rect_case_c/len(rect):.1f}%)")
print(f"  Receipts with no ADV/RCTBIL (limbo):   {rect_anom:>6}  ({100*rect_anom/len(rect):.1f}%)")

# Case C — prove partial absorption math
if case_c_samples:
    print("\n--- Case C math check (first sample) ---")
    cn, adv_total, rctbil_total = case_c_samples[0]
    net_abs = abs(cn.get('NETAMOUNT') or 0)
    print(f"  CN NETAMOUNT abs = {net_abs}")
    print(f"  RCTBIL applied   = {rctbil_total}")
    print(f"  ADV leftover     = {adv_total}")
    print(f"  Sum              = {rctbil_total + adv_total}")
    print(f"  Matches NETAMOUNT? {abs((rctbil_total + adv_total) - net_abs) < 1.0}")

# Spot check: one Case A to confirm bill RECDAMOUNT reflects CN
# pick a random Case A by finding a CN where RCTBIL exists and ADV is empty
if case_a > 0:
    print("\n--- Spot check: one Case A CN, verify matching bill's RECDAMOUNT ---")
    opnbil_by_key = {(b.get('BOOK'), b.get('INVOICENO'), b.get('ACCODE')): b for b in opnbil}
    inv_by_key = {(b.get('BOOK'), b.get('INVOICENO'), b.get('ACCODE')): b for b in inv}
    samples_shown = 0
    for cn in crn:
        if samples_shown >= 3:
            break
        rectvno = cn.get('RECTVNO') or cn.get('VNO')
        rctbil_rows = rctbil_by_vno.get(rectvno, [])
        adv_rows = adv_by_vno.get(rectvno, [])
        if rctbil_rows and not adv_rows:
            accode = cn.get('ACCODE')
            print(f"\n  ACCODE={accode} {acname.get(accode, '?')[:35]} — CN#{cn.get('CRNOTENO')} NET={cn.get('NETAMOUNT')}")
            for b in rctbil_rows[:3]:
                key = (b.get('BOOK'), b.get('INVOICENO'), accode)
                bill = opnbil_by_key.get(key) or inv_by_key.get(key)
                if bill:
                    src = 'OPNBIL' if key in opnbil_by_key else 'INV'
                    print(f"    → applied {b.get('AMOUNT')} to {src} {b.get('BOOK')}-{b.get('INVOICENO')}: "
                          f"BILLAMOUNT={bill.get('BILLAMOUNT')} RECDAMOUNT={bill.get('RECDAMOUNT')} CLEARED={bill.get('CLEARED')!r}")
                else:
                    print(f"    → applied {b.get('AMOUNT')} to {b.get('BOOK')}-{b.get('INVOICENO')} (NOT in current INV/OPNBIL — likely cleared/year-boundary)")
            samples_shown += 1
