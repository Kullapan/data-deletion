#!/usr/bin/env python3
"""Backward-compatibility forwarding wrapper for 1M/100K Benchmark Test.
Redirects to scripts.deletion.perf_test_1m_100k.
"""
import os
import sys

deletion_dir = os.path.join(os.path.dirname(__file__), "deletion")
sys.path.insert(0, deletion_dir)

from perf_test_1m_100k import main

if __name__ == "__main__":
    main()
