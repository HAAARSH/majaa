"""Trace the Rs.1,850 advance for DIVYA MEDICAL STORE on 15.04.2026.
Goal: confirm DUA's data model for unallocated advances so we know where
the app should read them from.
"""
import os
from dbfread import DBF

Y207 = r"E:\screenshot\DUAJAG\Y207"

def rows(name):
    path = os.path.join(Y207, name)
    return list(DBF(path, encoding='cp437', ignore_missing_memofile=True, char_decode_errors='ignore'))

# Step 1: find Divya Medical's ACCODE in ACMAST07
acmast = rows("ACMAST07.DBF")
divya = [r for r in acmast if 'DIVYA' in (r.get('ACNAME') or '').upper() and 'MEDICAL' in (r.get('ACNAME') or '').upper()]
print("=== DIVYA MEDICAL matches in ACMAST ===")
for r in divya:
    print(f"  ACCODE={r['ACCODE']}  ACNAME={r['ACNAME']!r}  GROUP={r.get('GROUP')!r}  PHONE={r.get('PHONENO')!r}")

if not divya:
    print("NOT FOUND")
    exit(1)

accode = divya[0]['ACCODE']

# Step 2: all RECT entries for this customer
rect = rows("RECT07.DBF")
divya_rect = [r for r in rect if r.get('ACCODE') == accode]
print(f"\n=== RECT07 entries for ACCODE={accode} ({len(divya_rect)} rows) ===")
for r in divya_rect:
    print(f"  DATE={r['DATE']}  AMOUNT={r['AMOUNT']}  BOOK={r.get('BOOK')!r}  INVOICENO={r.get('INVOICENO')}  BILLDATE={r.get('BILLDATE')}  BILLAMT={r.get('BILLAMOUNT')}  VNO={r.get('VNO')}  RECTVNO={r.get('RECTVNO')}  TYPE={r.get('TYPE')!r}  NARR1={r.get('NARRATION1')!r}")

# Step 3: all INV entries for this customer (current year bills)
inv = rows("INV07.DBF")
divya_inv = [r for r in inv if r.get('ACCODE') == accode]
print(f"\n=== INV07 entries for ACCODE={accode} ({len(divya_inv)} rows) ===")
for r in divya_inv:
    print(f"  DATE={r['DATE']}  BOOK={r['BOOK']}  INVOICENO={r['INVOICENO']}  BILLAMOUNT={r['BILLAMOUNT']}  RECDAMOUNT={r['RECDAMOUNT']}  CLEARED={r.get('CLEARED')!r}")

# Step 4: all OPNBIL entries for this customer (prior year carryover)
opnbil = rows("OPNBIL07.DBF")
divya_opnbil = [r for r in opnbil if r.get('ACCODE') == accode]
print(f"\n=== OPNBIL07 entries for ACCODE={accode} ({len(divya_opnbil)} rows) ===")
for r in divya_opnbil:
    print(f"  DATE={r['DATE']}  BOOK={r['BOOK']}  INVOICENO={r['INVOICENO']}  BILLAMOUNT={r['BILLAMOUNT']}  AMOUNT={r['AMOUNT']}  RECDAMOUNT={r['RECDAMOUNT']}")

# Step 5: all RCTBIL allocations touching this customer's receipts
# Need to match by RECTVNO from divya_rect
rctbil = rows("RCTBIL07.DBF")
rect_vnos = {r.get('VNO') for r in divya_rect if r.get('VNO')}
divya_rctbil = [b for b in rctbil if b.get('RECTVNO') in rect_vnos]
print(f"\n=== RCTBIL07 allocations for Divya's receipts (RECTVNOs={rect_vnos}) ===")
for b in divya_rctbil:
    print(f"  DATE={b['DATE']}  RECTVNO={b['RECTVNO']}  TYPE={b.get('TYPE')!r}  BOOK={b.get('BOOK')!r}  INVOICENO={b['INVOICENO']}  BILLDATE={b.get('BILLDATE')}  BILLAMT={b.get('BILLAMT')}  AMOUNT={b['AMOUNT']}  VOUTYPE={b.get('VOUTYPE')!r}  VOUTYPE2={b.get('VOUTYPE2')!r}")

# Step 6: compute sum check
print(f"\n=== RECONCILIATION ===")
opn_total = sum(r['BILLAMOUNT'] - (r.get('RECDAMOUNT') or 0) for r in divya_opnbil)
inv_unpaid = sum(r['BILLAMOUNT'] - (r.get('RECDAMOUNT') or 0) for r in divya_inv if r.get('CLEARED') != 'Y')
rect_total = sum(r['AMOUNT'] for r in divya_rect)
rctbil_allocated = sum(b['AMOUNT'] for b in divya_rctbil)
unallocated_advance = rect_total - rctbil_allocated

print(f"  OPNBIL unpaid (last year):          Rs.{opn_total:,.0f}")
print(f"  INV07 unpaid (current year):        Rs.{inv_unpaid:,.0f}")
print(f"  Sum of bills pending:               Rs.{opn_total + inv_unpaid:,.0f}")
print(f"  Total receipts from customer:       Rs.{rect_total:,.0f}")
print(f"  Receipts allocated to bills:        Rs.{rctbil_allocated:,.0f}")
print(f"  Unallocated advance (RECT - RCTBIL): Rs.{unallocated_advance:,.0f}  ← this is the -1850 row in DUA's PDF")
print(f"  Net outstanding (DUA would show):    Rs.{(opn_total + inv_unpaid) - unallocated_advance:,.0f}")
