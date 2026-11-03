# Schema Design

## 1. Overview

The database models an urban home-services platform. It stores information about customers, service professionals, cities, service categories, services, bookings, reviews, reschedules, professional skills, professional availability, and payouts.

The schema is designed around the relationships observed in the supplied dataset.

## 2. Entities and Primary Keys

| Entity | Primary Key | Description |
|---|---|---|
| cities | city_id | Stores city and state information |
| customers | customer_id | Stores customer details |
| professionals | pro_id | Stores service professional details |
| service_categories | category_id | Stores service categories |
| services | service_id | Stores individual services |
| bookings | booking_id | Stores customer service bookings |
| reviews | booking_id | Stores reviews associated with bookings |
| reschedules | reschedule_id | Stores booking reschedule history |
| payouts | payout_id | Stores professional payout records |
| pro_skills | (pro_id, category_id) | Maps professionals to their certified service categories |
| pro_availability | (pro_id, work_date, start_time) | Stores professional availability slots |

## 3. Relationships and Foreign Keys

| Referencing Entity | Foreign Key | Referenced Entity | Relationship |
|---|---|---|---|
| customers | city_id | cities(city_id) | Many customers can belong to one city |
| professionals | city_id | cities(city_id) | Many professionals can belong to one city |
| services | category_id | service_categories(category_id) | One category can contain many services |
| bookings | customer_id | customers(customer_id) | One customer can make many bookings |
| bookings | service_id | services(service_id) | One service can appear in many bookings |
| bookings | pro_id | professionals(pro_id) | One professional can be assigned many bookings |
| bookings | city_id | cities(city_id) | One city can have many bookings |
| reviews | booking_id | bookings(booking_id) | A booking can have at most one review |
| reschedules | booking_id | bookings(booking_id) | One booking can have many reschedule records |
| payouts | pro_id | professionals(pro_id) | One professional can have many payout records |
| pro_skills | pro_id | professionals(pro_id) | Links professionals to their skills |
| pro_skills | category_id | service_categories(category_id) | Links service categories to professionals |
| pro_availability | pro_id | professionals(pro_id) | One professional can have many availability slots |

## 4. Relationship Details

- **Cities and Customers:** A city can be associated with multiple customers. Each customer belongs to a city.
- **Cities and Professionals:** A city can be associated with multiple professionals. Each professional belongs to a city.
- **Categories and Services:** A service category can contain multiple services. Each service belongs to a category.
- **Customers and Bookings:** A customer can create multiple bookings. Each booking is associated with a customer.
- **Services and Bookings:** A service can be selected in multiple bookings. Each booking refers to a service.
- **Professionals and Bookings:** A professional can handle multiple bookings. The professional assignment is optional because `bookings.pro_id` contains NULL values.
- **Bookings and Reviews:** Each review is associated with one booking. Since `reviews.booking_id` is the primary key, a booking can have at most one review.
- **Bookings and Reschedules:** A booking can have multiple reschedule records.
- **Professionals and Payouts:** A professional can have multiple payout records.
- **Professionals and Service Categories:** This is a many-to-many relationship implemented through `pro_skills`.
- **Professionals and Availability:** A professional can have multiple availability slots, identified by professional, date, and start time.

## 5. Nullable Attributes

The following columns contain missing values in the supplied dataset and must allow NULL:

| Table | Nullable Columns |
|---|---|
| bookings | pro_id, started_at, completed_at, tip |
| customers | email, plus_valid_until |
| professionals | rating |
| payouts | paid_at |
| reviews | comment, rating_for_customer |

Other columns should be checked against the dataset and the intended schema before being declared nullable or NOT NULL.

## 6. Observed Categorical Values

The following distinct values were found in the supplied CSV files:

| Table | Column | Observed Values |
|---|---|---|
| bookings | status | REQUESTED, ASSIGNED, COMPLETED, CANCELLED_BY_CUSTOMER, CANCELLED_BY_PRO, NO_SHOW |
| bookings | payment_method | CARD, CASH, UPI, WALLET |
| professionals | gender | F, M |
| professionals | status | ACTIVE, OFFBOARDED, SUSPENDED |
| professionals | kyc_verified | Boolean (true/false) |
| payouts | status | PAID, PENDING |
| reschedules | requested_by | CUSTOMER, PRO |
| services | is_active | Boolean (true/false) |
| reviews | rating_for_pro | 1, 2, 3, 4, 5 |
| reviews | rating_for_customer | 3, 4, 5 in the supplied dataset |

These values describe the supplied dataset. Any additional domain constraints should be applied only when supported by the project requirements.

## 7. Key Design Decisions

1. Each main entity uses its identified unique identifier as its primary key.
2. `pro_skills` uses a composite primary key `(pro_id, category_id)` to prevent duplicate professional-category mappings.
3. `pro_availability` uses a composite primary key `(pro_id, work_date, start_time)` to identify an availability slot.
4. `reviews.booking_id` is both its primary key and a foreign key to `bookings`, allowing at most one review per booking.
5. `bookings.pro_id` is nullable because some bookings do not have an assigned professional.
6. Nullable attributes are retained as NULL rather than replacing missing values with artificial defaults.
7. Foreign keys maintain referential integrity between related entities.

## 8. Data Integrity Validation

The supplied CSV files were inspected before schema design.

- Candidate primary keys were checked for duplicate values.
- Composite primary keys were checked for duplicate combinations.
- Primary-key columns were checked for missing values.
- Foreign-key relationships were checked for orphan records.
- Categorical columns were inspected to identify their observed values.
- All tested candidate primary keys had zero duplicates and zero missing values.
- All tested foreign-key relationships had zero orphan records.

The resulting schema is intended to preserve the relationships and data integrity of the supplied dataset.
