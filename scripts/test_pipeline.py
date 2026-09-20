#!/usr/bin/env python3
"""Backward-compatibility forwarding wrapper for Data Deletion Test Pipeline.
Redirects to scripts.deletion.test_pipeline.
"""
import os
import sys

# Add deletion directory to sys.path
deletion_dir = os.path.join(os.path.dirname(__file__), "deletion")
sys.path.insert(0, deletion_dir)

from test_pipeline import run_pipeline, DEFAULT_DB_URL
import argparse

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Automated Regression Test Pipeline Wrapper")
    parser.add_argument("--db-url", default=DEFAULT_DB_URL, help="PostgreSQL connection string")
    args = parser.parse_args()
    run_pipeline(args.db_url)
