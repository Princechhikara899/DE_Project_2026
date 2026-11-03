# 1. Problem Understanding

## Business Context

Urban Company connects customers with service professionals for home services. The platform must manage service discovery, bookings, professional assignments, availability, payments, reviews, and operational reporting. As booking volume grows, slow queries affect customer experience, professional productivity, and business decisions.

## Problem Statements (P1–P8)

| ID | Business Need and Problem | Stakeholder Affected | Classification |
|---|---|---|---|
| P1 | Customers need a fast service menu and slot picker. The system must check service requirements, professional skills, availability, and scheduling conflicts before showing suitable slots. | Customers | Customer-facing / Real-time |
| P2 | Customers and support staff need quick access to booking lists, booking details, and phone-based booking lookups. Slow retrieval makes it difficult to track and resolve booking-related issues. | Customers, Customer Support | Customer-facing / Real-time |
| P3 | Professionals need their daily jobs, weekly earnings, and job-completion actions to load quickly so they can manage their work efficiently. | Service Professionals | Customer-facing / Real-time |
| P4 | Dispatch teams need to identify unassigned bookings whose scheduled start times are approaching, so that suitable professionals can be assigned promptly. | Dispatch Team | Customer-facing / Real-time |
| P5 | Partner Success needs an accurate list of professionals who have not received any customer cancellations. The current report returns an empty result, preventing identification of eligible professionals. | Partner Success Team | Reporting / Analytics |
| P6 | Quality teams need reports on late starts, no-shows, low ratings, complaints, and bookings where professionals lack the required skills. Slow reports delay quality monitoring and corrective action. | Quality Team | Reporting / Analytics |
| P7 | Finance needs timely reports for professional payouts, Urban Company Plus savings, cancellation fees, and gross merchandise value (GMV). Slow queries delay financial tracking and reconciliation. | Finance Team | Reporting / Analytics |
| P8 | Operations and Expansion teams need reports on reschedules, demand heat maps, pincodes, customer retention, professional utilisation, and city-level performance. The database must support these reports as bookings grow by 20 times. | Operations and Expansion Teams | Reporting / Analytics |

## Assumptions

1. Each booking is associated with one customer, one service, and one city.
2. A booking may initially have no assigned professional; therefore, its professional reference can be NULL.
3. Professionals have skills linked to service categories, and their availability is recorded by date and time.
4. Booking status represents the current stage or outcome of a booking.
5. Reviews are associated with bookings, and customer and professional ratings may be optional where the data permits.
6. Payout records represent professional earnings for a particular week.
7. Reporting queries must use the underlying booking, professional, customer, review, reschedule, and payout data consistently.
8. The database should preserve data integrity while supporting the expected increase in booking volume.
