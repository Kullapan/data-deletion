# 🚀 Performance Test Benchmark Report: 1M Source Records & 100K Excel Keys

## 📊 Executive Summary

This performance test benchmarks the **Yearly Data Deletion System** under high-volume production conditions:
- **Source Database Scale**: **1,000,000** parent orders + **1,000,000** child items + **1,000,000** grandchild logs (**3,000,000 total rows**).
- **Target Deletion Scale**: **100,000 keys** provided in an Excel file (`.xlsx`) containing 99,990 valid orders and 10 non-existent dummy orders.
- **Engine**: PostgreSQL 16 on Docker (`localhost:5432`).
- **Batch ID**: `PERF-1M-100K-1789886886`.

---

## ⏱️ Benchmark Results Summary

| Stage | Operations | Duration | Throughput | Resource / Detail |
|---|---|---|---|---|
| **1. Source Seeding** | 3,000,000 rows generated across 3 tables | `66.07s` | `45,403 rows/s` | `orders` + `order_items` + `order_item_logs` |
| **2. Excel Generation** | 100,000 rows written to `.xlsx` | `5.52s` | `18,116 keys/s` | File Size: `0.96 MB` |
| **3. Ingestion (`ingest.py`)** | Parse `.xlsx` + Bulk insert to Staging | `45.57s` | `2,194 keys/s` | `execute_values` (page size 5,000) |
| **4. Dry Run (`run_data_deletion_dry_run`)** | NOT_FOUND check + 3 COUNT estimates | `25.74s` | `3,885 keys/s` | 10 NOT_FOUND keys, 99,990 VALIDATED |
| **5. Real Deletion (`run_data_deletion`)** | 200 Chunks (chunk_size=500, throttle=0.05s) | `40.16s` | `2,490 keys/s` | **299,970 rows deleted** (7,469 rows/s) |
| **6. Post-Maintenance** | `VACUUM ANALYZE` across 5 tables | `0.77s` | - | Reclaimed dead tuples and updated statistics |

> ⏱️ **Total Ingestion to Complete Purge Time:** **`112.24 seconds`** (under 2 minutes!)

---

## 🔍 Detailed Phase Analysis

### Phase 1: Source Data Seeding (1M Orders, 3M Total Rows)
- **Orders Table**: 1,000,000 rows seeded in 3.33s (300,292 rows/s)
- **Order Items Table**: 1,000,000 rows with foreign key checking
- **Order Item Logs Table**: 1,000,000 rows with foreign key checking

### Phase 2: Excel (.xlsx) Key Generation & Ingestion
- Generated **100,000 rows** in `5.52s` (0.60 MB) with columns `key_type` and `key_no`.
- Ingested via Python CLI in `45.57s` (throughput: `2,194 keys/s`).
- All 100,000 keys loaded into `staging_deletion_item` as master keys.

### Phase 3: Analytical Dry Run (Task Expansion & Validation)
- Expanded 100,000 master items into `staging_deletion_task` based on matching `deletion_group` (`key_type = 'ORDER_NO'`).
- Accurately flagged **10 dummy keys** as `NOT_FOUND` via `NOT EXISTS` check against `orders`.
- Promoted **99,990 valid tasks** to `VALIDATED`.
- Accurately calculated estimated row count for all 3 levels:
  - `order_item_logs`: **99,990 rows**
  - `order_items`: **99,990 rows**
  - `orders`: **99,990 rows**
- Completed in just **`25.74s`**.

### Phase 4: Chunked Real Deletion
- **Chunk Configuration**: `chunk_size = 500`, `throttle_sec = 0.05s`.
- **Total Chunks**: 200 Chunks.
- **Sleep / Throttle Overhead**: 200 chunks × 0.05s = **10.0 seconds** of intentional I/O throttle.
- **Pure SQL Execution Time**: **`30.16 seconds`** for 200 micro-transactions deleting 299,970 rows!
- **Data Integrity**:
  - `orders` remaining rows: **900,010**
  - `order_items` remaining rows: **900,010**
  - `order_item_logs` remaining rows: **900,010**
  - Task final status: **99,990 COMPLETED, 10 NOT_FOUND**
  - Audit trail entries: **200 chunks logged per table (600 total audit records)**.

---

## 💡 Performance Tuning Recommendations for Operations

1. **Chunk Size Tuning**:
   - For 100,000 keys, increasing `chunk_size` from 500 to **1,000** reduces the number of transactions from 200 to 100, cutting throttle overhead by 50%.
2. **Throttle Configuration**:
   - In environments without read replicas or during designated maintenance windows, setting `throttle_sec = 0` will reduce total deletion time by ~10 seconds.
3. **Task Lookup Index**:
   - The composite index `idx_staging_task_lookup ON staging_deletion_task (batch_id, group_code, key_no)` provides instant `UPDATE ... WHERE key_no = ANY(...)` resolution across 100K task rows.
