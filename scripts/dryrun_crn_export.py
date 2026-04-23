"""Dry-run only the CRN export path on the screenshot copy of DUA,
to verify the output before running the full script on the live PC.

Produces test_CRN07.csv next to this script. Do NOT upload anywhere.
"""
import csv
import os
import sys
from dbfread import DBF

sys.stdout.reconfigure(encoding='utf-8', errors='replace')

DUA_ROOT = r"E:\screenshot\DUAJAG\Y207"
OUT_DIR = r"C:\Users\Harsh\StudioProjects\fmcgorders2603\scripts"

def find_dbf(folder, prefix):
    """Same helper as dua_export_all.py — literal copy for parity."""
    for f in os.listdir(folder):
        if f.upper().startswith(prefix.upper()) and f.upper().endswith('.DBF'):
            if prefix.upper() == 'ITEM' and 'ITMRP' in f.upper():
                continue
            if prefix.upper() == 'INV' and 'INVNO' in f.upper():
                continue
            return os.path.join(folder, f)
    return None


def dbf_to_csv(dbf_path, csv_path):
    db = DBF(dbf_path, encoding='latin-1', ignore_missing_memofile=True)
    field_names = [f.name for f in db.fields]
    records = list(db)
    with open(csv_path, 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=field_names)
        w.writeheader()
        for r in records:
            row = {}
            for k in field_names:
                v = r.get(k)
                if v is None:
                    row[k] = ''
                elif hasattr(v, 'strftime'):
                    row[k] = v.strftime('%Y-%m-%d')
                else:
                    row[k] = v
            w.writerow(row)
    return len(records)


crn_file = find_dbf(DUA_ROOT, 'CRN')
print(f"find_dbf('CRN') → {crn_file}")
if not crn_file:
    print("FAIL: CRN file not found")
    sys.exit(1)

csv_path = os.path.join(OUT_DIR, 'test_CRN07.csv')
count = dbf_to_csv(crn_file, csv_path)
print(f"Wrote {count} credit notes to {csv_path}")

# Spot-check Divya Medical's CN00023
print("\n--- Spot check: DIVYA MEDICAL (ACCODE=1201) in output ---")
with open(csv_path, 'r', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    headers = reader.fieldnames
    print(f"CSV columns ({len(headers)}): {headers[:15]} ...")
    found = False
    for row in reader:
        if row.get('ACCODE') == '1201':
            found = True
            print(f"  DATE={row.get('DATE')}  ACNAME={row.get('ACNAME')!r}")
            print(f"  BOOK={row.get('BOOK')}  INVOICENO={row.get('INVOICENO')}  CRNOTENO={row.get('CRNOTENO')}")
            print(f"  BILLAMOUNT={row.get('BILLAMOUNT')}  NETAMOUNT={row.get('NETAMOUNT')}")
            print(f"  REASON={row.get('REASON')!r}  SMANNAME={row.get('SMANNAME')!r}")
            print(f"  RECTVNO={row.get('RECTVNO')}")
    if not found:
        print("  !!! ACCODE=1201 NOT found in exported CSV")
