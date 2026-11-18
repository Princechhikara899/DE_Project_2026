-- ============================================================================
-- Urban Company Home Services Database - CP3 (Phase 4: Query Optimization)
-- File: sql/05_indexes.sql
--
-- Total Indexes: 14 (6 supporting-table indexes + 8 bookings indexes)
-- Target Schema: public (matching sql/01_schema.sql and run_benchmark.sh)
-- ============================================================================

SET search_path TO public;

-- ============================================================================
-- PART 1: SUPPORTING-TABLE INDEXES (6)
-- ============================================================================

-- 1. idx_customers_phone
--    Target queries : R06 (Customer support: look up customer by mobile number)
--    Index type     : Full non-unique B-tree index
--    Column order   : (phone) — single equality predicate in R06. Kept NON-UNIQUE
--                     because sql/01_schema.sql does not declare phone as UNIQUE.
--    PK overlap     : None (customers_pkey is on customer_id).
--    Write overhead : None in W01-W05 (no benchmark writes to customers).
CREATE INDEX idx_customers_phone
    ON customers (phone);

-- 2. idx_pro_skills_category_pro
--    Target queries : R02 (Slot picker: professionals certified in a category)
--    Index type     : Full B-tree composite index
--    Column order   : (category_id, pro_id) — leading category_id enables direct
--                     lookup by service category, with pro_id available for join.
--    PK overlap     : Inverse of pro_skills_pkey (pro_id, category_id); needed
--                     because pro_skills_pkey cannot seek on category_id alone.
--    Write overhead : None in W01-W05 (no benchmark writes to pro_skills).
CREATE INDEX idx_pro_skills_category_pro
    ON pro_skills (category_id, pro_id);

-- 3. idx_pro_availability_date_pro
--    Target queries : R25 (Weekly utilisation), R02 (Slot picker by work_date)
--    Index type     : Full B-tree composite index
--    Column order   : (work_date, pro_id) — leading work_date serves the date
--                     range filter in R25 (eliminating the 70k-row Seq Scan and
--                     5.3M-row nested loop join filter) and equality date in R02.
--    PK overlap     : Reordered prefix of pro_availability_pkey (pro_id, work_date,
--                     start_time); needed when filtering by work_date first.
--    Write overhead : None in W01-W05 (no benchmark writes to pro_availability).
CREATE INDEX idx_pro_availability_date_pro
    ON pro_availability (work_date, pro_id);

-- 4. idx_payouts_pending_week_net
--    Target queries : R08 (Finance: pending payouts for a week, highest first)
--    Index type     : Partial B-tree composite index (WHERE status = 'PENDING')
--    Column order   : (week_start, net_payout DESC) — equality on week_start first,
--                     then net_payout DESC to match ORDER BY po.net_payout DESC.
--                     Partial predicate indexes only the ~4% PENDING rows.
--    PK overlap     : None (payouts_pkey is on payout_id).
--    Write overhead : Maintained during W04 (inserts ~401 PENDING payout rows into
--                     a small partial index); zero cost for PAID rows.
CREATE INDEX idx_payouts_pending_week_net
    ON payouts (week_start, net_payout DESC)
    WHERE status = 'PENDING';

-- 5. idx_reschedules_created_at
--    Target queries : R11 (Operations: most rescheduled services in June 2026)
--    Index type     : Full B-tree index
--    Column order   : (created_at) — supports range filter on created_at, skipping
--                     ~95% of reschedules outside the target month.
--    PK overlap     : None (reschedules_pkey is on reschedule_id).
--    Write overhead : None in W01-W05 (no benchmark writes to reschedules).
CREATE INDEX idx_reschedules_created_at
    ON reschedules (created_at);

-- 6. idx_reviews_comment_trgm
--    Target queries : R18 (Quality: newest reviews complaining about lateness)
--    Index type     : Full GIN trigram index (requires pg_trgm extension)
--    Column order   : (comment gin_trgm_ops) — supports leading-wildcard
--                     ILIKE '%late%' substring matching where B-tree cannot be used.
--    PK overlap     : None (reviews_pkey is on booking_id).
--    Write overhead : None in W01-W05 (no benchmark writes to reviews); in general
--                     OLTP, GIN trigram inserts/updates are heavier than B-tree.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX idx_reviews_comment_trgm
    ON reviews USING gin (comment gin_trgm_ops);


-- ============================================================================
-- PART 2: BOOKINGS TABLE INDEXES (8: 4 FULL B-TREE + 4 PARTIAL B-TREE)
-- ============================================================================

-- 7. idx_bookings_pro_sched
--    Target queries : R04 (Pro daily jobs), R07 (Pro weekly earnings)
--    Index type     : Full B-tree composite index
--    Column order   : (pro_id, scheduled_start) — equality on pro_id first, then
--                     range/sort on scheduled_start for R04; narrows R07 to a
--                     single professional's bookings (~60 rows).
--    PK overlap     : None (bookings_pkey is on booking_id). Partially overlaps
--                     with idx_bookings_active_pro_sched (index #12), which is a
--                     tiny active-only partial index used by R02 and W03.
--    Write overhead : Maintained on W01 (INSERT) and W02 (pro_id changes NULL->425).
CREATE INDEX idx_bookings_pro_sched
    ON bookings (pro_id, scheduled_start);

-- 8. idx_bookings_customer_sched
--    Target queries : R03 ("My bookings": customer's upcoming bookings)
--    Index type     : Full B-tree composite index
--    Column order   : (customer_id, scheduled_start) — equality on customer_id
--                     first, then range/ordering on scheduled_start.
--    PK overlap     : None (bookings_pkey is on booking_id).
--    Write overhead : Maintained on W01 (INSERT); untouched by W02, W03, W05.
CREATE INDEX idx_bookings_customer_sched
    ON bookings (customer_id, scheduled_start);

-- 9. idx_bookings_booked_at_desc
--    Target queries : R22 (Support console deep pagination), R16 (June Mumbai
--                     pincodes), R12 (2026 UC Plus discounts after sargable rewrite),
--                     R17 (2026 repeat-category retention bookings)
--    Index type     : Full B-tree index
--    Column order   : (booked_at DESC) — matches ORDER BY booked_at DESC in R22
--                     (avoiding disk-spilling external sort) and supports range
--                     scans on booked_at for R16, R12, and R17.
--    PK overlap     : None (bookings_pkey is on booking_id).
--    Write overhead : Maintained on W01 (INSERT); untouched by W02, W03, W05.
CREATE INDEX idx_bookings_booked_at_desc
    ON bookings (booked_at DESC);

-- 10. idx_bookings_status_sched
--     Target queries : R09 (June late starts), R20 (June daily GMV after rewrite),
--                      R25 (Weekly completed booked minutes CTE)
--     Index type     : Full B-tree composite index
--     Column order   : (status, scheduled_start) — equality on status = 'COMPLETED'
--                      first, followed by date range on scheduled_start.
--     PK overlap     : None (bookings_pkey is on booking_id).
--     Write overhead : Maintained on W01 (INSERT) and status transitions in
--                      W02, W03, and W05.
CREATE INDEX idx_bookings_status_sched
    ON bookings (status, scheduled_start);

-- 11. idx_bookings_requested_id_sched
--     Target queries : W02 (Dispatch: oldest REQUESTED booking),
--                      R05 (Dispatch: requested jobs before noon)
--     Index type     : Partial B-tree composite index (WHERE status = 'REQUESTED')
--     Column order   : (booking_id, scheduled_start) — leading booking_id directly
--                      supports W02's MIN(booking_id) via a B-tree index seek.
--                      scheduled_start is the second column, so R05 can scan this
--                      small partial index (~84 rows in seed data) and filter its
--                      entries without touching non-matching heap rows, though it
--                      cannot perform a direct date-range seek on scheduled_start.
--     PK overlap     : Partial subset of bookings_pkey (booking_id) restricted to
--                      status = 'REQUESTED' so W02 avoids scanning 148k historical rows.
--     Write overhead : Row enters index on W01 (INSERT as REQUESTED) and leaves on
--                      W02 (UPDATE to ASSIGNED); untouched by W03, W04, W05.
CREATE INDEX idx_bookings_requested_id_sched
    ON bookings (booking_id, scheduled_start)
    WHERE status = 'REQUESTED';

-- 12. idx_bookings_active_pro_sched
--     Target queries : R02 (Slot picker clash check anti-join), W03 (Complete job)
--     Index type     : Partial B-tree composite index
--                      (WHERE status IN ('ASSIGNED', 'IN_PROGRESS'))
--     Column order   : (pro_id, scheduled_start, scheduled_end) — equality on
--                      pro_id, range on scheduled_start, plus scheduled_end to
--                      evaluate slot overlap directly within the tiny active subset
--                      (~359 rows in seed data) without scanning historical jobs.
--     PK overlap     : None (bookings_pkey is on booking_id). Narrow partial subset
--                      of idx_bookings_pro_sched (#7) plus scheduled_end.
--     Write overhead : Row enters on W02 (ASSIGNED) and leaves on W03 (COMPLETED)
--                      and W05 (NO_SHOW); untouched by W01 (REQUESTED).
CREATE INDEX idx_bookings_active_pro_sched
    ON bookings (pro_id, scheduled_start, scheduled_end)
    WHERE status IN ('ASSIGNED', 'IN_PROGRESS');

-- 13. idx_bookings_cancelled_cust
--     Target queries : R13 (Partner rewards: active pros with no customer
--                      cancellations, rewritten with NOT EXISTS)
--     Index type     : Partial B-tree index (WHERE status = 'CANCELLED_BY_CUSTOMER')
--     Column order   : (pro_id) — supports anti-join lookup by pro_id against only
--                      the ~8.1% customer-cancelled bookings (~12,123 rows).
--     PK overlap     : None (bookings_pkey is on booking_id).
--     Write overhead : Zero write cost in W01-W05 (none set CANCELLED_BY_CUSTOMER);
--                      in OLTP, maintained only when a booking is customer-cancelled.
CREATE INDEX idx_bookings_cancelled_cust
    ON bookings (pro_id)
    WHERE status = 'CANCELLED_BY_CUSTOMER';

-- 14. idx_bookings_assigned_unstarted
--     Target queries : W05 (Operations: mark expired unstarted ASSIGNED jobs NO_SHOW)
--     Index type     : Partial B-tree index
--                      (WHERE status = 'ASSIGNED' AND started_at IS NULL)
--     Column order   : (scheduled_end) — directly supports range predicate
--                      scheduled_end < '2026-07-02 00:00:00+05:30' on the tiny
--                      assigned-unstarted subset (<=359 rows in seed data).
--     PK overlap     : None (bookings_pkey is on booking_id). Distinct from #12
--                      because W05 filters by scheduled_end without pro_id.
--     Write overhead : Row enters on W02 (ASSIGNED with started_at IS NULL) and
--                      leaves on W03 (COMPLETED/started_at set) and W05 (NO_SHOW);
--                      untouched by W01.
CREATE INDEX idx_bookings_assigned_unstarted
    ON bookings (scheduled_end)
    WHERE status = 'ASSIGNED' AND started_at IS NULL;


-- Refresh planner statistics after index creation
ANALYZE;
