#!/usr/bin/env python3
"""Ingest deletion keys from Excel (.xlsx) or CSV (.csv) into staging_deletion_item table.

Usage:
    # Auto-detect 'key_type' and 'key_no' columns from file:
    python ingest.py --file keys.xlsx --batch BATCH-2025

    # Specify key_type explicitly (for single-column files):
    python ingest.py --file sample_keys.csv --batch BATCH-2025 --key-type ORDER_NO

    # With custom DB URL:
    python ingest.py --file keys.xlsx --batch BATCH-2025 --db-url postgresql://user:pass@host:5432/db
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
    """Read keys from Excel/CSV and bulk insert into staging_deletion_item."""

    if not os.path.isfile(file_path):
        print(f"ERROR: File not found: {file_path}")
        sys.exit(1)

    ext = os.path.splitext(file_path)[-1].lower()
    print(f"Reading file: {file_path} (format: {ext})")

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

    # Case A: File contains both 'key_type' and 'key_no' (or 'order_no') columns
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

    # Case B: File has explicit key_type passed or single key column
    else:
        target_col = df.columns[0]
        if "key_no" in lower_cols:
            target_col = lower_cols["key_no"]
        elif "order_no" in lower_cols:
            target_col = lower_cols["order_no"]

        resolved_type = key_type or "ORDER_NO"
        print(f"Using column '{target_col}' with key_type='{resolved_type}'")

        keys = df[target_col].dropna().astype(str).str.strip().tolist()
        for k in keys:
            if k:
                records_data.append((resolved_type, k))

    total_raw = len(records_data)
    # Deduplicate within file (preserve order)
    unique_records = list(dict.fromkeys(records_data))
    dupes = total_raw - len(unique_records)
    if dupes > 0:
        print(f"WARNING: Found {dupes} duplicate keys in file. Deduplicating.")

    print(f"Unique keys to ingest: {len(unique_records)}")

    # Build DB tuples: (batch_id, key_type, key_no)
    db_records = [(batch_id, kt, kn) for kt, kn in unique_records]

    # Bulk insert into staging_deletion_item
    conn = psycopg2.connect(db_url)
    try:
        with conn.cursor() as cur:
            execute_values(
                cur,
                """
                INSERT INTO staging_deletion_item (batch_id, key_type, key_no)
                VALUES %s
                ON CONFLICT (batch_id, key_type, key_no) DO NOTHING
                """,
                db_records,
                page_size=5000,
            )
        conn.commit()
        print(f"SUCCESS: Ingested {len(db_records)} keys into staging_deletion_item")
        print(f"  batch_id: {batch_id}")

        # Summary of types
        type_counts = {}
        for kt, _ in unique_records:
            type_counts[kt] = type_counts.get(kt, 0) + 1
        print(f"  Key types breakdown: {type_counts}")

    except Exception as e:
        conn.rollback()
        print(f"ERROR: Failed to insert: {e}")
        sys.exit(1)
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(
        description="Ingest deletion keys from Excel/CSV into staging_deletion_item table"
    )
    parser.add_argument(
        "--file", required=True, help="Path to .xlsx or .csv file"
    )
    parser.add_argument(
        "--batch", required=True, help="Batch ID, e.g. BATCH-2025"
    )
    parser.add_argument(
        "--key-type",
        required=False,
        default=None,
        help="Explicit Key Type (e.g. ORDER_NO, CUSTOMER_ID). Optional if file has key_type column.",
    )
    parser.add_argument(
        "--group",
        required=False,
        default=None,
        help="(Deprecated) Table group is now automatically resolved from key_type",
    )
    parser.add_argument(
        "--db-url",
        default=DEFAULT_DB_URL,
        help=f"PostgreSQL connection URL (default: {DEFAULT_DB_URL})",
    )
    args = parser.parse_args()

    ingest_file(args.file, args.batch, key_type=args.key_type, db_url=args.db_url)


if __name__ == "__main__":
    main()
