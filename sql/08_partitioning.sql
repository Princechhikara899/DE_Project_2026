-- ============================================================================
-- CP4 (Phase 5) - Table Partitioning Strategy & DDL Implementation
-- Database: urban_company_db (PostgreSQL 18+)
-- Target Table: bookings (Scalability from 150k -> 3M -> 15M+ rows)
-- Partitioning Method: Declarative RANGE Partitioning on scheduled_start
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Architectural Justification & Partition Key Selection
-- ----------------------------------------------------------------------------
-- The `bookings` table is the primary transactional engine of Urban Company,
-- accounting for >85% of total database volume and IO throughput.
--
-- Why RANGE Partitioning on `scheduled_start`?
-- 1. Operational Locality: Real-time queries (dispatch, partner slot availability,
--    customer check-ins) exclusively target active windows (today, tomorrow, or
--    the current week).
-- 2. Partition Pruning: PostgreSQL's planner can instantly eliminate 95%+ of historical
--    partitions when queries provide temporal bounds (e.g., WHERE scheduled_start >= ...).
-- 3. Maintenance & Archival: Older quarterly partitions can be detached, compressed,
--    or moved to cold storage without locking the active operational dataset.
--
-- Primary Key Rule for Partitioned Tables:
-- In PostgreSQL declarative partitioning, any UNIQUE or PRIMARY KEY constraint
-- MUST include the partition key column (`scheduled_start`). Therefore, the primary
-- key is declared as a composite key: PRIMARY KEY (booking_id, scheduled_start).
-- ----------------------------------------------------------------------------

-- Drop partitioned table if already exists for clean idempotent execution
DROP TABLE IF EXISTS bookings_partitioned CASCADE;

-- ----------------------------------------------------------------------------
-- 2. Partitioned Master Table Definition
-- ----------------------------------------------------------------------------
CREATE TABLE bookings_partitioned (
    booking_id          INTEGER NOT NULL,
    customer_id         INTEGER NOT NULL,
    service_id          INTEGER NOT NULL,
    pro_id              INTEGER,
    city_id             INTEGER NOT NULL,
    pincode             VARCHAR(10) NOT NULL,
    booked_at           TIMESTAMPTZ NOT NULL,
    scheduled_start     TIMESTAMPTZ NOT NULL,
    scheduled_end       TIMESTAMPTZ NOT NULL,
    started_at          TIMESTAMPTZ,
    completed_at        TIMESTAMPTZ,
    status              VARCHAR(30) NOT NULL,
    price               NUMERIC(12,2) NOT NULL,
    discount            NUMERIC(12,2) NOT NULL,
    cancellation_fee    NUMERIC(12,2) NOT NULL,
    tip                 NUMERIC(12,2),
    payment_method      VARCHAR(20) NOT NULL,

    -- Composite Primary Key required by PostgreSQL declarative partitioning
    CONSTRAINT pk_bookings_partitioned 
        PRIMARY KEY (booking_id, scheduled_start),

    -- Foreign Key constraints
    CONSTRAINT fk_bookings_part_customer
        FOREIGN KEY (customer_id) REFERENCES customers(customer_id),

    CONSTRAINT fk_bookings_part_service
        FOREIGN KEY (service_id) REFERENCES services(service_id),

    CONSTRAINT fk_bookings_part_professional
        FOREIGN KEY (pro_id) REFERENCES professionals(pro_id)
) PARTITION BY RANGE (scheduled_start);

-- ----------------------------------------------------------------------------
-- 3. Quarterly Partition Ranges (2025 - 2027+)
-- ----------------------------------------------------------------------------

-- 2025 Partitions
CREATE TABLE bookings_2025_q1 PARTITION OF bookings_partitioned
    FOR VALUES FROM ('2025-01-01 00:00:00+05:30') TO ('2025-04-01 00:00:00+05:30');

CREATE TABLE bookings_2025_q2 PARTITION OF bookings_partitioned
    FOR VALUES FROM ('2025-04-01 00:00:00+05:30') TO ('2025-07-01 00:00:00+05:30');

CREATE TABLE bookings_2025_q3 PARTITION OF bookings_partitioned
    FOR VALUES FROM ('2025-07-01 00:00:00+05:30') TO ('2025-10-01 00:00:00+05:30');

CREATE TABLE bookings_2025_q4 PARTITION OF bookings_partitioned
    FOR VALUES FROM ('2025-10-01 00:00:00+05:30') TO ('2026-01-01 00:00:00+05:30');

-- 2026 Partitions (Current Operational Year)
CREATE TABLE bookings_2026_q1 PARTITION OF bookings_partitioned
    FOR VALUES FROM ('2026-01-01 00:00:00+05:30') TO ('2026-04-01 00:00:00+05:30');

CREATE TABLE bookings_2026_q2 PARTITION OF bookings_partitioned
    FOR VALUES FROM ('2026-04-01 00:00:00+05:30') TO ('2026-07-01 00:00:00+05:30');

CREATE TABLE bookings_2026_q3 PARTITION OF bookings_partitioned
    FOR VALUES FROM ('2026-07-01 00:00:00+05:30') TO ('2026-10-01 00:00:00+05:30');

CREATE TABLE bookings_2026_q4 PARTITION OF bookings_partitioned
    FOR VALUES FROM ('2026-10-01 00:00:00+05:30') TO ('2027-01-01 00:00:00+05:30');

-- Catch-all Default Partition for Future / Out-of-Range Data
CREATE TABLE bookings_default PARTITION OF bookings_partitioned DEFAULT;

-- ----------------------------------------------------------------------------
-- 4. Local Optimization Indexes on Partitioned Table
-- Indexes created on the master table are automatically cascaded to all existing
-- and future partitions in PostgreSQL 11+.
-- ----------------------------------------------------------------------------

-- Index for R03 ("My bookings" lookup by customer and date)
CREATE INDEX idx_part_bookings_customer_sched 
    ON bookings_partitioned (customer_id, scheduled_start);

-- Index for R04, R07 (Partner app: professional schedule)
CREATE INDEX idx_part_bookings_pro_sched 
    ON bookings_partitioned (pro_id, scheduled_start);

-- Index for R09, R10, R14, R15, R20, R21, R24 (Status and date filtering)
CREATE INDEX idx_part_bookings_status_sched 
    ON bookings_partitioned (status, scheduled_start);

-- Partial index for W02 (Dispatch unassigned queue)
CREATE INDEX idx_part_bookings_requested_id_sched 
    ON bookings_partitioned (booking_id, scheduled_start) 
    WHERE status = 'REQUESTED';

-- Partial index for W05 (Assigned unstarted reconciliation)
CREATE INDEX idx_part_bookings_assigned_unstarted 
    ON bookings_partitioned (scheduled_start) 
    WHERE status = 'ASSIGNED' AND started_at IS NULL;

-- Index for R12, R16, R17, R22 (Deep pagination and booked_at ordering)
CREATE INDEX idx_part_bookings_booked_at_desc 
    ON bookings_partitioned (booked_at DESC);

-- Partial index for R02, W03 (Active pro conflicting bookings)
CREATE INDEX idx_part_bookings_active_pro_sched 
    ON bookings_partitioned (pro_id, scheduled_start, scheduled_end) 
    WHERE status IN ('ASSIGNED', 'IN_PROGRESS');

-- ----------------------------------------------------------------------------
-- 5. Data Migration from Unpartitioned Table
-- ----------------------------------------------------------------------------
-- When transitioning in production:
-- INSERT INTO bookings_partitioned SELECT * FROM bookings;
-- ANALYZE bookings_partitioned;

-- ----------------------------------------------------------------------------
-- 6. Demonstration of Partition Pruning
-- ----------------------------------------------------------------------------
-- Ensure partition pruning is enabled (default in modern PostgreSQL)
SET enable_partition_pruning = on;

-- Example Query: Customer lookup for July 2026
-- Notice that PostgreSQL prunes away all partitions except `bookings_2026_q3`!
EXPLAIN (ANALYZE, BUFFERS)
SELECT booking_id, scheduled_start, status, price
FROM bookings_partitioned
WHERE customer_id = 226
  AND scheduled_start >= '2026-07-01 00:00:00+05:30'
  AND scheduled_start <  '2026-08-01 00:00:00+05:30';

-- Example Query: Slot collision check during July 2026
EXPLAIN (ANALYZE, BUFFERS)
SELECT booking_id
FROM bookings_partitioned
WHERE pro_id = 142
  AND status IN ('ASSIGNED', 'IN_PROGRESS')
  AND scheduled_start < '2026-07-03 12:30:00+05:30'
  AND scheduled_end   > '2026-07-03 11:00:00+05:30';
