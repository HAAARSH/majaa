"""Survey every DBF in DUA's Y207 folder. Print rowcount + whether it has
ACCODE, DATE, AMOUNT. Find what the mobile app doesn't currently sync
and could. Output grouped by apparent purpose.
"""
import os
import sys
from dbfread import DBF

sys.stdout.reconfigure(encoding='utf-8', errors='replace')

Y207 = r"E:\screenshot\DUAJAG\Y207"

ALREADY_SYNCED = {
    'ACMAST07',      # customers
    'INV07',         # invoices
    'OPNBIL07',      # opening bills
    'RECT07',        # receipts
    'RCTBIL07',      # receipt-to-bill allocations
    'ITTR07',        # billed items
    'ITMRP07',       # stock/MRP
    # BILLED_COLLECTED is a DUA-generated summary CSV, not a raw DBF
}

results = []
for name in sorted(os.listdir(Y207)):
    if not name.lower().endswith('.dbf'):
        continue
    path = os.path.join(Y207, name)
    try:
        table = DBF(path, encoding='cp437', ignore_missing_memofile=True, char_decode_errors='ignore')
        field_names = [f.name for f in table.fields]
        row_count = sum(1 for _ in table)
        has_accode = 'ACCODE' in field_names
        has_date = 'DATE' in field_names
        has_amount = any(f in field_names for f in ['AMOUNT', 'BILLAMOUNT', 'NETAMOUNT'])
        base = name.replace('.DBF', '').replace('.dbf', '')
        synced = base in ALREADY_SYNCED
        results.append({
            'name': base, 'rows': row_count, 'fields': len(field_names),
            'accode': has_accode, 'date': has_date, 'amount': has_amount,
            'synced': synced, 'first_fields': field_names[:8],
        })
    except Exception as e:
        results.append({'name': name, 'error': str(e)})

# Filter: only tables with rows, sorted by relevance (accode+date+amount+rows)
non_empty = [r for r in results if 'error' not in r and r['rows'] > 0]
non_empty.sort(key=lambda r: (
    -int(r['accode']), -int(r['date']), -int(r['amount']), -r['rows']
))

print(f"{'NAME':<14} {'ROWS':>6} {'FLD':>3} AC DT AM SYNC  FIRST_FIELDS")
print('-' * 110)
for r in non_empty:
    mark = 'YES ' if r['synced'] else '----'
    flags = ''.join('Y' if r[k] else '.' for k in ('accode', 'date', 'amount'))
    print(f"{r['name']:<14} {r['rows']:>6} {r['fields']:>3} {flags:>5}  {mark}  {r['first_fields']}")

print(f"\n---- EMPTY DBFs ({sum(1 for r in results if 'error' not in r and r['rows'] == 0)}) ----")
for r in results:
    if 'error' not in r and r['rows'] == 0:
        print(f"  {r['name']}  ({r['fields']} fields)")
print(f"\n---- READ ERRORS ----")
for r in results:
    if 'error' in r:
        print(f"  {r['name']}: {r['error']}")
