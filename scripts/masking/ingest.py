#!/usr/bin/env python3
"""Ingest masking keys from Excel (.xlsx) or CSV (.csv) into staging_masking_item table.

Usage:
    # Auto-detect 'key_type' and 'key_no' columns from file:
    python scripts/masking/ingest.py --file keys.xlsx --batch MASK-2026

    # Specify key_type explicitly (for single-column files):
    python scripts/masking/ingest.py --file customer_ids.csv --batch MASK-2026 --key-type CUSTOMER_ID

    # Custom database connection:
    python scripts/masking/ingest.py --file keys.xlsx --batch MASK-2026 --db-url postgresql://user:pass@host:5432/db
"""

import os
import sys
import argparse
from typing import Optional

import pandas as pd
import psycopg2
from psycopg2.extras import execute_values

DEFAULT_DB_URL = "postgresql://postgres:password123@localhost:5432/deletion_db"


def ingest_file(
    file_path: str,
    batch_id: str,
    key_type: Optional[str] = None,
    db_url: str = DEFAULT_DB_URL,
) -> None:
    """Read keys from Excel/CSV and bulk insert into staging_masking_item."""

    if not os.path.isfile(file_path):
        print(f"ERROR: File not found: {file_path}")
        sys.exit(1)

    ext = os.path.splitext(file_path)[-1].lower()
    print(f"Reading masking keys file: {file_path} (format: {ext})")

    if ext == ".csv":
        df = pd.read_csv(file_path, dtype=str)
    elif ext in (".xlsx", ".xls"):
        df = pd.read_excel(file_path, dtype=str, engine="openpyxl")
    else:
        print(f"ERROR: Unsupported file format: {ext}. Use .csv or .xlsx")
        sys.exit(1)

    if df.empty:
        print("ERROR: File is empty.")
        sys.exit(1)

    # Clean column names (strip whitespace and lowercase for comparison)
    col_map = {c: str(c).strip() for c in df.columns}
    df.rename(columns=col_map, inplace=True)
    lower_cols = {str(c).lower(): c for c in df.columns}

    records_data = []

    # Case A: File contains both 'key_type' and 'key_no'
    if "key_type" in lower_cols and ("key_no" in lower_cols or "key_val" in lower_cols):
        type_col = lower_cols["key_type"]
        no_col = lower_cols["key_no"] if "key_no" in lower_cols else lower_cols["key_val"]
        print(f"Detected multi-type columns: type='{type_col}', key='{no_col}'")

        df_clean = df[[type_col, no_col]].dropna()
        for _, row in df_clean.iterrows():
            kt = str(row[type_col]).strip()
            kn = str(row[no_col]).strip()
            if kt and kn:
                records_data.append((kt, kn))

    # Case B: File has single key column
    else:
        target_col = df.columns[0]
        if "key_no" in lower_cols:
            target_col = lower_cols["key_no"]
        elif "customer_id" in lower_cols:
            target_col = lower_cols["customer_id"]

        resolved_type = key_type or "CUSTOMER_ID"
        print(f"Using column '{target_col}' with key_type='{resolved_type}'")

        keys = df[target_col].dropna().astype(str).str.strip().tolist()
        for k in keys:
            if k:
                records_data.append((resolved_type, k))

    total_raw = len(records_data)
    unique_records = list(dict.fromkeys(records_data))
    dupes = total_raw - len(unique_records)
    if dupes > 0:
        print(f"WARNING: Found {dupes} duplicate keys in file. Deduplicated.")

    print(f"Unique keys to ingest: {len(unique_records)}")

    # Build DB tuples: (batch_id, key_type, key_no)
    db_rows = [(batch_id, kt, kn) for (kt, kn) in unique_records]

    # Bulk insert into staging_masking_item
    print(f"Connecting to database: {db_url.split('@')[-1]}...")
    conn = psycopg2.connect(db_url)
    try:
        with conn.cursor() as cur:
            insert_sql = """
                INSERT INTO staging_masking_item (batch_id, key_type, key_no)
                VALUES %s
                ON CONFLICT (batch_id, key_type, key_no) DO NOTHING;
            """
            execute_values(cur, insert_sql, db_rows, page_size=1000)
            conn.commit()

            cur.execute("""
                SELECT key_type, COUNT(*)
                FROM staging_masking_item
                WHERE batch_id = %s
                GROUP BY key_type;
            """, (batch_id,))
            breakdown = dict(cur.fetchall())

        print(f"SUCCESS: Ingested {len(db_rows)} keys into staging_masking_item")
        print(f"  batch_id: {batch_id}")
        print(f"  Key types breakdown: {breakdown}")
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(description="Ingest masking keys from Excel/CSV into staging_masking_item")
    parser.add_argument("--file", required=True, help="Path to .xlsx or .csv file")
    parser.add_argument("--batch", required=True, help="Batch ID (e.g. MASK-2026)")
    parser.add_argument("--key-type", default=None, help="Explicit key_type if not present in file columns")
    parser.add_argument("--db-url", default=DEFAULT_DB_URL, help="PostgreSQL connection string")
    args = parser.parse_args()

    ingest_file(args.file, args.batch, args.key_type, args.db_url)


if __name__ == "__main__":
    main()
