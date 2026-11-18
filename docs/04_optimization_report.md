# CP3 (Phase 4) – Query Optimization Report

---

## A. Executive Summary

This report documents the indexing strategy, SQL query rewrites, correctness validation, and measured performance impact for **Phase 4 (CP3: Query Optimization)** of the Urban Company Home Services Database (`urban_company_db`).

* **Optimization Objective**: Accelerate the 30-query production workload (`queries/workload_30.sql`) without modifying data, dropping constraints, or altering PostgreSQL server configuration—while fixing any logical query defects discovered during plan and result analysis.
* **Environment**: PostgreSQL `18.4 (Postgres.app)` on `MacBook Pro 14-inch (Nov 2024, Mac16,1)`, `Apple M4`, `16 GB RAM`; database `urban_company_db`, schema `public`, session `TimeZone = Asia/Kolkata`.
* **Dataset**: 11 normalized tables totaling **376,932 rows** (including `150,000` bookings, `76,539` reviews, `70,407` availability slots, `40,000` customers, and `27,015` payouts).
* **Indexes Created**: **14** new optimization indexes in `sql/05_indexes.sql` (**6** supporting-table indexes + **8** `bookings` indexes, totaling **20 MB** / `20,488 kB` of index storage, separate from the 11 pre-existing primary-key indexes). All 14 indexes were actively used by PostgreSQL's planner during benchmarking.
* **Queries Benchmarked**: All **30** workload queries (**25 READ**, **5 WRITE**) in `sql/06_optimized_queries.sql` (**6** queries rewritten: `R04`, `R12`, `R13`, `R19`, `R20`, `R25`; **24** queries kept verbatim).
* **Headline Performance Results** *(3-run baseline vs. 5-run optimized)*:
  * **READ queries (25)**: Sum dropped from **5,699.960 ms** (avg `227.998 ms`) to **120.059 ms** (avg `4.802 ms`) — **+97.89% improvement (47.5× faster)**.
  * **WRITE queries (5)**: Sum dropped from **35.800 ms** (avg `7.160 ms`) to **11.224 ms** (avg `2.245 ms`) — **+68.65% improvement (3.2× faster)**.
  * **Total workload (30)**: Sum dropped from **5,735.760 ms** to **131.283 ms** — **+97.71% improvement (43.7× faster)**.
  * **Logical Bug Fix**: Corrected `R13`'s `NOT IN (NULL)` defect so it returns the true **377** eligible active professionals rather than **0** rows.

---

## B. Baseline Performance

The baseline workload (`queries/workload_30.sql`) consists of **25 READ queries** (`R01`–`R25`) covering customer app, partner app, dispatch, quality, finance, and operations reporting, plus **5 WRITE queries** (`W01`–`W05`) covering booking creation, dispatch assignment, job completion, weekly payout generation, and no-show reconciliation.

In CP2 (`docs/03_baseline_timings.md` and `benchmarks/results/baseline/summary.csv`), all 30 queries were measured across **3 runs** using `EXPLAIN (ANALYZE, BUFFERS)` with only the 11 primary-key indexes present (no secondary indexes).

### Major Baseline Bottlenecks

1. **Correlated Subqueries ($N+1$ Full Table Scans) — `R19` and `R25`**:
   * `R19` averaged **3,381.296 ms** (run 1: `3,488.950 ms`, `1,816,446` shared buffer hits). For each of the 357 active Bengaluru professionals, PostgreSQL executed two `SubPlan` nodes, each performing a full `Seq Scan` on all 150,000 `bookings` rows (714 full table scans total).
   * `R25` averaged **2,089.105 ms** (run 1: `2,073.924 ms`, `908,695` shared buffer hits). It combined a `Nested Loop` join between `professionals` and `pro_availability` (whose `Join Filter` discarded `5,325,858` rows in ~216 ms) with a correlated `SubPlan` scanning 150,000 `bookings` rows 357 times.
2. **External Disk Sort on Deep Pagination — `R22`**:
   * Averaged **30.593 ms**. Without an index on `booked_at DESC`, PostgreSQL scanned all 150,000 bookings and spilled `6,408 kB` to temporary disk (`Sort Method: external merge Disk: 6408kB`, `temp read=690 written=804`) to skip `100,000` rows.
3. **Unindexed Leading-Wildcard Text Search — `R18`**:
   * Averaged **28.476 ms** (`Seq Scan on reviews` across 76,539 rows evaluating `comment ILIKE '%late%'`, then sorting 7,772 matches).
4. **Missing Secondary Indexes on High-Selectivity Lookups & Updates — `R02`–`R08`, `W02`, `W03`, `W05`**:
   * Real-time lookups (`R02` at `11.815 ms`, `R03` at `6.345 ms`, `R04` at `4.512 ms`, `R05` at `7.394 ms`, `R06` at `7.278 ms`, `R07` at `4.921 ms`) and targeted updates (`W03` at `6.694 ms`, `W05` at `7.763 ms`) performed full 40k–150k row sequential scans.
   * `W02` (`11.329 ms`) scanned `bookings_pkey` forward from `booking_id = 1`, discarding `148,818` historical rows (`2,940` buffers) before locating the first `status = 'REQUESTED'` row.
5. **Non-Sargable Date Expressions — `R04`, `R12`, `R20`**:
   * Wrapping indexed timestamp columns inside `DATE(b.scheduled_start)`, `EXTRACT(YEAR FROM b.booked_at)`, and `scheduled_start::date BETWEEN ...` prevented B-tree range seeks.
6. **Silent SQL NULL Logic Bug — `R13`**:
   * `R13` (`8.203 ms`) used `p.pro_id NOT IN (SELECT b.pro_id ...)` where the subquery contained `NULL` values, filtering out all 2,500 professionals and returning **0 rows**.

---

## C. Indexing Strategy (`sql/05_indexes.sql`)

A total of **14 new indexes** (**6** on supporting tables and **8** on `bookings`) were created via `sql/05_indexes.sql` and verified valid (`indisvalid = true`). These 14 indexes are entirely separate from the 11 pre-existing primary-key indexes created in `sql/01_schema.sql`.

### Complete Index Inventory & Actual Storage Measurements (`pg_relation_size`)

#### Supporting-Table Indexes (6)

| # | Index Name | Table | Type | Columns & Order | Partial Predicate | Target Queries | Rationale | Actual Index Size | Table Heap Size |
|---:|---|---|---|---|---|---|---|---:|---:|
| 1 | `idx_customers_phone` | `customers` | B-tree *(non-unique)* | `(phone)` | None (Full) | `R06` | Eliminates 40,000-row Seq Scan on mobile lookup. Kept non-unique because `sql/01_schema.sql` does not declare `phone` as `UNIQUE`. | 1,248 kB | 3,712 kB |
| 2 | `idx_pro_skills_category_pro` | `pro_skills` | B-tree | `(category_id, pro_id)` | None (Full) | `R02` | Inverse of `pro_skills_pkey (pro_id, category_id)`; enables Index Only Scan by category without scanning all 5,000 rows. | 128 kB | 224 kB |
| 3 | `idx_pro_availability_date_pro` | `pro_availability` | B-tree | `(work_date, pro_id)` | None (Full) | `R25`, `R02` | Reordered prefix of `pro_availability_pkey (pro_id, work_date, start_time)`; eliminates the 70k-row Seq Scan and 5.3M-row nested-loop filter in `R25`. | 1,560 kB | 3,592 kB |
| 4 | `idx_payouts_pending_week_net` | `payouts` | Partial B-tree | `(week_start, net_payout DESC)` | `WHERE status = 'PENDING'` | `R08` | Indexes only the ~4% `PENDING` rows (1,080 of 27,015); matches equality on `week_start` and descending sort on `net_payout`. | 56 kB | 2,112 kB |
| 5 | `idx_reschedules_created_at` | `reschedules` | B-tree | `(created_at)` | None (Full) | `R11` | Avoids scanning ~95% of `reschedules` outside June 2026; zero write cost in `W01`–`W05` and scales cleanly at 20× volume. | 136 kB | 456 kB |
| 6 | `idx_reviews_comment_trgm` | `reviews` | GIN (`gin_trgm_ops`) | `(comment)` | None (Full) | `R18` | Requires `pg_trgm` (installed v1.6); enables Bitmap Index Scan for leading-wildcard `comment ILIKE '%late%'`. | 2,344 kB | 4,608 kB |

#### `bookings` Table Indexes (8: 4 Full B-Tree + 4 Partial B-Tree)

| # | Index Name | Table | Type | Columns & Order | Partial Predicate | Target Queries | Rationale | Actual Index Size | Table Heap Size |
|---:|---|---|---|---|---|---|---|---:|---:|
| 7 | `idx_bookings_pro_sched` | `bookings` | B-tree | `(pro_id, scheduled_start)` | None (Full) | `R04`, `R07` | Equality on `pro_id`, then range/sort on `scheduled_start`; narrows per-pro lookups to ~60 rows (`W03` uses `idx_bookings_active_pro_sched`). | 4,616 kB | 20 MB |
| 8 | `idx_bookings_customer_sched` | `bookings` | B-tree | `(customer_id, scheduled_start)` | None (Full) | `R03` | Equality on `customer_id`, then range/ordering on `scheduled_start` for customer upcoming bookings. | 4,640 kB | 20 MB |
| 9 | `idx_bookings_booked_at_desc` | `bookings` | B-tree | `(booked_at DESC)` | None (Full) | `R22`, `R16`, `R12`, `R17` | Eliminates `R22`'s 6,408 kB external disk sort and serves `booked_at` range scans (`R16`, `R12`, `R17`). | 3,312 kB | 20 MB |
| 10 | `idx_bookings_status_sched` | `bookings` | B-tree | `(status, scheduled_start)` | None (Full) | `R09`, `R20`, `R25` *(+ `R24` skip scan)* | Equality on `status = 'COMPLETED'` followed by `scheduled_start` window. Also leveraged by PostgreSQL 18 skip scan in `R24`. | 2,240 kB | 20 MB |
| 11 | `idx_bookings_requested_id_sched` | `bookings` | Partial B-tree | `(booking_id, scheduled_start)` | `WHERE status = 'REQUESTED'` | `W02`, `R05` | Leading `booking_id` supports `W02`'s `MIN(booking_id)` via O(1) Index Only Scan (`Limit 1`). For `R05`, `scheduled_start` is the second column (no direct range seek), but scanning this 84-row partial index avoids scanning 150k rows without adding a duplicate index. | 16 kB | 20 MB |
| 12 | `idx_bookings_active_pro_sched` | `bookings` | Partial B-tree | `(pro_id, scheduled_start, scheduled_end)` | `WHERE status IN ('ASSIGNED', 'IN_PROGRESS')` | `R02`, `W03` | Tiny 359-row active subset prevents `R02`'s anti-join from fetching historical completed jobs via index #7 and enables Index Only Scan on overlap checks. | 32 kB | 20 MB |
| 13 | `idx_bookings_cancelled_cust` | `bookings` | Partial B-tree | `(pro_id)` | `WHERE status = 'CANCELLED_BY_CUSTOMER'` | `R13` | Indexes only the 12,123 customer-cancelled rows (~8.1%) for the corrected `NOT EXISTS` Merge Anti Join (`Index Only Scan`). | 144 kB | 20 MB |
| 14 | `idx_bookings_assigned_unstarted` | `bookings` | Partial B-tree | `(scheduled_end)` | `WHERE status = 'ASSIGNED' AND started_at IS NULL` | `W05` | Tiny partial index (≤359 rows) leading with `scheduled_end`; eliminates 150k-row Seq Scan in `W05`. | 16 kB | 20 MB |

* **Total Size of All 14 New Indexes**: **20 MB** (`20,488 kB` / `20,979,712` bytes).
* **Storage & Write Trade-Off**: The 4 full `bookings` indexes account for `14,808 kB` (~72% of all new index storage), while the 4 partial `bookings` indexes plus `idx_payouts_pending_week_net` consume just `264 kB` combined (~1.3% of new index storage) while delivering major gains on `R02`, `R05`, `R08`, `R13`, `W02`, `W03`, and `W05`. Partial indexes minimize disk footprint and avoid maintenance on non-matching rows, though they still require index updates whenever a row enters or leaves their predicate (analyzed in Section I).

### Intentionally Excluded Indexes

1. **`reviews(created_at)` (Excluded)**:
   * In `R15` (`12.651 ms` baseline), `Seq Scan on reviews` filtering June 2026 (`4,265 / 76,539` rows) took only `2.56–3.09 ms`, whereas the `Hash Join` + `Seq Scan on bookings` (`150,000` rows) accounted for ~75% (`~9.5 ms`) of total runtime. Indexing `reviews(created_at)` cannot help the join on `booking_id` or `ORDER BY avg_rating`, making it low-value for an analytics query (`< 5,000 ms` scale target).
2. **`bookings(completed_at)` (Excluded)**:
   * Only `W04` (`8.920 ms` baseline) filters `bookings` purely by `completed_at` (`R07` already filters by `pro_id = 425`, which uses `idx_bookings_pro_sched` to narrow down to ~60 rows). Because `85.1%` of bookings (`127,692` rows) are `COMPLETED`, adding an index on `completed_at` would add another ~3–4 MB full-scale index on `bookings` and extra write overhead on every job completion (`W03`) solely to optimize a weekly batch job already well under its `< 1,000 ms` target.

---

## D. Query Rewrites (`sql/06_optimized_queries.sql`)

Only **6 queries** were rewritten; the remaining **24 queries** remain verbatim from `queries/workload_30.sql`. No hardcoded timezone offsets (such as `+05:30`) were introduced; date-only boundaries inherit PostgreSQL's session `TimeZone` (`Asia/Kolkata`), matching the original `DATE()`, `EXTRACT()`, and `::date` semantics.

### 1. `R04` — Partner App: Pro 425's Jobs on 2 July 2026
* **Original Bottleneck**: `DATE(b.scheduled_start) = '2026-07-02'` wrapped the timestamp column in a function, preventing index range seeks and forcing a 150,000-row Seq Scan (`4.512 ms`).
* **SQL Change**: Replaced with `b.scheduled_start >= '2026-07-02' AND b.scheduled_start < '2026-07-03'`.
* **Plan & Timing**: Switched to `Index Scan using idx_bookings_pro_sched` (`10` buffers vs. `2,548` baseline). Improved from **4.512 ms → 0.055 ms** (**+98.78%**, **82.0×**).
* **Correctness**: Exact match (`1` row, `0` bidirectional `EXCEPT ALL` diffs, identical MD5).

### 2. `R12` — UC Plus: Monthly Discounts in 2026
* **Original Bottleneck**: `EXTRACT(YEAR FROM b.booked_at) = 2026` was non-sargable, forcing a Parallel Seq Scan on all 150,000 rows (`8.160 ms`).
* **SQL Change**: Replaced with `b.booked_at >= '2026-01-01' AND b.booked_at < '2027-01-01'`.
* **Plan & Timing**: Enabled `Index Scan using idx_bookings_booked_at_desc` skipping 2025 rows (~66.9% of table; `1,340` buffers vs. `2,582`). Improved from **8.160 ms → 4.773 ms** (**+41.51%**, **1.7×**).
* **Correctness**: Exact match (`6` rows, `0` diffs, identical MD5).

### 3. `R13` — Partner Rewards: Active Pros With No Customer Cancellations *(Logical Bug Fix)*
* **Original Bottleneck & Bug**:
  ```sql
  -- Original (buggy):
  WHERE p.status = 'ACTIVE'
    AND p.pro_id NOT IN (SELECT b.pro_id FROM bookings b WHERE b.status = 'CANCELLED_BY_CUSTOMER');
  ```
  In `urban_company_db`, `bookings.pro_id` is nullable (unassigned bookings cancelled by customers before assignment have `pro_id IS NULL`). Out of **12,123** customer-cancelled bookings, **6,058** have `pro_id IS NULL`. Under SQL three-valued logic, `p.pro_id NOT IN (v1, v2, ..., NULL)` expands to `p.pro_id <> v1 AND ... AND p.pro_id <> NULL`, which evaluates to `UNKNOWN` or `FALSE` for every professional—causing the `WHERE` clause to filter out all 2,500 professionals and return **0 rows** (matching Problem P5 in `README.md`).
* **SQL Change**: Rewrote to `NOT EXISTS (SELECT 1 FROM bookings b WHERE b.pro_id = p.pro_id AND b.status = 'CANCELLED_BY_CUSTOMER')`.
* **Semantics Note**: **This is a logical bug fix, NOT an equivalent-output optimization.** Original output was **0 rows** (incorrect); optimized output is **377 rows** (all active professionals with zero customer-cancelled bookings).
* **Plan & Timing**: Uses `Merge Anti Join` over `professionals_pkey` and `Index Only Scan using idx_bookings_cancelled_cust` (`286` buffers vs. `2,571`). Execution time dropped from **8.203 ms → 0.659 ms** (**+91.97%**, **12.4×**), though timing comparison must note that the query now performs the correct anti-join returning 377 rows.

### 4. `R19` — City Report: Active Bengaluru Pros' June Jobs & Last Job Date
* **Original Bottleneck**: Two correlated scalar subqueries in `SELECT` forced 714 full `bookings` Seq Scans (`1,816,446` shared buffer hits, **3,381.296 ms**).
* **SQL Change**: Replaced both correlated subqueries with a single pre-aggregated subquery grouped by `pro_id` (`WHERE pro_id IS NOT NULL`) using `count(*) FILTER (...)` and `max(completed_at)`, joined via `LEFT JOIN` to `professionals` with `coalesce(b.june_jobs, 0)`.
* **Plan & Timing**: Reduced to a single-pass `Parallel Seq Scan` + `HashAggregate` + `Hash Right Join` (`2,574` shared buffer hits—**99.86% fewer buffers**). Dropped from **3,381.296 ms → 11.504 ms** (**+99.66%**, **293.9×**).
* **Correctness**: Exact match (`357` rows, `0` diffs, identical MD5).

### 5. `R20` — Finance: Daily GMV & Running Total for June 2026
* **Original Bottleneck**: `scheduled_start::date BETWEEN '2026-06-01' AND '2026-06-30'` cast `scheduled_start` to `date`, preventing B-tree index usage and forcing a 150k-row Seq Scan (`9.099 ms`).
* **SQL Change**: Replaced with `scheduled_start >= '2026-06-01' AND scheduled_start < '2026-07-01'`.
* **Plan & Timing**: Uses `Bitmap Index Scan on idx_bookings_status_sched` + `Bitmap Heap Scan` (`176` buffers vs. `2,582`). Dropped from **9.099 ms → 1.462 ms** (**+83.93%**, **6.2×**).
* **Correctness**: Exact match (`30` rows, `0` diffs, identical MD5).

### 6. `R25` — Capacity: Weekly Utilisation of Bengaluru Professionals (22–28 June 2026)
* **Original Bottleneck**: Combined a 5.3M-row nested-loop join filter on `pro_availability` with a correlated subquery scanning 150k `bookings` rows 357 times (`908,695` shared buffer hits, **2,089.105 ms**).
* **SQL Change**: Split into two independent CTEs aggregated to the `pro_id` grain (`avail` for availability minutes and `booked` for completed booking minutes), joined 1-to-1 via `LEFT JOIN` so no row multiplication can occur.
* **Plan & Timing**: Uses `Bitmap Index Scan on idx_pro_availability_date_pro` (`avail`) and `Bitmap Index Scan on idx_bookings_status_sched` (`booked`) joined via `Hash Left Join` (`576` buffers vs. `908,695`—**99.94% fewer buffers**). Dropped from **2,089.105 ms → 2.595 ms** (**+99.88%**, **805.1×**).
* **Correctness**: Exact match on both the full 357-row set (`0` diffs, identical MD5) and the returned `LIMIT 30` set (`0` diffs).

---

## E. Correctness Validation

All 6 rewritten queries and all 5 write queries were validated directly against `urban_company_db` (`TimeZone = Asia/Kolkata`) before benchmarking.

### 1. Equivalent-Output Rewritten Read Queries

| Query | Original Rows | Optimized Rows | `Orig EXCEPT ALL Opt` | `Opt EXCEPT ALL Orig` | Original MD5 | Optimized MD5 | Result |
|---|---:|---:|---:|---:|---|---|:---:|
| **R04** | 1 | 1 | 0 | 0 | `a7c0ec771f8c151de3a87a5148860ceb` | `a7c0ec771f8c151de3a87a5148860ceb` | ✅ Exact match |
| **R12** | 6 | 6 | 0 | 0 | `746c4dd5b871a7ecce76fabf7b4d35d1` | `746c4dd5b871a7ecce76fabf7b4d35d1` | ✅ Exact match |
| **R19** | 357 | 357 | 0 | 0 | `41fea6a89b9760ed60e71ef68a5767b6` | `41fea6a89b9760ed60e71ef68a5767b6` | ✅ Exact match |
| **R20** | 30 | 30 | 0 | 0 | `0104661c8b45e6357a82848aa17d1de5` | `0104661c8b45e6357a82848aa17d1de5` | ✅ Exact match |
| **R25** *(all 357 rows)* | 357 | 357 | 0 | 0 | `8a1ff11a1bd6d8516563ce9386d5be8b` | `8a1ff11a1bd6d8516563ce9386d5be8b` | ✅ Exact match |
| **R25** *(`LIMIT 30`)* | 30 | 30 | 0 | 0 | — | — | ✅ Exact match |

### 2. `R13` Reference-Query Validation
* Original `NOT IN`: **0 rows** (due to **6,058** `NULL` `pro_id` rows among `12,123` `CANCELLED_BY_CUSTOMER` bookings).
* Optimized `NOT EXISTS`: **377 rows** (out of `2,220` active professionals).
* Cross-checked against `NOT IN (SELECT b.pro_id FROM bookings b WHERE b.status = 'CANCELLED_BY_CUSTOMER' AND b.pro_id IS NOT NULL)`: **377 rows**, `0` bidirectional `EXCEPT ALL` diffs, and **0** false positives (verified via join against `bookings` where `status = 'CANCELLED_BY_CUSTOMER'`).

### 3. Write Queries (`W01`–`W05`) & Database Integrity
* All 5 write queries remained verbatim from `queries/workload_30.sql` and were validated inside isolated `BEGIN; ... ROLLBACK;` transactions:
  * `W01`: `INSERT 0 1` → rolled back
  * `W02`: `UPDATE 1` → rolled back
  * `W03`: `UPDATE 1` → rolled back
  * `W04`: `INSERT 0 401` → rolled back
  * `W05`: `UPDATE 154` → rolled back
* Full-file execution of `sql/06_optimized_queries.sql` (wrapped in `BEGIN; ... ROLLBACK;`) exited with code `0`.
* Verified both post-validation and post-benchmark that all **11 tables** retain their exact initial row counts (`bookings = 150,000`, `reviews = 76,539`, `pro_availability = 70,407`, `customers = 40,000`, `payouts = 27,015`, `reschedules = 5,391`, `pro_skills = 5,000`, `professionals = 2,500`, `services = 60`, `cities = 10`, `service_categories = 10`) and all 6 booking status counts remain identical (`COMPLETED: 127,692`, `CANCELLED_BY_CUSTOMER: 12,123`, `CANCELLED_BY_PRO: 5,924`, `NO_SHOW: 3,818`, `ASSIGNED: 359`, `REQUESTED: 84`).

---

## F. Benchmark Methodology

* **Optimized Benchmark Command** *(exact README Phase 4 command, with PostgreSQL 18.4 `psql` on `PATH`)*:
  ```bash
  ./benchmarks/run_benchmark.sh urban_company_db optimized 5 sql/06_optimized_queries.sql
  ```
* **Run Counts**:
  * Baseline (`benchmarks/results/baseline/`): **3 runs** per query (`queries/workload_30.sql`, PK indexes only).
  * Optimized (`benchmarks/results/optimized/`): **5 runs** per query (`sql/06_optimized_queries.sql`, PK + 14 optimization indexes).
* **Execution Isolation**: Each query is timed with `EXPLAIN (ANALYZE, BUFFERS)` reading the `Execution Time` line. Write queries (`W01`–`W05`) are automatically wrapped in `BEGIN; ... ROLLBACK;` by `benchmarks/run_benchmark.sh` so the dataset never mutates.
* **No Configuration Hacks**: Default PostgreSQL 18.4 settings were preserved throughout (`enable_seqscan` untouched, `work_mem` untouched, `TimeZone = Asia/Kolkata`, no external caching).
* **Metrics**:
  * Average execution time = arithmetic mean of the runs (`3` runs for baseline, `5` runs for optimized) as written by `run_benchmark.sh`.
  * $\text{Improvement \%} = \frac{\text{Baseline Avg} - \text{Optimized Avg}}{\text{Baseline Avg}} \times 100$ (positive = faster, negative = slower).
* **Interpretation Caveat**: Because the baseline used 3 runs and the optimized benchmark used 5 runs, and because the entire database fits in 16 GB RAM, small deltas (under ~1 ms or ±5%) reflect normal warm-cache and OS scheduling variance rather than structural plan changes.

---

## G. Complete Performance Comparison (All 30 Queries)

All timings below are taken directly from `benchmarks/results/baseline/summary.csv` and `benchmarks/results/optimized/summary.csv`.

| Query | Type | Baseline Avg (ms) | Optimized Avg (ms) | Time Saved (ms) | Improvement (%) | Same Result? / Status | Problem Found in Baseline Plan | Optimization Applied |
|---|---|---:|---:|---:|---:|---|---|---|
| **R01** | READ | 0.082 | 0.073 | +0.009 | +10.98% | ✅ Faster *(noise)* | Small-table Seq Scan (60 `services`, 10 categories) | None needed (already <0.1 ms) |
| **R02** | READ | 11.815 | 0.675 | +11.140 | +94.29% | ✅ Faster (17.5×) | Parallel Seq Scan on 150k `bookings` + Seq Scan on `pro_skills` | `idx_pro_skills_category_pro`, `idx_pro_availability_date_pro`, `idx_bookings_active_pro_sched` |
| **R03** | READ | 6.345 | 0.112 | +6.233 | +98.23% | ✅ Faster (56.7×) | Seq Scan on 150k `bookings` + Sort | `idx_bookings_customer_sched` |
| **R04** | READ | 4.512 | 0.055 | +4.457 | +98.78% | ✅ Faster (82.0×) | Non-sargable `DATE(scheduled_start)` + Seq Scan on 150k `bookings` | Half-open range rewrite + `idx_bookings_pro_sched` |
| **R05** | READ | 7.394 | 0.069 | +7.325 | +99.07% | ✅ Faster (107.2×) | Seq Scan on 150k `bookings` for 46 `REQUESTED` rows | Partial index `idx_bookings_requested_id_sched` |
| **R06** | READ | 7.278 | 0.023 | +7.255 | +99.68% | ✅ Faster (316.4×) | Seq Scan on 40,000 `customers` | Non-unique B-tree `idx_customers_phone` |
| **R07** | READ | 4.921 | 0.183 | +4.738 | +96.28% | ✅ Faster (26.9×) | Parallel Seq Scan on 150k `bookings` | `idx_bookings_pro_sched` (Bitmap Index Scan) |
| **R08** | READ | 1.480 | 0.559 | +0.921 | +62.23% | ✅ Faster (2.6×) | Seq Scan on 27,015 `payouts` + Sort | Partial index `idx_payouts_pending_week_net` |
| **R09** | READ | 6.176 | 2.019 | +4.157 | +67.31% | ✅ Faster (3.1×) | Seq Scan on 150k `bookings` for June completed jobs | `idx_bookings_status_sched` (Bitmap Index Scan) |
| **R10** | READ | 17.711 | 16.908 | +0.803 | +4.53% | ✅ Approx. unchanged | Seq Scan on 95.9% of `bookings` (`pro_id IS NOT NULL`) | None (Seq Scan optimal for 96% table scan) |
| **R11** | READ | 0.704 | 0.476 | +0.228 | +32.39% | ✅ Faster (1.5×) | Seq Scan on 5,391 `reschedules` (95% filtered out) | `idx_reschedules_created_at` |
| **R12** | READ | 8.160 | 4.773 | +3.387 | +41.51% | ✅ Faster (1.7×) | Non-sargable `EXTRACT(YEAR)` + Parallel Seq Scan on 150k `bookings` | Half-open range rewrite + `idx_bookings_booked_at_desc` |
| **R13** | READ | 8.203 | 0.659 | +7.544 | +91.97% | 🔧 **Logical bug fix** *(0 → 377 rows)* | `NOT IN` NULL bug (returned 0 rows) + Seq Scan on 150k `bookings` | `NOT EXISTS` rewrite + partial `idx_bookings_cancelled_cust` |
| **R14** | READ | 20.394 | 19.408 | +0.986 | +4.83% | ✅ Approx. unchanged | Seq Scan on `bookings` (`city_id = 1`, 23,919 rows) + Sort/Group | None (broad multi-column grouping; Seq Scan appropriate) |
| **R15** | READ | 12.651 | 12.543 | +0.108 | +0.85% | ✅ Approx. unchanged | Hash Join dominated by 150k `bookings` Seq Scan (~75% of runtime) | None (`reviews(created_at)` intentionally excluded) |
| **R16** | READ | 4.855 | 0.640 | +4.215 | +86.82% | ✅ Faster (7.6×) | Parallel Seq Scan on 150k `bookings` for June rows (5.5%) | `idx_bookings_booked_at_desc` |
| **R17** | READ | 14.861 | 12.669 | +2.192 | +14.75% | ✅ Faster (1.2×) | Seq Scan on 150k `bookings` for 2026 completed rows | `idx_bookings_booked_at_desc` (skips 2025 rows) |
| **R18** | READ | 28.476 | 4.180 | +24.296 | +85.32% | ✅ Faster (6.8×) | Seq Scan on 76,539 `reviews` with `ILIKE '%late%'` | `pg_trgm` GIN index `idx_reviews_comment_trgm` |
| **R19** | READ | 3,381.296 | 11.504 | +3,369.792 | +99.66% | ✅ Faster (293.9×) | Two correlated subqueries executing 714 full `bookings` Seq Scans | Single-pass pre-aggregated `LEFT JOIN` rewrite |
| **R20** | READ | 9.099 | 1.462 | +7.637 | +83.93% | ✅ Faster (6.2×) | Non-sargable `scheduled_start::date` + Seq Scan on 150k `bookings` | Half-open range rewrite + `idx_bookings_status_sched` |
| **R21** | READ | 14.238 | 14.501 | −0.263 | −1.85% | ✅ Approx. unchanged *(slight variance)* | Parallel Seq Scan on 127,692 `COMPLETED` bookings (85.1%) | None (Seq Scan optimal for 85% table compliance scan) |
| **R22** | READ | 30.593 | 8.950 | +21.643 | +70.74% | ✅ Faster (3.4×) | Seq Scan on 150k `bookings` + **6,408 kB external disk sort** | `idx_bookings_booked_at_desc` (eliminated disk sort) |
| **R23** | READ | 0.049 | 0.043 | +0.006 | +12.24% | ✅ Faster *(noise)* | Already PK lookup (`bookings_pkey`) | None needed |
| **R24** | READ | 9.562 | 4.980 | +4.582 | +47.92% | ✅ Faster (1.9×) | Seq Scan on 150k `bookings` | PG18 B-tree skip scan on `idx_bookings_status_sched` |
| **R25** | READ | 2,089.105 | 2.595 | +2,086.510 | +99.88% | ✅ Faster (805.1×) | 5.3M-row nested-loop filter + 357 correlated `bookings` Seq Scans | Dual-CTE rewrite + `idx_pro_availability_date_pro` + `idx_bookings_status_sched` |
| **W01** | WRITE | 1.094 | 0.612 | +0.482 | +44.06% | ✅ Faster *(warm cache; higher buffer hits)* | Single-row `INSERT` | Unchanged SQL (incurs B-tree maintenance: `51 → 188` buffers) |
| **W02** | WRITE | 11.329 | 0.413 | +10.916 | +96.35% | ✅ Faster (27.4×) | `bookings_pkey` scan discarding `148,818` rows for `MIN(booking_id)` | Partial index `idx_bookings_requested_id_sched` (Index Only Scan) |
| **W03** | WRITE | 6.694 | 0.170 | +6.524 | +97.46% | ✅ Faster (39.4×) | Full 150k-row Seq Scan to update 1 assigned job | Partial index `idx_bookings_active_pro_sched` |
| **W04** | WRITE | 8.920 | 8.401 | +0.519 | +5.82% | ✅ Approx. unchanged | Seq Scan on 150k `bookings` (`completed_at`) + 401 payout inserts | Unchanged SQL (`completed_at` index deliberately excluded) |
| **W05** | WRITE | 7.763 | 1.628 | +6.135 | +79.03% | ✅ Faster (4.8×) | Full 150k-row Seq Scan to update 154 expired assigned jobs | Partial index `idx_bookings_assigned_unstarted` |
| **READ Subtotal** | 25 READ | **5,699.960** | **120.059** | **+5,579.901** | **+97.89%** | **47.5× faster** | *(Avg per READ query: `227.998 ms → 4.802 ms`)* | |
| **WRITE Subtotal** | 5 WRITE | **35.800** | **11.224** | **+24.576** | **+68.65%** | **3.2× faster** | *(Avg per WRITE query: `7.160 ms → 2.245 ms`)* | |
| **TOTAL (All 30)** | **30** | **5,735.760** | **131.283** | **+5,604.477** | **+97.71%** | **43.7× faster** | *(Avg across all 30 queries: `191.192 ms → 4.376 ms`)* | |

---

## H. Performance Analysis & Before/After Execution Plans

### 1. Five Biggest READ Improvements

* **By Percentage Improvement**:
  1. `R25`: `2,089.105 → 2.595 ms` (**+99.88%**, **805.1×**)
  2. `R06`: `7.278 → 0.023 ms` (**+99.68%**, **316.4×**)
  3. `R19`: `3,381.296 → 11.504 ms` (**+99.66%**, **293.9×**)
  4. `R05`: `7.394 → 0.069 ms` (**+99.07%**, **107.2×**)
  5. `R04`: `4.512 → 0.055 ms` (**+98.78%**, **82.0×**)
* **By Absolute Time Saved**:
  1. `R19`: **3,369.792 ms** saved (`3,381.296 → 11.504 ms`)
  2. `R25`: **2,086.510 ms** saved (`2,089.105 → 2.595 ms`)
  3. `R18`: **24.296 ms** saved (`28.476 → 4.180 ms`)
  4. `R22`: **21.643 ms** saved (`30.593 → 8.950 ms`)
  5. `R02`: **11.140 ms** saved (`11.815 → 0.675 ms`)

### 2. Condensed Before/After `EXPLAIN (ANALYZE, BUFFERS)` Plans (Top 5 Improvements by Time Saved)

#### Improvement 1: `R19` (`3,381.296 ms → 11.504 ms`, +99.66%, 293.9×)
* **Before (`benchmarks/results/baseline/R19.txt`, run 1)**:
  ```text
  Sort  (cost=3537011.99..3537012.87 rows=355 width=32) (actual time=3488.755..3488.765 rows=357.00 loops=1)
    Buffers: shared hit=1816446
    ->  Seq Scan on professionals p  (actual time=11.595..3488.543 rows=357.00 loops=1)
          Filter: ((city_id = 1) AND ((status)::text = 'ACTIVE'::text))
          SubPlan 1 -> Aggregate (actual time=5.681..5.681 rows=1.00 loops=357)
            -> Seq Scan on bookings b (Rows Removed by Filter: 149997, Buffers: shared hit=908208)
          SubPlan 2 -> Aggregate (actual time=4.089..4.089 rows=1.00 loops=357)
            -> Seq Scan on bookings b_1 (Rows Removed by Filter: 149936, Buffers: shared hit=908208)
  Execution Time: 3488.950 ms
  ```
* **After (`benchmarks/results/optimized/R19.txt`, run 1)**:
  ```text
  Sort  (cost=6252.18..6253.07 rows=355 width=32) (actual time=11.240..11.400 rows=357.00 loops=1)
    Buffers: shared hit=2574
    ->  Hash Right Join  (actual time=11.048..11.367 rows=357.00 loops=1)
          Hash Cond: (bookings.pro_id = p.pro_id)
          ->  Finalize HashAggregate  (actual time=10.923..11.164 rows=2220.00 loops=1)
                ->  Gather (Workers Launched: 1) -> Partial HashAggregate
                      -> Parallel Seq Scan on bookings (Filter: pro_id IS NOT NULL, Buffers: shared hit=2544)
          ->  Hash -> Seq Scan on professionals p (Filter: city_id = 1 AND status = 'ACTIVE', Buffers: shared hit=27)
  Execution Time: 11.458 ms
  ```

#### Improvement 2: `R25` (`2,089.105 ms → 2.595 ms`, +99.88%, 805.1×)
* **Before (`benchmarks/results/baseline/R25.txt`, run 1)**:
  ```text
  Limit  (cost=12007616.44..12007616.52 rows=30 width=68) (actual time=2073.877..2073.879 rows=30.00 loops=1)
    Buffers: shared hit=908695
    ->  Sort -> GroupAggregate (Group Key: a.pro_id, rows=357.00)
          ->  Nested Loop (actual time=0.015..216.497 rows=2142.00 loops=1)
                Join Filter: (a.pro_id = p.pro_id)
                Rows Removed by Join Filter: 5325858
                -> Index Scan using professionals_pkey on professionals p (Filter: city_id = 1)
                -> Materialize -> Seq Scan on pro_availability a (Rows Removed by Filter: 57087)
          SubPlan 1 -> Aggregate (actual time=5.201..5.201 rows=1.00 loops=357)
            -> Seq Scan on bookings b (Rows Removed by Filter: 149999, Buffers: shared hit=908208)
  Execution Time: 2073.924 ms
  ```
* **After (`benchmarks/results/optimized/R25.txt`, run 1)**:
  ```text
  Limit  (cost=3502.63..3502.71 rows=30 width=68) (actual time=2.687..2.689 rows=30.00 loops=1)
    Buffers: shared hit=576
    ->  Sort -> Hash Left Join (Hash Cond: a.pro_id = booked.pro_id, rows=357.00)
          ->  HashAggregate (Group Key: a.pro_id, rows=357.00)
                ->  Hash Join (Hash Cond: a.pro_id = p.pro_id, rows=2142.00)
                      -> Bitmap Heap Scan on pro_availability a (Heap Blocks: exact=449)
                           -> Bitmap Index Scan on idx_pro_availability_date_pro (rows=13320.00)
                      -> Hash -> Seq Scan on professionals p (Filter: city_id = 1, rows=400.00)
          ->  Hash -> Subquery Scan on booked -> HashAggregate (Group Key: b.pro_id, rows=1080.00)
                -> Bitmap Heap Scan on bookings b (Heap Blocks: exact=53)
                     -> Bitmap Index Scan on idx_bookings_status_sched (rows=1638.00, Buffers: shared hit=6)
  Execution Time: 2.743 ms
  ```

#### Improvement 3: `R18` (`28.476 ms → 4.180 ms`, +85.32%, 6.8×)
* **Before (`benchmarks/results/baseline/R18.txt`, run 1)**:
  ```text
  Limit  (cost=1790.29..1790.41 rows=50 width=40) (actual time=15.015..15.018 rows=50.00 loops=1)
    Buffers: shared hit=579
    ->  Sort (Sort Key: created_at DESC, Sort Method: top-N heapsort Memory: 32kB)
          ->  Seq Scan on reviews r (actual time=0.007..14.432 rows=7772.00 loops=1)
                Filter: (comment ~~* '%late%'::text)
                Rows Removed by Filter: 68767
  Execution Time: 15.031 ms   (avg across 3 runs: 28.476 ms)
  ```
* **After (`benchmarks/results/optimized/R18.txt`, run 1)**:
  ```text
  Limit  (cost=992.53..992.65 rows=50 width=40) (actual time=3.987..3.990 rows=50.00 loops=1)
    Buffers: shared hit=561
    ->  Sort (Sort Key: created_at DESC, Sort Method: top-N heapsort Memory: 32kB)
          ->  Bitmap Heap Scan on reviews r (actual time=0.368..3.430 rows=7772.00 loops=1)
                Recheck Cond: (comment ~~* '%late%'::text)
                Heap Blocks: exact=548
                ->  Bitmap Index Scan on idx_reviews_comment_trgm (actual time=0.334..0.335 rows=7772.00 loops=1)
                      Index Cond: (comment ~~* '%late%'::text)
                      Buffers: shared hit=10
  Execution Time: 4.035 ms    (avg across 5 runs: 4.180 ms)
  ```

#### Improvement 4: `R22` (`30.593 ms → 8.950 ms`, +70.74%, 3.4× — Eliminated Disk Sort)
* **Before (`benchmarks/results/baseline/R22.txt`, run 1)**:
  ```text
  Limit  (cost=20780.95..20781.01 rows=25 width=31) (actual time=29.927..29.929 rows=25.00 loops=1)
    Buffers: shared hit=2547, temp read=690 written=804
    ->  Sort  (cost=20530.95..20905.95 rows=150000 width=31) (actual time=25.073..28.206 rows=100025.00 loops=1)
          Sort Key: booked_at DESC
          Sort Method: external merge  Disk: 6408kB
          ->  Seq Scan on bookings (actual time=0.006..8.796 rows=150000.00 loops=1)
  Execution Time: 31.355 ms
  ```
* **After (`benchmarks/results/optimized/R22.txt`, run 1)**:
  ```text
  Limit  (cost=4307.59..4308.66 rows=25 width=31) (actual time=9.091..9.093 rows=25.00 loops=1)
    Buffers: shared hit=2058
    ->  Index Scan using idx_bookings_booked_at_desc on bookings (actual time=0.012..7.489 rows=100025.00 loops=1)
          Index Searches: 1
          Buffers: shared hit=2058
  Execution Time: 9.105 ms
  ```
  *Analysis*: `idx_bookings_booked_at_desc` completely removed the `Sort` node and eliminated `6,408 kB` of temporary disk spill (`temp read=0 written=0`). Remaining cost (`~8.95 ms`) comes from walking `100,025` tuples in `OFFSET 100000` (which can only be reduced further via keyset pagination if application semantics permit changing the query contract).

#### Improvement 5: `R02` (`11.815 ms → 0.675 ms`, +94.29%, 17.5×)
* **Before (`benchmarks/results/baseline/R02.txt`, run 1)**:
  ```text
  Limit -> Sort -> Nested Loop Anti Join (Buffers: shared hit=5410)
    -> Nested Loop (pro_skills Seq Scan -> professionals_pkey -> pro_availability_pkey)
    -> Materialize -> Gather -> Parallel Seq Scan on bookings b (Rows Removed by Filter: 74992/worker, Buffers: shared hit=2547)
  Execution Time: 19.087 ms   (avg across 3 runs: 11.815 ms)
  ```
* **After (`benchmarks/results/optimized/R02.txt`, run 1)**:
  ```text
  Limit -> Sort -> Nested Loop Anti Join (Buffers: shared hit=576)
    -> Nested Loop
          -> Hash Join
                -> Nested Loop (service_categories Seq Scan -> Index Only Scan using idx_pro_skills_category_pro, Heap Fetches: 0)
                -> Hash -> Seq Scan on professionals p
          -> Index Scan using idx_pro_availability_date_pro (Index Cond: work_date = '2026-07-03' AND pro_id = ps.pro_id)
    -> Index Only Scan using idx_bookings_active_pro_sched (Heap Fetches: 0, Index Searches: 98, Buffers: shared hit=208)
  Execution Time: 0.848 ms    (avg across 5 runs: 0.675 ms)
  ```

### 3. Confirmed PostgreSQL 18 B-Tree Skip Scan (`R24`)
Although `idx_bookings_status_sched` leads with `status` and `R24` does not filter on `status`, `benchmarks/results/optimized/R24.txt` confirms PostgreSQL 18's B-tree skip scan executed `5` index searches across the distinct `status` prefixes to evaluate `scheduled_start >= '2026-01-01'`:
```text
->  Bitmap Heap Scan on bookings  (Heap Blocks: exact=873, Buffers: shared hit=987)
      Recheck Cond: (scheduled_start >= '2026-01-01 00:00:00+05:30'::timestamp with time zone)
      Filter: (cancellation_fee > '0'::numeric)
      ->  Bitmap Index Scan on idx_bookings_status_sched  (actual time=1.412..1.412 rows=50361.00 loops=1)
            Index Cond: (scheduled_start >= '2026-01-01 00:00:00+05:30'::timestamp with time zone)
            Index Searches: 5
            Buffers: shared hit=114
```
This reduced `R24`'s heap blocks from `2,544` to `873` and cut average runtime from **9.562 ms → 4.980 ms** (**+47.92%**).

### 4. Queries That Did Not Meaningfully Improve & `R21`'s Small Variance
* **`R10`** (`17.711 → 16.908 ms`, `+4.53%`): Reads `143,858 / 150,000` rows (`95.9%` of `bookings` where `pro_id IS NOT NULL`) to compute no-show rates per professional. Sequential scan is mathematically optimal when touching ~96% of a table.
* **`R14`** (`20.394 → 19.408 ms`, `+4.83%`): Aggregates `23,919` Bengaluru bookings (`15.9%` of table) across all dates by `(category_id, ISODOW, HOUR)`. Hash join and sort/group across ~24k rows dominate execution time; sequential scan remains appropriate.
* **`R15`** (`12.651 → 12.543 ms`, `+0.85%`): Joins `4,265` June reviews to `bookings` (`150,000` rows). Because PostgreSQL chooses a Hash Join with a Seq Scan on `bookings` (~75% of runtime), leaving `reviews(created_at)` unindexed avoided unnecessary index storage for negligible benefit.
* **`R21`** (`14.238 → 14.501 ms`, **−1.85% / +0.263 ms**): The only negative delta in the workload. `R21` must inspect all `127,692` `COMPLETED` bookings (`85.1%` of `bookings`) in a compliance anti-join against `pro_skills`. Both baseline and optimized use the exact same `Parallel Seq Scan on bookings` + `Hash Anti Join` plan; the `0.263 ms` difference is routine run-to-run scheduling variance.

---

## I. Write Performance and Index Overhead

Secondary indexes are never free on writes; every write query must be evaluated on both **lookup cost saved** and **index maintenance added**:

| Query | Baseline Avg (ms) | Optimized Avg (ms) | Improvement (%) | Baseline Run 1 Buffers | Optimized Run 1 Buffers | Write-Overhead Analysis |
|---|---:|---:|---:|---|---|---|
| **W01** (`INSERT` booking) | 1.094 | 0.612 | +44.06% | `shared hit=51 dirtied=3` | `shared hit=188 dirtied=4` | **Real index maintenance cost**: Buffer hits more than tripled (`51 → 188`) because inserting a `'REQUESTED'` booking updates the 4 full `bookings` indexes plus `idx_bookings_requested_id_sched` (while skipping the 3 other partial indexes). Wall-clock time was slightly lower on warm cache, but CPU/buffer overhead per insert increased—acceptable given sub-millisecond latency (`0.612 ms`). |
| **W02** (`UPDATE` assign oldest `REQUESTED`) | 11.329 | 0.413 | +96.35% | `shared hit=2982 dirtied=3` | `shared hit=56 dirtied=5` | Row leaves `idx_bookings_requested_id_sched` and enters `idx_bookings_active_pro_sched` & `idx_bookings_assigned_unstarted` (`dirtied 3 → 5`), but replacing the 148,818-row `bookings_pkey` scan with a 3-buffer Index Only Scan yielded a **27.4× net speedup**. |
| **W03** (`UPDATE` complete job) | 6.694 | 0.170 | +97.46% | `shared hit=2579 dirtied=3` | `shared hit=43 dirtied=3` | Row leaves `idx_bookings_active_pro_sched` and `idx_bookings_assigned_unstarted` and updates `idx_bookings_status_sched`, but replacing a 150k-row Seq Scan with a 3-buffer Index Scan yielded a **39.4× net speedup**. |
| **W04** (`INSERT` weekly payouts) | 8.920 | 8.401 | +5.82% | `shared hit=3789 dirtied=10` | `shared hit=4860 dirtied=14` | Still uses `Seq Scan on bookings` because we deliberately avoided creating an extra 85%-table `bookings(completed_at)` index solely for this weekly batch job. Extra buffer hits (`3,789 → 4,860`) come from inserting 401 new `'PENDING'` rows into `idx_payouts_pending_week_net`. |
| **W05** (`UPDATE` mark 154 `NO_SHOW`) | 7.763 | 1.628 | +79.03% | `shared hit=3887 dirtied=88` | `shared hit=3038 dirtied=269` | Updating 154 rows from `'ASSIGNED'` to `'NO_SHOW'` dirtied more index pages (`88 → 269`) as rows left `idx_bookings_assigned_unstarted` and `idx_bookings_active_pro_sched` and updated `idx_bookings_status_sched`, yet eliminating the 150k-row Seq Scan produced a **4.8× net speedup**. |

---

## J. Limitations and Observations

1. **Baseline vs. Optimized Run-Count Asymmetry**: Baseline timings come from `3` runs (CP2), whereas optimized timings come from `5` runs per the CP3 README requirement. No formal statistical significance test was performed; small differences (such as `R01`, `R21`, `R23`, `W04`) should be interpreted as normal warm-cache variance.
2. **Warm-Cache Effects on 16 GB RAM**: The full database (~36 MB heap + ~20 MB new indexes) fits comfortably in memory, eliminating physical disk reads (`shared read=0` on warm runs) except for `R22`'s baseline temp disk spill. Real-world cold-cache speedups from index-only and narrow-range scans would be even more pronounced at larger scale.
3. **`R13` Semantic Difference**: `R13`'s baseline (`8.203 ms`, `0` rows) and optimized (`0.659 ms`, `377` rows) versions do not produce the same output because the original query suffered from a `NOT IN (NULL)` logic bug. Its improvement must be evaluated primarily as a **correctness fix** that also runs 12.4× faster.
4. **`R25` Tied Rows at `LIMIT 30` Boundary**: Both `rank 30` and `rank 31` have `booked_min = 225.0000000000000000` minutes, and the original workload specifies `ORDER BY booked_min DESC LIMIT 30` without a secondary tie-breaker (e.g., `pro_id`). While both the full 357-row set and the top-30 returned rows matched with `0` differences in our validation, any future dataset or plan change could break a tie at rank 30 differently unless a deterministic tie-breaker is added to the specification.
5. **Single-Table Deep Pagination (`R22`)**: `idx_bookings_booked_at_desc` eliminated the `6,408 kB` disk sort (`30.593 → 8.950 ms`), but `OFFSET 100000` still scans `100,025` rows sequentially. At 20× dataset growth (Phase 5), maintaining interactive latency will favor keyset pagination if query-contract changes are permitted.

---

## K. Conclusion

All CP3 optimization objectives were achieved with measurable, verified evidence:

* **14** targeted, valid indexes (`20 MB` total; 6 supporting-table + 8 `bookings`, including 4 lightweight partial indexes) were created via `sql/05_indexes.sql`, and **100% (14/14)** were utilized by PostgreSQL's planner.
* **6** justified SQL rewrites were implemented in `sql/06_optimized_queries.sql` (`R04`, `R12`, `R13`, `R19`, `R20`, `R25`), eliminating $N+1$ correlated scans, restoring sargability without hardcoding timezone offsets, and fixing `R13`'s `NOT IN (NULL)` bug (`0 → 377` rows).
* Across the 30-query workload, total execution time dropped from **5,735.760 ms** to **131.283 ms** (**+97.71%**, **43.7× faster**), with READ queries improving **+97.89%** (**47.5×**) and WRITE queries improving **+68.65%** (**3.2×**) with zero significant regressions.
* Accepted trade-offs—higher index-maintenance buffer hits on `W01` (`51 → 188`), extra dirtied pages on `W05` (`88 → 269`), `20 MB` of index storage, and deliberately keeping sequential scans on broad full-table analytics (`R10`, `R14`, `R15`, `R21`, `W04`)—keep the schema lean and well-balanced ahead of Phase 5 scalability testing.
