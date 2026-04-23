"""Read key DBFs from DUA JAG software and print their schema + sample rows.

Read-only exploration — we only want to understand the data model, not mutate it.
"""
import os
import sys
from dbfread import DBF

Y207 = r"E:\screenshot\DUAJAG\Y207"

# Files to inspect for outstanding-logic understanding
TARGETS = [
    "ACMAST07.DBF",   # customer master
    "INV07.DBF",      # invoices (current year bills)
    "OPNBIL07.DBF",   # opening bills (carry-forward)
    "OBILL07.DBF",    # ??
    "IBILL07.DBF",    # ??
    "TBILL07.DBF",    # ??
    "CLBILL07.DBF",   # ??
    "CLBAL07.DBF",    # ??
    "RECT07.DBF",     # receipts (payments)
    "RCTBIL07.DBF",   # receipt-to-bill allocations
    "RCINV07.DBF",    # ??
    "LEDGER07.DBF",   # ledger
    "JURN07.DBF",     # journal
    "AOUT07.DBF",     # area outstanding?
    "CMOUT07.DBF",    # customer month outstanding?
    "CSRECT07.DBF",   # customer receipts summary?
    "CUSTSL07.DBF",   # customer sales?
    "ITBNO07.DBF",    # invoice by bill no?
    "INVVNO07.DBF",   # invoice by voucher no?
]

def inspect(name):
    path = os.path.join(Y207, name)
    if not os.path.exists(path):
        print(f"[MISS] {name}")
        return
    try:
        table = DBF(path, encoding='cp437', ignore_missing_memofile=True, char_decode_errors='ignore')
        fields = [(f.name, f.type, f.length) for f in table.fields]
        print(f"\n=== {name} ({len(list(table))} rows) ===")
        # Re-open iterator since we consumed it
        table = DBF(path, encoding='cp437', ignore_missing_memofile=True, char_decode_errors='ignore')
        print("  Schema:")
        for n, t, l in fields:
            print(f"    {n:<20} {t} ({l})")
        # Show 2 sample rows if nonempty
        sample = []
        for i, row in enumerate(table):
            sample.append(row)
            if i >= 1:
                break
        if sample:
            print("  Sample rows:")
            for r in sample:
                line = "    | ".join(f"{k}={str(v)[:30]}" for k, v in r.items() if v not in (None, '', 0, 0.0))
                print(f"    {line[:250]}")
    except Exception as e:
        print(f"[ERR] {name}: {e}")

if __name__ == '__main__':
    for t in TARGETS:
        inspect(t)
