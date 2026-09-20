#!/usr/bin/env python3
"""Ingest deletion keys from Excel (.xlsx) or CSV (.csv) into staging_deletion_item table.

Usage:
    python ingest.py --file sample_keys.csv --batch BATCH-2025 --group ORDERS
    python ingest.py --file sample_keys.xlsx --batch BATCH-2025 --group ORDERS
    python ingest.py --file sample_keys.csv --batch BATCH-2025 --group ORDERS --db-url postgresql://user:pass@host:5432/db
"""

import os
import sys
import argparse

import pandas as pd
import psycopg2
from psycopg2.extras import execute_values


DEFAULT_DB_URL = "postgresql://postgres:password123@localhost:5432/deletion_db"


def ingest_file(file_path: str, batch_id: str, group_code: str, db_url: str) -> None:
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

    # Use first column as key_no
    key_col = df.columns[0]
    print(f"Using column '{key_col}' as key_no")

    # Sanitize: convert to string, strip whitespace, drop empty
    keys = df[key_col].dropna().astype(str).str.strip().tolist()
    keys = [k for k in keys if k]  # remove empty strings

    total_raw = len(keys)

    # Detect and remove duplicates within file
    unique_keys = list(dict.fromkeys(keys))  # preserve order
    dupes = total_raw - len(unique_keys)
    if dupes > 0:
        print(f"WARNING: Found {dupes} duplicate keys in file. Deduplicating.")
    keys = unique_keys

    print(f"Keys to ingest: {len(keys)}")

    # Build records
    records = [(batch_id, group_code, k, "PENDING") for k in keys]

    # Bulk insert
    conn = psycopg2.connect(db_url)
    try:
        with conn.cursor() as cur:
            execute_values(
                cur,
                """
                INSERT INTO staging_deletion_item (batch_id, group_code, key_no, status)
                VALUES %s
                """,
                records,
                page_size=5000,
            )
        conn.commit()
        print(f"SUCCESS: Ingested {len(records)} keys into staging_deletion_item")
        print(f"  batch_id:   {batch_id}")
        print(f"  group_code: {group_code}")
    except Exception as e:
        conn.rollback()
        print(f"ERROR: Failed to insert: {e}")
        sys.exit(1)
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(
        description="Ingest deletion keys from Excel/CSV into staging table"
    )
    parser.add_argument(
        "--file", required=True, help="Path to .xlsx or .csv file"
    )
    parser.add_argument(
        "--batch", required=True, help="Batch ID, e.g. BATCH-2025"
    )
    parser.add_argument(
        "--group", required=True, help="Group code, e.g. ORDERS"
    )
    parser.add_argument(
        "--db-url",
        default=DEFAULT_DB_URL,
        help=f"PostgreSQL connection URL (default: {DEFAULT_DB_URL})",
    )
    args = parser.parse_args()
    ingest_file(args.file, args.batch, args.group, args.db_url)


if __name__ == "__main__":
    main()
