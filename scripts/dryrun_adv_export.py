"""Dry-run ADV export against screenshot copy of Y207."""
import csv
import os
import sys
from dbfread import DBF

sys.stdout.reconfigure(encoding='utf-8', errors='replace')

DUA_ROOT = r"E:\screenshot\DUAJAG\Y207"
OUT_DIR = r"C:\Users\Harsh\StudioProjects\fmcgorders2603\scripts"

def find_dbf(folder, prefix):
    for f in os.listdir(folder):
        if f.upper().startswith(prefix.upper()) and f.upper().endswith('.DBF'):
            if prefix.upper() == 'ITEM' and 'ITMRP' in f.upper():
                continue
            if prefix.upper() == 'INV' and 'INVNO' in f.upper():
                continue
            return os.path.join(folder, f)
    return None

adv_file = find_dbf(DUA_ROOT, 'ADV')
print(f"find_dbf('ADV') → {adv_file}")
if not adv_file:
    print("FAIL: ADV file not found")
    sys.exit(1)

# Make sure we didn't accidentally match a different ADV prefix
print(f"Filename basename: {os.path.basename(adv_file)}")

db = DBF(adv_file, encoding='latin-1', ignore_missing_memofile=True)
field_names = [f.name for f in db.fields]
print(f"Fields: {field_names}")
records = list(db)
print(f"Rows: {len(records)}")
for r in records:
    print(f"  {dict(r)}")

# Sanity check: cross-reference with CRN07 to confirm RECTVNO=522 → Divya 1850
crn = list(DBF(os.path.join(DUA_ROOT, 'CRN07.DBF'), encoding='cp437',
               ignore_missing_memofile=True, char_decode_errors='ignore'))
cn_by_vno = {c.get('RECTVNO'): c for c in crn}
print("\nCross-check each ADV row against CRN:")
for a in records:
    vno = a.get('RECTVNO')
    cn = cn_by_vno.get(vno)
    if cn:
        print(f"  ADV RECTVNO={vno} amt={a.get('AMOUNT')}  ⇔  CN#{cn.get('CRNOTENO')} "
              f"ACCODE={cn.get('ACCODE')} NETAMOUNT={cn.get('NETAMOUNT')} "
              f"ACNAME={(cn.get('ACNAME') or '').strip()!r}")
    else:
        print(f"  ADV RECTVNO={vno} amt={a.get('AMOUNT')} — NOT in CRN07 (receipt-origin advance?)")
