#!/usr/bin/env python3
"""Backward-compatibility forwarding wrapper for Data Deletion Ingest CLI.
Redirects to scripts.deletion.ingest.
"""
import os
import sys

# Add deletion directory to sys.path
deletion_dir = os.path.join(os.path.dirname(__file__), "deletion")
sys.path.insert(0, deletion_dir)

from ingest import main, ingest_file

if __name__ == "__main__":
    main()
