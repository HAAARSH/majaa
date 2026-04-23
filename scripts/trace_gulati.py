"""Trace GULATI CHEMIST fully through DUA's Y207 tables. Compute what
outstanding SHOULD be and compare against app's display."""
import os
import sys
from dbfread import DBF

sys.stdout.reconfigure(encoding='utf-8', errors='replace')

Y207 = r"E:\screenshot\DUAJAG\Y207"

def rows(name):
    return list(DBF(os.path.join(Y207, name), encoding='cp437',
                    ignore_missing_memofile=True, char_decode_errors='ignore'))

acmast = rows("ACMAST07.DBF")
gulati = [r for r in acmast if 'GULATI' in (r.get('ACNAME') or '').upper()]
print("=== GULATI matches in ACMAST ===")
for r in gulati:
    print(f"  ACCODE={r['ACCODE']}  ACNAME={r['ACNAME']!r}  GROUP={r.get('GROUP')!r}")

if not gulati:
    sys.exit(1)

ac = gulati[0]['ACCODE']

print(f"\n=== OPNBIL07 (prior-year carryover bills for {ac}) ===")
for b in rows("OPNBIL07.DBF"):
    if b.get('ACCODE') == ac:
        print(f"  {b.get('BOOK')}-{b.get('INVOICENO')}  date={b.get('DATE')}  BILLAMOUNT={b.get('BILLAMOUNT')}  AMOUNT={b.get('AMOUNT')}  RECDAMOUNT={b.get('RECDAMOUNT')}  CLEARED={b.get('CLEARED')!r}  SMAN={b.get('SMANNAME')!r}")

print(f"\n=== INV07 (current-year invoices for {ac}) ===")
for b in rows("INV07.DBF"):
    if b.get('ACCODE') == ac:
        print(f"  {b.get('BOOK')}-{b.get('INVOICENO')}  date={b.get('DATE')}  BILLAMOUNT={b.get('BILLAMOUNT')}  RECDAMOUNT={b.get('RECDAMOUNT')}  CLEARED={b.get('CLEARED')!r}  SMAN={b.get('SMANNAME')!r}")

print(f"\n=== RECT07 (receipts from {ac}) ===")
rect_rows = [r for r in rows("RECT07.DBF") if r.get('ACCODE') == ac]
for r in rect_rows:
    print(f"  date={r.get('DATE')}  AMOUNT={r.get('AMOUNT')}  BOOK={r.get('BOOK')!r}  INVOICENO={r.get('INVOICENO')}  VNO={r.get('VNO')}  NARR={r.get('NARRATION1')!r}")

print(f"\n=== RCTBIL07 (receipt-to-bill allocations for {ac}'s RECTVNOs) ===")
vnos = {r.get('VNO') for r in rect_rows if r.get('VNO')}
for b in rows("RCTBIL07.DBF"):
    if b.get('RECTVNO') in vnos:
        print(f"  RECTVNO={b.get('RECTVNO')}  TYPE={b.get('TYPE')!r}  {b.get('BOOK')!r}-{b.get('INVOICENO')}  BILLDATE={b.get('BILLDATE')}  BILLAMT={b.get('BILLAMT')}  AMOUNT={b.get('AMOUNT')}")

print(f"\n=== CRN07 (credit notes for {ac}) ===")
for c in rows("CRN07.DBF"):
    if c.get('ACCODE') == ac:
        print(f"  CN#{c.get('CRNOTENO')}  date={c.get('DATE')}  BILLAMOUNT={c.get('BILLAMOUNT')}  NETAMOUNT={c.get('NETAMOUNT')}  REASON={c.get('REASON')!r}  RECTVNO={c.get('RECTVNO')}  VNO={c.get('VNO')}")

print(f"\n=== ADV07 (unallocated advances for {ac}) ===")
for a in rows("ADV07.DBF"):
    if a.get('ACCODE') == ac:
        print(f"  RECTVNO={a.get('RECTVNO')}  AMOUNT={a.get('AMOUNT')}")

print(f"\n=== TRIAL07 (authoritative balance for {ac}) ===")
for t in rows("TRIAL07.DBF"):
    if t.get('ACCODE') == ac:
        print(f"  AMOUNT={t.get('AMOUNT')}  TYPE={t.get('TYPE')!r}  GROUP={t.get('GROUP')!r}")

print(f"\n=== LEDGER07 (journal entries for {ac}) ===")
for le in rows("LEDGER07.DBF"):
    if le.get('ACCODE') == ac:
        amt = le.get('AMOUNT') or 0
        tpe = le.get('TYPE')
        sign = '+' if tpe == 'D' else '-'
        print(f"  {le.get('DATE')}  {sign}{amt}  {le.get('BOOK')}-{le.get('BILLNO')}  VOUTYPE={le.get('VOUTYPE')!r}  NARR={le.get('NARRATION1')!r}")
