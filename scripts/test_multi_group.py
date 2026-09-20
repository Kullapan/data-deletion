#!/usr/bin/env python3
"""Backward-compatibility forwarding wrapper for Multi-Group Test.
Redirects to scripts.deletion.test_multi_group.
"""
import os
import sys

deletion_dir = os.path.join(os.path.dirname(__file__), "deletion")
sys.path.insert(0, deletion_dir)

from test_multi_group import test_multi_group_expansion, DEFAULT_DB_URL
import argparse

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Multi-Group Test Wrapper")
    parser.add_argument("--db-url", default=DEFAULT_DB_URL, help="PostgreSQL connection string")
    args = parser.parse_args()
    test_multi_group_expansion(args.db_url)
