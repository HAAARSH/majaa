"""Verify my theory: ADV07 tracks unallocated advance leftovers from CNs
and receipts. CN absorption vs advance is the deciding factor for whether
the app's PDF should render a separate 'CR NOTE' line.

Theory:
  - CN fully absorbed into a bill  → no ADV07 row → bill's RECDAMOUNT
    already reflects the reduction.
  - CN partially absorbed           → ADV07 row with leftover.
  - CN fully unallocated (advance)  → ADV07 row with full CN amount.

Also verify RECT receipts obey the same ADV07 pattern.

Read-only against E:\\screenshot\\DUAJAG\\Y207.
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

# Load everything
crn = rows("CRN07.DBF")
adv = rows("ADV07.DBF")
rect = rows("RECT07.DBF")
rctbil = rows("RCTBIL07.DBF")
inv = rows("INV07.DBF")
opnbil = rows("OPNBIL07.DBF")
acmast = rows("ACMAST07.DBF")

print(f"Loaded: CRN07={len(crn)}, ADV07={len(adv)}, RECT07={len(rect)}, RCTBIL07={len(rctbil)}, INV07={len(inv)}, OPNBIL07={len(opnbil)}")

# Map ACCODE → ACNAME for readable output
acname = {r['ACCODE']: (r.get('ACNAME') or '').strip() for r in acmast}

# Index ADV07 by RECTVNO (the voucher number linking to CRN/RECT)
adv_by_vno = defaultdict(list)
for a in adv:
    adv_by_vno[a.get('RECTVNO')].append(a)

# Index RCTBIL by RECTVNO (how much of each voucher was applied to bills)
rctbil_by_vno = defaultdict(list)
for b in rctbil:
    rctbil_by_vno[b.get('RECTVNO')].append(b)

# --- PART 1: classify every CN into Case A/B/C ---
case_a = []  # fully absorbed — no ADV row
case_b = []  # fully unallocated — ADV row amount == CN amount
case_c = []  # partial absorption
anomalies = []  # something doesn't add up

print("\n=== EVERY CREDIT NOTE IN CRN07 ===")
for cn in crn:
    rectvno = cn.get('RECTVNO') or cn.get('VNO')  # fall back to VNO if RECTVNO blank
    cn_amt = abs(cn.get('NETAMOUNT') or 0)
    cn_bill_amt = cn.get('BILLAMOUNT') or 0
    accode = cn.get('ACCODE')
    cn_no = cn.get('CRNOTENO')

    adv_rows = adv_by_vno.get(rectvno, [])
    adv_total = sum(a.get('AMOUNT', 0) for a in adv_rows)

    rctbil_rows = rctbil_by_vno.get(rectvno, [])
    rctbil_total = sum(b.get('AMOUNT', 0) for b in rctbil_rows)

    # Classify
    if adv_total == 0 and rctbil_total > 0:
        case_a.append((cn, rctbil_total))
    elif adv_total > 0 and rctbil_total == 0:
        case_b.append((cn, adv_total))
    elif adv_total > 0 and rctbil_total > 0:
        case_c.append((cn, adv_total, rctbil_total))
    else:
        anomalies.append((cn, adv_total, rctbil_total))

print(f"\nClassification:")
print(f"  Case A (fully absorbed, no ADV row):      {len(case_a)}")
print(f"  Case B (fully unallocated advance):       {len(case_b)}")
print(f"  Case C (partial absorption + advance):    {len(case_c)}")
print(f"  Anomalies (no ADV, no RCTBIL):            {len(anomalies)}")

# Sample outputs per case
print("\n--- Case A samples (CN fully absorbed into bills — no PDF line needed) ---")
for cn, rctbil_total in case_a[:3]:
    accode = cn.get('ACCODE')
    print(f"  ACCODE={accode} {acname.get(accode, '?')[:30]:<30}  CN #{cn['CRNOTENO']}  NET={cn['NETAMOUNT']}  RCTBIL applied={rctbil_total}")
    for b in rctbil_by_vno[cn.get('RECTVNO')][:5]:
        print(f"      → applied to BOOK={b.get('BOOK')} INV={b.get('INVOICENO')} amt={b.get('AMOUNT')} TYPE={b.get('TYPE')!r}")

print("\n--- Case B samples (fully unallocated — render as CR NOTE line in PDF) ---")
for cn, adv_total in case_b[:3]:
    accode = cn.get('ACCODE')
    print(f"  ACCODE={accode} {acname.get(accode, '?')[:30]:<30}  CN #{cn['CRNOTENO']}  NET={cn['NETAMOUNT']}  ADV leftover={adv_total}")

print("\n--- Case C samples (partial — render only the leftover portion) ---")
for cn, adv_total, rctbil_total in case_c[:3]:
    accode = cn.get('ACCODE')
    print(f"  ACCODE={accode} {acname.get(accode, '?')[:30]:<30}  CN #{cn['CRNOTENO']}  NET={cn['NETAMOUNT']}  applied={rctbil_total}  leftover={adv_total}")

if anomalies:
    print("\n--- Anomalies (no ADV and no RCTBIL — shouldn't happen if theory holds) ---")
    for cn, at, rt in anomalies[:5]:
        accode = cn.get('ACCODE')
        print(f"  ACCODE={accode} {acname.get(accode, '?')[:30]:<30}  CN #{cn['CRNOTENO']}  NET={cn['NETAMOUNT']}  RECTVNO={cn.get('RECTVNO')!r}  VNO={cn.get('VNO')!r}")

# --- PART 2: do RECT receipts also obey ADV07? ---
print("\n\n=== RECT (receipts) — do unallocated receipts appear in ADV07 too? ===")
rect_case_a = 0
rect_case_b = 0
rect_case_c = 0
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
print(f"  Receipts fully applied (no ADV):     {rect_case_a}")
print(f"  Receipts fully unallocated (advance): {rect_case_b}")
print(f"  Receipts partially applied:           {rect_case_c}")

# --- PART 3: spot-check Case A — verify bill's RECDAMOUNT reflects the CN absorption ---
if case_a:
    cn, total_applied = case_a[0]
    accode = cn.get('ACCODE')
    vno = cn.get('RECTVNO')
    print(f"\n=== SPOT CHECK (Case A #1): ACCODE={accode} {acname.get(accode, '?')[:40]} ===")
    print(f"  CN #{cn['CRNOTENO']}  NET={cn['NETAMOUNT']}  RCTBIL applied={total_applied}")
    print(f"  RCTBIL allocations for this CN's RECTVNO={vno}:")
    for b in rctbil_by_vno[vno]:
        tgt_book = b.get('BOOK')
        tgt_inv = b.get('INVOICENO')
        applied_amt = b.get('AMOUNT')
        print(f"    → BOOK={tgt_book} INVOICENO={tgt_inv}  applied={applied_amt}")
        # Find the target bill in INV or OPNBIL
        for src_name, src in (('INV07', inv), ('OPNBIL07', opnbil)):
            for bill in src:
                if bill.get('BOOK') == tgt_book and bill.get('INVOICENO') == tgt_inv and bill.get('ACCODE') == accode:
                    print(f"       in {src_name}: BILLAMOUNT={bill.get('BILLAMOUNT')} RECDAMOUNT={bill.get('RECDAMOUNT')} CLEARED={bill.get('CLEARED')!r}")
                    break
