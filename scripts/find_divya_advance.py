"""Scan EVERY DBF file in DUA's Y207 (and top-level) folder for any row
that references ACCODE=1201 (DIVYA MEDICAL STORE) or contains the amount
1850 around 15.04.2026. The DUA PDF shows an ADVANCE line for this
customer but neither RECT07 nor RCTBIL07 has it — so it must be
somewhere else.
"""
import os
import sys
from dbfread import DBF

# stdout encoding safety on Windows cp1252
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

TARGETS_DIR = [r"E:\screenshot\DUAJAG\Y207", r"E:\screenshot\DUAJAG"]
ACCODE = 1201

for folder in TARGETS_DIR:
    print(f"\n########## SCANNING {folder} ##########")
    dbfs = sorted([f for f in os.listdir(folder) if f.lower().endswith('.dbf')])
    for name in dbfs:
        path = os.path.join(folder, name)
        try:
            table = DBF(path, encoding='cp437', ignore_missing_memofile=True, char_decode_errors='ignore')
            field_names = {f.name for f in table.fields}
            if 'ACCODE' not in field_names:
                continue
            hits = []
            for r in table:
                if r.get('ACCODE') == ACCODE:
                    hits.append(r)
            if hits:
                print(f"\n>>> {name}  ({len(hits)} rows with ACCODE={ACCODE})")
                for h in hits[:10]:
                    compact = {k: v for k, v in h.items() if v not in (None, '', 0, 0.0, b'\x00')}
                    print(f"    {compact}")
                if len(hits) > 10:
                    print(f"    ... ({len(hits) - 10} more)")
        except Exception as e:
            print(f"[ERR] {name}: {e}")
