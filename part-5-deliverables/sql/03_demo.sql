-- Optional end-to-end demonstration. Requires 01_schema.sql and 02_operations.sql.
-- Every inserted row is rolled back; existing library rows are not modified.
BEGIN;
CREATE TEMP TABLE demo_ids (borrower INTEGER, waiting_client INTEGER, item INTEGER,
                           loan INTEGER, reservation INTEGER) ON COMMIT DROP;
DO $$
DECLARE v_membership INTEGER; v_borrower INTEGER; v_waiter INTEGER;
        v_item INTEGER; v_loan INTEGER; v_reservation INTEGER;
BEGIN
    INSERT INTO library.membership_type (name, borrowing_limit, daily_late_fee_rate)
    VALUES ('Demo membership', 2, 0.25) RETURNING membership_type_id INTO v_membership;
    INSERT INTO library.client (first_name,last_name,phone_number,membership_type_id)
    VALUES ('Alex','Demo','555-0101',v_membership) RETURNING client_id INTO v_borrower;
    INSERT INTO library.client (first_name,last_name,phone_number,membership_type_id)
    VALUES ('Sam','Demo','555-0102',v_membership) RETURNING client_id INTO v_waiter;
    INSERT INTO library.library_item (title,item_type,author_creator,publication_year,genre)
    VALUES ('Demo book','book','Demo Author',2025,'Fiction') RETURNING item_id INTO v_item;
    v_loan := library.checkout_item(v_borrower,v_item,'2025-01-01 12:00-06','2025-01-15');
    v_reservation := library.reserve_item(v_waiter,v_item,'2025-01-02');
    PERFORM library.return_item(v_loan,'2025-01-18 12:00-06');
    INSERT INTO demo_ids VALUES (v_borrower,v_waiter,v_item,v_loan,v_reservation);
END;
$$;

-- Expected: amount owed 0.75; item reserved; waiting client's hold available.
SELECT i.title, i.availability_status, r.reservation_status,
       f.amount_owed, f.amount_paid
FROM demo_ids d JOIN library.library_item i ON i.item_id=d.item
JOIN library.reservation r ON r.reservation_id=d.reservation
JOIN library.late_fee f ON f.loan_id=d.loan;

-- Expected: one reservation-available notification addressed to the waiting client.
SELECT n.client_id, n.notification_type, n.message
FROM demo_ids d JOIN library.notification n ON n.reservation_id=d.reservation;

-- The waiting client checks out the item; its hold becomes fulfilled.
SELECT library.checkout_item(waiting_client,item,'2025-01-18 13:00-06') AS next_loan
FROM demo_ids;
SELECT i.availability_status, r.reservation_status
FROM demo_ids d JOIN library.library_item i ON i.item_id=d.item
JOIN library.reservation r ON r.reservation_id=d.reservation;
ROLLBACK;
