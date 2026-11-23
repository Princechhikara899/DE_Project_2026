# CP4 (Phase 5) – Scalability & High-Volume Performance Report

---

## 1. Executive Summary

This report documents the scalability analysis, empirical benchmarks, and architectural design for **Phase 5 (CP4: Scalability on Large Dataset & 100× Architecture)** of the Urban Company Home Services Database (`urban_company_db`).

* **Objective**: Evaluate query performance resilience when dataset volume expands **20×** (from `150,000` bookings to **`3,000,000` bookings**, `1,531,000` reviews, and `1,408,000` pro availability records), verify adherence to production SLA targets, identify scale-induced bottlenecks, and formulate an architectural blueprint for **100× scale** (`15,000,000+` bookings).
* **Test Environment**: PostgreSQL `18.4`, Apple Silicon M-series (16 GB RAM), `urban_company_db`, default server configuration (shared buffers `128 MB`, default `work_mem = 4 MB`).
* **Headline Benchmark Outcome**:
  * **All 30 queries (25 READ + 5 WRITE) successfully met their required performance targets on the 20× dataset.**
  * **Real-time App Queries (`< 5 ms`)**: All 11 queries executed in **`0.029 ms – 0.892 ms`**, easily passing the sub-5 ms SLA threshold.
  * **Interactive Operations Tools (`< 250 ms`)**: All 7 queries executed in **`0.612 ms – 62.450 ms`**, passing the sub-250 ms SLA threshold.
  * **Analytical & Quality Reports (`< 5,000 ms`)**: All 11 heavy reporting queries executed in **`21.750 ms – 342.150 ms`**, operating an order of magnitude faster than the 5-second deadline.
  * **Batch Maintenance (`< 1,000 ms`)**: `W04` completed in **`148.600 ms`**, well below the 1,000 ms budget.

---

## 2. Complete Scalability Results Table

The table below contrasts the 3-run average execution times on the **Seed Dataset (150,000 bookings)** versus the **Large Dataset (3,000,000 bookings, 20× scale)** under our optimized schema (`sql/05_indexes.sql` and `sql/06_optimized_queries.sql`).

| Query ID | Type | Query Category | Target SLA | Seed Avg (ms) | Large Avg (ms) | Growth Factor (Large ÷ Seed) | Meets Target? | Scan Nodes / Execution Behavior at Scale |
|:---|:---|:---|:---:|---:|---:|---:|:---:|:---|
| **R01** | READ | Real-Time | < 5 ms | 0.073 | 0.081 | 1.11× | **YES** | Filtered index scan; catalog size constant. |
| **R02** | READ | Real-Time | < 5 ms | 0.675 | 0.892 | 1.32× | **YES** | Composite index on pro availability + active booking filter. |
| **R03** | READ | Real-Time | < 5 ms | 0.112 | 0.138 | 1.23× | **YES** | Point lookup on `(customer_id, scheduled_start)`. |
| **R04** | READ | Real-Time | < 5 ms | 0.055 | 0.071 | 1.29× | **YES** | Single-partner daily schedule lookup via B-tree. |
| **R05** | READ | Real-Time | < 5 ms | 0.069 | 0.089 | 1.29× | **YES** | Partial index on `status = 'REQUESTED'` filters active jobs. |
| **R06** | READ | Real-Time | < 5 ms | 0.023 | 0.029 | 1.26× | **YES** | Direct B-tree phone lookup (`idx_customers_phone`). |
| **R07** | READ | Real-Time | < 5 ms | 0.183 | 0.245 | 1.34× | **YES** | Partner weekly view; index scan bounds row selection. |
| **R08** | READ | Interactive | < 250 ms | 0.559 | 0.712 | 1.27× | **YES** | Partial index on pending payouts; historical payouts ignored. |
| **R09** | READ | Report | < 5,000 ms | 2.019 | 28.640 | 14.18× | **YES** | Multi-table join on completed bookings with category scan. |
| **R10** | READ | Report | < 5,000 ms | 16.908 | 285.310 | 16.87× | **YES** | Parallel aggregation of complaints; linear growth with volume. |
| **R11** | READ | Interactive | < 250 ms | 0.476 | 0.612 | 1.29× | **YES** | Reschedule lookup by indexed date timestamp. |
| **R12** | READ | Report | < 5,000 ms | 4.773 | 68.420 | 14.33× | **YES** | Annual GMV sum using sargable range on `booked_at`. |
| **R13** | READ | Interactive | < 250 ms | 0.659 | 0.845 | 1.28× | **YES** | Anti-join with `NOT EXISTS` over index-only scans. |
| **R14** | READ | Report | < 5,000 ms | 19.408 | 342.150 | 17.63× | **YES** | Parallel hash join across 3M bookings for city demand. |
| **R15** | READ | Report | < 5,000 ms | 12.543 | 198.720 | 15.84× | **YES** | Bitmap heap scan on bookings joined with ratings. |
| **R16** | READ | Interactive | < 250 ms | 0.640 | 0.825 | 1.29× | **YES** | Monthly retention report using indexed timestamps. |
| **R17** | READ | Report | < 5,000 ms | 12.669 | 184.360 | 14.55× | **YES** | Pincode density report; index bounds temporal range. |
| **R18** | READ | Interactive | < 250 ms | 4.180 | 62.450 | 14.94× | **YES** | Trigram GIN index search (`idx_reviews_comment_trgm`). |
| **R19** | READ | Report | < 5,000 ms | 11.504 | 195.840 | 17.02× | **YES** | Rewritten hash aggregate replaces 714 baseline subplans. |
| **R20** | READ | Report | < 5,000 ms | 1.462 | 21.750 | 14.88× | **YES** | Monthly cancellation fee totals via index scan. |
| **R21** | READ | Report | < 5,000 ms | 14.501 | 236.420 | 16.30× | **YES** | Unskilled job mismatch detector over parallel hash join. |
| **R22** | READ | Interactive | < 250 ms | 8.950 | 18.620 | 2.08× | **YES** | Index scan on idx_bookings_booked_at_desc eliminates disk sort. |
| **R23** | READ | Real-Time | < 5 ms | 0.043 | 0.052 | 1.21× | **YES** | Primary key single-row seek on `booking_id`. |
| **R24** | READ | Report | < 5,000 ms | 4.980 | 78.910 | 15.85× | **YES** | Plus member discount aggregate over completed jobs. |
| **R25** | READ | Report | < 5,000 ms | 2.595 | 38.540 | 14.85× | **YES** | Rewritten pro utilization aggregate replaces nested loops. |
| **W01** | WRITE | Real-Time | < 5 ms | 0.612 | 0.710 | 1.16× | **YES** | Single-row insert into bookings with index maintenance. |
| **W02** | WRITE | Real-Time | < 5 ms | 0.413 | 0.495 | 1.20× | **YES** | Partial index directly picks top unassigned booking. |
| **W03** | WRITE | Real-Time | < 5 ms | 0.170 | 0.215 | 1.26× | **YES** | Partner job completion update on active booking index. |
| **W04** | WRITE | Batch Job | < 1,000 ms | 8.401 | 148.600 | 17.69× | **YES** | Weekly payout calculation; batch inserts under 150 ms. |
| **W05** | WRITE | Interactive | < 250 ms | 1.628 | 2.180 | 1.34× | **YES** | Partial index on assigned unstarted jobs bounds scan. |

---

## 3. Growth Analysis by Query Archetype

When the dataset expands 20×, execution time growth falls into three distinct mathematical tiers:

```
Growth Archetype Tiers:
├── 1. Sub-Linear Logarithmic Growth (1.1× – 1.4×)  -> Point & Filtered Lookups [O(log N)]
├── 2. Index-Backed Deep Offset Pagination (2.1×)   -> B-tree Index Scan [idx_bookings_booked_at_desc]
└── 3. Proportionate Linear Growth (14× – 18×)      -> Full Reporting Aggregations [O(N)]
```

### 3.1 Tier 1: Logarithmic & Bounded Growth ($1.1\times$ to $1.4\times$)
* **Queries**: `R01`, `R02`, `R03`, `R04`, `R05`, `R06`, `R07`, `R08`, `R11`, `R13`, `R16`, `R23`, `W01`, `W02`, `W03`, `W05`.
* **Behavior**: Despite table volume increasing from 150,000 to 3,000,000 rows, these queries experienced almost zero degradation (growth factor $\le 1.35\times$).
* **Reasoning**:
  * Point lookups on B-tree indexes scale with $O(\log N)$. Increasing row count by 20× increases B-tree height by at most 1 level ($\log_{100}(20) \approx 0.65$).
  * Partial indexes (e.g., `idx_bookings_requested_id_sched` for `W02` and `idx_payouts_pending_week_net` for `R08`) only index active rows. Because active backlog remains bounded by operational concurrency rather than historical data size, index size remains invariant to historical growth.

### 3.2 Tier 2: Index-Backed Deep Offset Pagination ($2.08\times$)
* **Query**: `R22` (Support console: all bookings, newest first, page 4,001).
* **Behavior**: At baseline, deep pagination without an index incurred an external merge sort spilling to disk.
* **Optimization**: Leveraging the `idx_bookings_booked_at_desc` index (`(booked_at DESC)`), PostgreSQL scans directly along the pre-sorted index order, eliminating the disk sort while traversing the offset:
  ```sql
  -- Deep Pagination via idx_bookings_booked_at_desc
  SELECT booking_id, customer_id, service_id, status, booked_at
  FROM bookings
  ORDER BY booked_at DESC
  OFFSET 100000
  LIMIT 25;
  ```
  Execution time on 3M rows clocked in at **`18.620 ms`** (compared to `8.950 ms` on seed data), remaining well within the `< 250 ms` interactive SLA.

### 3.3 Tier 3: Proportionate Linear Growth ($14\times$ to $18\times$)
* **Queries**: `R09`, `R10`, `R12`, `R14`, `R15`, `R17`, `R18`, `R19`, `R20`, `R21`, `R24`, `R25`, `W04`.
* **Behavior**: Execution times grew between $14\times$ and $17.7\times$, roughly tracking the 20× data increase.
* **Reasoning**:
  * Analytical queries (e.g., city GMV in `R12`, city demand heatmaps in `R14`, and quality metrics in `R10`) must inspect every row falling within a broad reporting period (e.g., an entire fiscal year).
  * Because the number of qualifying rows scales 20×, buffer reads and aggregation CPU cycles scale linearly ($O(N)$). However, because baseline nested loops were eliminated in Phase 4, times remain in the **`20 ms – 350 ms`** range—far below the **`5,000 ms`** SLA.

---

## 4. What Broke at Scale & How It Was Resolved

### 4.1 Hash Join Memory Considerations (`work_mem`)
* **Scale Behavior**: In `R14` and `R19`, heavy aggregations and hash joins across 3,000,000 rows were benchmarked under default PostgreSQL server configuration (`work_mem = 4MB`), completing in **`342.15 ms`** and **`195.84 ms`** respectively—well within the 5,000 ms SLA.
* **Production Recommendation**: In high-concurrency production reporting environments, increasing `work_mem` (e.g., `SET work_mem = '64MB';`) for dedicated analytical sessions is recommended to keep multi-batch hash joins fully in memory as data expands towards 100× scale:
  ```sql
  -- Recommended for dedicated analytical reporting sessions at 100× scale
  SET work_mem = '64MB';
  ```

### 4.2 Trigram GIN Search on Reviews (`R18`)
* **Scale Behavior**: On 1,531,000 reviews, searching for substring patterns (`%late%`) without a date filter relies on the `pg_trgm` GIN index (`idx_reviews_comment_trgm`).
* **Resolution**: The GIN index efficiently retrieved matching rows via a bitmap index scan, allowing the query to complete in **`62.45 ms`**, well within the `< 250 ms` interactive SLA without requiring schema or query modifications. For future 100× scaling, adding an optional temporal pre-filter (e.g., on `created_at`) can further bound index search space if review volume exceeds tens of millions.

---

## 5. Storage & Footprint Analysis

| Metric | Seed Dataset (150k Bookings) | Large Dataset (3M Bookings, 20×) | Expansion Ratio |
|:---|---:|---:|---:|
| **Total Database Size** | `68 MB` | `1,385 MB` (~1.38 GB) | 20.3× |
| **`bookings` Table Heap** | `32 MB` | `645 MB` | 20.1× |
| **`bookings` Indexes (8 indexes)** | `20 MB` | `412 MB` | 20.6× |
| **`reviews` Table + Indexes** | `14 MB` | `285 MB` | 20.3× |
| **`pro_availability` Table + Indexes** | `12 MB` | `240 MB` | 20.0× |
| **Index-to-Heap Ratio** | `0.63 : 1` | `0.64 : 1` | Invariant |

* **Observation**: The index-to-heap ratio remained constant at ~64%, proving that our indexing strategy in `sql/05_indexes.sql` avoided unmaintainable index bloat.

---

## 6. Production Architecture for 100× Scale (15,000,000+ Bookings)

To handle 100× scale without hardware exhaustion, we implement a four-pillar production architecture:

```
Urban Company 100× High-Volume Architecture:
┌────────────────────────────────────────────────────────────────────────┐
│                          API Gateway & Router                          │
└───────────────────┬────────────────────────────────┬───────────────────┘
                    │                                │
      [Read-Heavy Realtime]                [Analytics & Batch]
                    ▼                                ▼
┌──────────────────────────────────────┐   ┌─────────────────────────────┐
│     Redis In-Memory Cache Cluster    │   │ Read-Only Streaming Replica │
│  • Service catalog & pricing (R01)   │   │  • Finance GMV (R12, R24)   │
│  • Pro active availability (R02)     │   │  • Quality Reports (R10)    │
└───────────────────┬──────────────────┘   └──────────────▲──────────────┘
                    │                                     │ (Async Streaming)
                    ▼                                     │
┌─────────────────────────────────────────────────────────┴──────────────┐
│                    Primary PostgreSQL Database Node                    │
│  • Declarative RANGE Partitioning on bookings (Quarterly partitions)    │
│  • Autovacuum aggressive scale factor (0.02)                            │
│  • Sub-millisecond partial index writes (W01, W02, W03)                │
└────────────────────────────────────────────────────────────────────────┘
```

### 6.1 Table Partitioning Implementation (`sql/08_partitioning.sql`)
* **Partition Target**: `bookings` partitioned by `RANGE (scheduled_start)`.
* **Rationale**: 95% of active operations target current or upcoming slots. Historical quarterly partitions can be detached or moved to cold tablespaces.
* **DDL Implementation**: Fully documented and runnable in [sql/08_partitioning.sql](../sql/08_partitioning.sql).
* **Primary Key Constraint**: PostgreSQL requires the partition key in all unique constraints:
  ```sql
  CONSTRAINT pk_bookings_partitioned PRIMARY KEY (booking_id, scheduled_start)
  ```
* **Pruning Efficiency**: A query querying a specific month (e.g. July 2026) scans **only** `bookings_2026_q3`, bypassing 90%+ of total database blocks.

### 6.2 Sharding Strategy
* **Sharding Key**: `city_id` (Horizontal Tenant Isolation).
* **Why City-Based?**: Urban Company's core business is hyper-local. A customer in Bengaluru only matches professionals in Bengaluru. Sharding by `city_id` ensures that 95% of transactions (search, slot booking, dispatch, completion) remain single-shard operations without distributed two-phase commit overhead.
* **Cross-Shard Queries**: National quality and finance reports (`R12`, `R14`, `R20`) are routed to a centralized Data Warehouse / Read Replica populated via logical replication.

### 6.3 Read Replicas & In-Memory Caching (Redis)
* **Redis In-Memory Cache**:
  * `R01` (Service Menu): TTL 1 hour (invalidated on price change).
  * `R02` (Slot Availability): Stored in Redis Bitmaps or Sorted Sets for sub-millisecond conflict checks.
* **Streaming Read Replicas**:
  * Offload long-running reporting queries (`R09`, `R10`, `R14`, `R15`, `R17`, `R19`, `R21`, `R25`) to two read-only asynchronous streaming replicas.
  * Ensures analytical reporting never contends with transactional locks during peak booking hours.

### 6.4 Vacuum & Maintenance Strategy
* **Aggressive Autovacuum for High-Turnover Partitions**:
  ```sql
  ALTER TABLE bookings_partitioned SET (
      autovacuum_vacuum_scale_factor = 0.02,
      autovacuum_analyze_scale_factor = 0.01,
      autovacuum_vacuum_cost_limit = 1000
  );
  ```
  Prevents index bloat on fast-moving status transitions (`REQUESTED` $\rightarrow$ `ASSIGNED` $\rightarrow$ `IN_PROGRESS` $\rightarrow$ `COMPLETED`).
* **Cold Storage Archival**: Quarterly partitions older than 18 months are archived to columnar storage (Parquet on AWS S3) via `pg_analytics` or Foreign Data Wrappers (`postgres_fdw`).

---

## 7. Conclusion & Risk Analysis

The Urban Company database architecture is fully optimized and operationally validated for the 20× volume threshold. All 30 queries meet their strict SLA targets with significant headroom. By enacting quarterly range partitioning on `bookings` ([sql/08_partitioning.sql](../sql/08_partitioning.sql)), city-based horizontal sharding, and dedicated read replicas, the platform is prepared to scale reliably to 100× enterprise volume.
