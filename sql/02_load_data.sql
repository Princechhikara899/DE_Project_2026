BEGIN;

-- 1. Cities
\copy cities (city_id, city_name, state) FROM 'seed_data/cities.csv' WITH (FORMAT CSV, HEADER TRUE);

-- 2. Customers
\copy customers (customer_id, full_name, phone, email, city_id, plus_valid_until, created_at) FROM 'seed_data/customers.csv' WITH (FORMAT CSV, HEADER TRUE);

-- 3. Professionals
\copy professionals (pro_id, full_name, phone, city_id, gender, joined_on, rating, kyc_verified, status) FROM 'seed_data/professionals.csv' WITH (FORMAT CSV, HEADER TRUE);

-- 4. Service categories
\copy service_categories (category_id, category_name) FROM 'seed_data/service_categories.csv' WITH (FORMAT CSV, HEADER TRUE);

-- 5. Services
\copy services (service_id, category_id, service_name, duration_min, base_price, is_active) FROM 'seed_data/services.csv' WITH (FORMAT CSV, HEADER TRUE);

-- 6. Bookings
\copy bookings (booking_id, customer_id, service_id, pro_id, city_id, pincode, booked_at, scheduled_start, scheduled_end, started_at, completed_at, status, price, discount, cancellation_fee, tip, payment_method) FROM 'seed_data/bookings.csv' WITH (FORMAT CSV, HEADER TRUE);

-- 7. Reviews
\copy reviews (booking_id, rating_for_pro, comment, rating_for_customer, created_at) FROM 'seed_data/reviews.csv' WITH (FORMAT CSV, HEADER TRUE);

-- 8. Reschedules
\copy reschedules (reschedule_id, booking_id, old_start, new_start, requested_by, reason, created_at) FROM 'seed_data/reschedules.csv' WITH (FORMAT CSV, HEADER TRUE);

-- 9. Payouts
\copy payouts (payout_id, pro_id, week_start, jobs, gross_earnings, commission, net_payout, status, paid_at) FROM 'seed_data/payouts.csv' WITH (FORMAT CSV, HEADER TRUE);

-- 10. Professional skills
\copy pro_skills (pro_id, category_id, certified_on) FROM 'seed_data/pro_skills.csv' WITH (FORMAT CSV, HEADER TRUE);

-- 11. Professional availability
\copy pro_availability (pro_id, work_date, start_time, end_time) FROM 'seed_data/pro_availability.csv' WITH (FORMAT CSV, HEADER TRUE);

COMMIT;
