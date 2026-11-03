BEGIN;

-- 1. Cities
CREATE TABLE cities (
    city_id INTEGER PRIMARY KEY,
    city_name VARCHAR(100) NOT NULL,
    state VARCHAR(100) NOT NULL
);

-- 2. Customers
CREATE TABLE customers (
    customer_id INTEGER PRIMARY KEY,
    full_name VARCHAR(150) NOT NULL,
    phone VARCHAR(20) NOT NULL,
    email VARCHAR(254),
    city_id INTEGER NOT NULL,
    plus_valid_until DATE,
    created_at TIMESTAMPTZ NOT NULL,

    CONSTRAINT fk_customers_city
        FOREIGN KEY (city_id) REFERENCES cities(city_id)
);

-- 3. Professionals
CREATE TABLE professionals (
    pro_id INTEGER PRIMARY KEY,
    full_name VARCHAR(150) NOT NULL,
    phone VARCHAR(20) NOT NULL,
    city_id INTEGER NOT NULL,
    gender CHAR(1) NOT NULL,
    joined_on DATE NOT NULL,
    rating NUMERIC(3,2),
    kyc_verified BOOLEAN NOT NULL,
    status VARCHAR(20) NOT NULL,

    CONSTRAINT fk_professionals_city
        FOREIGN KEY (city_id) REFERENCES cities(city_id),

    CONSTRAINT chk_professionals_gender
        CHECK (gender IN ('F', 'M')),

    CONSTRAINT chk_professionals_status
        CHECK (status IN ('ACTIVE', 'OFFBOARDED', 'SUSPENDED')),

    CONSTRAINT chk_professionals_rating
        CHECK (rating IS NULL OR (rating >= 0 AND rating <= 5))
);

-- 4. Service categories
CREATE TABLE service_categories (
    category_id INTEGER PRIMARY KEY,
    category_name VARCHAR(100) NOT NULL
);

-- 5. Services
CREATE TABLE services (
    service_id INTEGER PRIMARY KEY,
    category_id INTEGER NOT NULL,
    service_name VARCHAR(150) NOT NULL,
    duration_min INTEGER NOT NULL,
    base_price NUMERIC(12,2) NOT NULL,
    is_active BOOLEAN NOT NULL,

    CONSTRAINT fk_services_category
        FOREIGN KEY (category_id)
        REFERENCES service_categories(category_id),

    CONSTRAINT chk_services_duration
        CHECK (duration_min > 0),

    CONSTRAINT chk_services_base_price
        CHECK (base_price >= 0)
);

-- 6. Bookings
CREATE TABLE bookings (
    booking_id INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL,
    service_id INTEGER NOT NULL,
    pro_id INTEGER,
    city_id INTEGER NOT NULL,
    pincode VARCHAR(10) NOT NULL,
    booked_at TIMESTAMPTZ NOT NULL,
    scheduled_start TIMESTAMPTZ NOT NULL,
    scheduled_end TIMESTAMPTZ NOT NULL,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    status VARCHAR(30) NOT NULL,
    price NUMERIC(12,2) NOT NULL,
    discount NUMERIC(12,2) NOT NULL,
    cancellation_fee NUMERIC(12,2) NOT NULL,
    tip NUMERIC(12,2),
    payment_method VARCHAR(20) NOT NULL,

    CONSTRAINT fk_bookings_customer
        FOREIGN KEY (customer_id) REFERENCES customers(customer_id),

    CONSTRAINT fk_bookings_service
        FOREIGN KEY (service_id) REFERENCES services(service_id),

    CONSTRAINT fk_bookings_professional
        FOREIGN KEY (pro_id) REFERENCES professionals(pro_id),

    CONSTRAINT fk_bookings_city
        FOREIGN KEY (city_id) REFERENCES cities(city_id),

    CONSTRAINT chk_bookings_status
        CHECK (status IN (
            'REQUESTED',
            'ASSIGNED',
            'COMPLETED',
            'CANCELLED_BY_CUSTOMER',
            'CANCELLED_BY_PRO',
            'NO_SHOW'
        )),

    CONSTRAINT chk_bookings_payment_method
        CHECK (payment_method IN ('CARD', 'CASH', 'UPI', 'WALLET')),

    CONSTRAINT chk_bookings_amounts
        CHECK (
            price >= 0
            AND discount >= 0
            AND cancellation_fee >= 0
            AND (tip IS NULL OR tip >= 0)
        )
);

-- 7. Reviews
CREATE TABLE reviews (
    booking_id INTEGER PRIMARY KEY,
    rating_for_pro SMALLINT NOT NULL,
    comment TEXT,
    rating_for_customer SMALLINT,
    created_at TIMESTAMPTZ NOT NULL,

    CONSTRAINT fk_reviews_booking
        FOREIGN KEY (booking_id) REFERENCES bookings(booking_id),

    CONSTRAINT chk_reviews_pro_rating
        CHECK (rating_for_pro BETWEEN 1 AND 5),

    CONSTRAINT chk_reviews_customer_rating
        CHECK (
            rating_for_customer IS NULL
            OR rating_for_customer BETWEEN 1 AND 5
        )
);

-- 8. Reschedules
CREATE TABLE reschedules (
    reschedule_id INTEGER PRIMARY KEY,
    booking_id INTEGER NOT NULL,
    old_start TIMESTAMPTZ NOT NULL,
    new_start TIMESTAMPTZ NOT NULL,
    requested_by VARCHAR(20) NOT NULL,
    reason VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,

    CONSTRAINT fk_reschedules_booking
        FOREIGN KEY (booking_id) REFERENCES bookings(booking_id),

    CONSTRAINT chk_reschedules_requested_by
        CHECK (requested_by IN ('CUSTOMER', 'PRO'))
);

-- 9. Payouts
CREATE TABLE payouts (
    payout_id INTEGER PRIMARY KEY,
    pro_id INTEGER NOT NULL,
    week_start DATE NOT NULL,
    jobs INTEGER NOT NULL,
    gross_earnings NUMERIC(12,2) NOT NULL,
    commission NUMERIC(12,2) NOT NULL,
    net_payout NUMERIC(12,2) NOT NULL,
    status VARCHAR(20) NOT NULL,
    paid_at TIMESTAMPTZ,

    CONSTRAINT fk_payouts_professional
        FOREIGN KEY (pro_id) REFERENCES professionals(pro_id),

    CONSTRAINT chk_payouts_status
        CHECK (status IN ('PAID', 'PENDING')),

    CONSTRAINT chk_payouts_amounts
        CHECK (
            gross_earnings >= 0
            AND commission >= 0
            AND net_payout >= 0
        ),

    CONSTRAINT chk_payouts_jobs
        CHECK (jobs > 0)
);

-- 10. Professional skills (many-to-many bridge)
CREATE TABLE pro_skills (
    pro_id INTEGER NOT NULL,
    category_id INTEGER NOT NULL,
    certified_on DATE NOT NULL,

    PRIMARY KEY (pro_id, category_id),

    CONSTRAINT fk_pro_skills_professional
        FOREIGN KEY (pro_id) REFERENCES professionals(pro_id),

    CONSTRAINT fk_pro_skills_category
        FOREIGN KEY (category_id)
        REFERENCES service_categories(category_id)
);

-- 11. Professional availability
CREATE TABLE pro_availability (
    pro_id INTEGER NOT NULL,
    work_date DATE NOT NULL,
    start_time TIME NOT NULL,
    end_time TIME NOT NULL,

    PRIMARY KEY (pro_id, work_date, start_time),

    CONSTRAINT fk_pro_availability_professional
        FOREIGN KEY (pro_id) REFERENCES professionals(pro_id)
);

COMMIT;
