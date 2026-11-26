-- run after 01_schema.sql
BEGIN;

CREATE OR REPLACE FUNCTION library.lock_writes() RETURNS VOID
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
BEGIN
    IF current_setting('transaction_isolation') NOT IN ('read committed', 'read uncommitted') THEN
        RAISE EXCEPTION 'Use READ COMMITTED for library writes' USING ERRCODE = '0A000';
    END IF;
    PERFORM pg_advisory_xact_lock(447, 5);
END;
$$;

-- Lock writes before checking borrowing limits.
CREATE OR REPLACE FUNCTION library.serialize_write() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
BEGIN
    PERFORM library.lock_writes();
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION library.expected_availability(p_item_id INTEGER) RETURNS TEXT
LANGUAGE sql STABLE SET search_path = pg_catalog, library AS $$
    SELECT CASE
        WHEN EXISTS (SELECT 1 FROM library.loan WHERE item_id = p_item_id AND return_timestamp IS NULL)
            THEN 'on_loan'
        WHEN EXISTS (SELECT 1 FROM library.reservation WHERE item_id = p_item_id AND reservation_status = 'available')
            THEN 'reserved'
        ELSE 'available' END;
$$;

CREATE OR REPLACE FUNCTION library.sync_item(p_item_id INTEGER) RETURNS VOID
LANGUAGE sql SET search_path = pg_catalog, library AS $$
    UPDATE library.library_item SET availability_status = library.expected_availability(p_item_id)
    WHERE item_id = p_item_id AND availability_status <> library.expected_availability(p_item_id);
$$;

CREATE OR REPLACE FUNCTION library.promote_reservation(p_item_id INTEGER) RETURNS VOID
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM library.loan WHERE item_id = p_item_id AND return_timestamp IS NULL)
       AND NOT EXISTS (SELECT 1 FROM library.reservation WHERE item_id = p_item_id AND reservation_status = 'available') THEN
        UPDATE library.reservation SET reservation_status = 'available'
        WHERE reservation_id = (
            SELECT reservation_id FROM library.reservation
            WHERE item_id = p_item_id AND reservation_status = 'pending'
            ORDER BY reservation_date, reservation_id LIMIT 1
        );
    END IF;
    PERFORM library.sync_item(p_item_id);
END;
$$;

CREATE OR REPLACE FUNCTION library.guard_membership() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
BEGIN
    IF NEW.membership_type_id <> OLD.membership_type_id THEN
        RAISE EXCEPTION 'Membership identifiers cannot be changed' USING ERRCODE = '23514';
    END IF;
    IF NEW.daily_late_fee_rate <> OLD.daily_late_fee_rate AND EXISTS (
        SELECT 1 FROM library.client c JOIN library.loan l USING (client_id)
        WHERE c.membership_type_id = OLD.membership_type_id AND l.return_timestamp IS NULL
    ) THEN
        RAISE EXCEPTION 'Return active loans before changing their fee rate' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM library.client c JOIN library.loan l USING (client_id)
        WHERE c.membership_type_id = OLD.membership_type_id AND l.return_timestamp IS NULL
        GROUP BY c.client_id HAVING count(*) > NEW.borrowing_limit
    ) THEN
        RAISE EXCEPTION 'Borrowing limit is below an existing active loan count' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION library.guard_client() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
BEGIN
    IF NEW.client_id <> OLD.client_id THEN
        RAISE EXCEPTION 'Client identifiers cannot be changed' USING ERRCODE = '23514';
    END IF;
    IF NEW.membership_type_id <> OLD.membership_type_id AND EXISTS (
        SELECT 1 FROM library.loan WHERE client_id = OLD.client_id AND return_timestamp IS NULL
    ) THEN
        RAISE EXCEPTION 'Return active loans before changing membership' USING ERRCODE = '23514';
    END IF;
    IF NEW.account_status <> 'active' AND EXISTS (
        SELECT 1 FROM library.reservation WHERE client_id = OLD.client_id
        AND reservation_status IN ('pending', 'available')
    ) THEN
        RAISE EXCEPTION 'Cancel open reservations before restricting an account' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION library.guard_item() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF EXISTS (SELECT 1 FROM library.reservation WHERE item_id = OLD.item_id
                   AND reservation_status IN ('pending', 'available')) THEN
            RAISE EXCEPTION 'Cannot remove an item with an open reservation' USING ERRCODE = '23514';
        END IF;
        RETURN OLD;
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.item_id <> OLD.item_id THEN
        RAISE EXCEPTION 'Item identifiers cannot be changed' USING ERRCODE = '23514';
    END IF;
    IF NEW.availability_status <> library.expected_availability(NEW.item_id) THEN
        RAISE EXCEPTION 'Availability must match loan/reservation records' USING ERRCODE = '23514';
    END IF;
    IF NEW.borrowing_restricted AND EXISTS (
        SELECT 1 FROM library.reservation WHERE item_id = NEW.item_id
        AND reservation_status IN ('pending', 'available')
    ) THEN
        RAISE EXCEPTION 'Cancel open reservations before restricting an item' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION library.guard_loan() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
DECLARE
    v_limit INTEGER;
    v_status TEXT;
    v_restricted BOOLEAN;
    v_holder INTEGER;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.return_timestamp IS NULL THEN
            RAISE EXCEPTION 'Return the item instead of deleting an active loan' USING ERRCODE = '23514';
        END IF;
        RETURN OLD;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF NEW.loan_id <> OLD.loan_id OR NEW.item_id <> OLD.item_id OR NEW.client_id <> OLD.client_id
           OR NEW.checkout_timestamp <> OLD.checkout_timestamp OR NEW.due_date <> OLD.due_date
           OR (OLD.return_timestamp IS NOT NULL AND
               (NEW.return_timestamp IS NULL OR NEW.return_timestamp <> OLD.return_timestamp)) THEN
            RAISE EXCEPTION 'Loan identity and dates are fixed; only the first return may be recorded' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;
    SELECT c.account_status, m.borrowing_limit INTO v_status, v_limit
    FROM library.client c JOIN library.membership_type m USING (membership_type_id)
    WHERE c.client_id = NEW.client_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Client does not exist' USING ERRCODE = '23503';
    END IF;
    SELECT borrowing_restricted INTO v_restricted FROM library.library_item WHERE item_id = NEW.item_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Item does not exist' USING ERRCODE = '23503';
    END IF;
    IF v_status <> 'active' OR v_restricted THEN
        RAISE EXCEPTION 'Client or item is not eligible for borrowing' USING ERRCODE = '23514';
    END IF;
    IF NEW.return_timestamp IS NULL THEN
        IF EXISTS (SELECT 1 FROM library.loan WHERE item_id = NEW.item_id AND return_timestamp IS NULL) THEN
            RAISE EXCEPTION 'Item already has an active loan' USING ERRCODE = '23514';
        END IF;
        IF (SELECT count(*) FROM library.loan WHERE client_id = NEW.client_id AND return_timestamp IS NULL) >= v_limit THEN
            RAISE EXCEPTION 'Membership borrowing limit reached' USING ERRCODE = '23514';
        END IF;
        SELECT client_id INTO v_holder FROM library.reservation
        WHERE item_id = NEW.item_id AND reservation_status = 'available';
        IF FOUND AND v_holder <> NEW.client_id THEN
            RAISE EXCEPTION 'Item is held for another client' USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION library.guard_reservation() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
DECLARE v_first INTEGER;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.reservation_status IN ('pending', 'available') THEN
            RAISE EXCEPTION 'Cancel the reservation instead of deleting it' USING ERRCODE = '23514';
        END IF;
        RETURN OLD;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.reservation_status <> 'pending' THEN
            RAISE EXCEPTION 'A reservation must start pending' USING ERRCODE = '23514';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM library.client WHERE client_id = NEW.client_id AND account_status = 'active')
           OR NOT EXISTS (SELECT 1 FROM library.library_item WHERE item_id = NEW.item_id AND NOT borrowing_restricted) THEN
            RAISE EXCEPTION 'Client or item is not eligible for reservation' USING ERRCODE = '23514';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM library.loan WHERE item_id = NEW.item_id AND return_timestamp IS NULL)
           OR EXISTS (SELECT 1 FROM library.loan WHERE item_id = NEW.item_id AND client_id = NEW.client_id AND return_timestamp IS NULL) THEN
            RAISE EXCEPTION 'Reserve an unavailable item borrowed by another client' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.reservation_id <> OLD.reservation_id OR NEW.client_id <> OLD.client_id
       OR NEW.item_id <> OLD.item_id OR NEW.reservation_date <> OLD.reservation_date THEN
        RAISE EXCEPTION 'Reservation identity and request date cannot change' USING ERRCODE = '23514';
    END IF;
    IF NEW.reservation_status = OLD.reservation_status THEN RETURN NEW; END IF;
    IF OLD.reservation_status IN ('cancelled', 'fulfilled') THEN
        RAISE EXCEPTION 'A completed reservation cannot be reopened' USING ERRCODE = '23514';
    END IF;
    IF NEW.reservation_status = 'cancelled' THEN RETURN NEW; END IF;
    IF OLD.reservation_status = 'pending' AND NEW.reservation_status = 'available'
       AND NOT EXISTS (SELECT 1 FROM library.loan WHERE item_id = NEW.item_id AND return_timestamp IS NULL) THEN
        SELECT reservation_id INTO v_first FROM library.reservation
        WHERE item_id = NEW.item_id AND reservation_status = 'pending'
        ORDER BY reservation_date, reservation_id LIMIT 1;
        IF v_first = NEW.reservation_id THEN RETURN NEW; END IF;
    END IF;
    IF OLD.reservation_status = 'available' AND NEW.reservation_status = 'fulfilled'
       AND EXISTS (SELECT 1 FROM library.loan WHERE item_id = NEW.item_id AND client_id = NEW.client_id AND return_timestamp IS NULL) THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'Invalid reservation transition' USING ERRCODE = '23514';
END;
$$;

CREATE OR REPLACE FUNCTION library.assess_late_fee(
    p_loan_id INTEGER,
    p_as_of DATE DEFAULT CAST(CURRENT_TIMESTAMP AT TIME ZONE 'America/Chicago' AS DATE)
) RETURNS NUMERIC
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
DECLARE v_amount NUMERIC(10,2); v_end DATE; v_due DATE; v_rate NUMERIC(6,2); v_closed BOOLEAN;
BEGIN
    PERFORM library.lock_writes();
    IF p_as_of IS NULL THEN RAISE EXCEPTION 'Assessment date is required' USING ERRCODE = '23514'; END IF;
    SELECT COALESCE(CAST(l.return_timestamp AT TIME ZONE 'America/Chicago' AS DATE), p_as_of),
           l.due_date, m.daily_late_fee_rate, l.return_timestamp IS NOT NULL
    INTO v_end, v_due, v_rate, v_closed
    FROM library.loan l JOIN library.client c USING (client_id)
    JOIN library.membership_type m USING (membership_type_id) WHERE l.loan_id = p_loan_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Loan does not exist' USING ERRCODE = '23503'; END IF;
    -- Keep the amount recorded at return
    IF v_closed THEN
        SELECT amount_owed INTO v_amount FROM library.late_fee WHERE loan_id = p_loan_id;
        IF FOUND THEN RETURN v_amount; END IF;
    END IF;
    v_amount := GREATEST(v_end - v_due, 0) * v_rate;
    UPDATE library.late_fee SET amount_owed = v_amount WHERE loan_id = p_loan_id;
    IF NOT FOUND AND (v_amount > 0 OR (v_closed AND v_end > v_due)) THEN
        INSERT INTO library.late_fee (loan_id, amount_owed) VALUES (p_loan_id, v_amount);
    END IF;
    RETURN v_amount;
END;
$$;

CREATE OR REPLACE FUNCTION library.after_reservation() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.reservation_status = OLD.reservation_status THEN
        RETURN NEW;
    END IF;
    IF NEW.reservation_status = 'available' AND NOT EXISTS (
        SELECT 1 FROM library.notification WHERE reservation_id = NEW.reservation_id
    ) THEN
        INSERT INTO library.notification (client_id, reservation_id, notification_type, message)
        VALUES (NEW.client_id, NEW.reservation_id, 'reservation_available',
                'Reserved item ' || NEW.item_id || ' is available for pickup.');
    END IF;
    PERFORM library.promote_reservation(NEW.item_id);
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION library.after_loan() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF OLD.return_timestamp IS NOT NULL OR NEW.return_timestamp IS NULL THEN
            RETURN NEW;
        END IF;
    END IF;
    IF NEW.return_timestamp IS NULL THEN
        UPDATE library.reservation SET reservation_status = 'fulfilled'
        WHERE item_id = NEW.item_id AND client_id = NEW.client_id AND reservation_status = 'available';
    ELSE
        -- finalize any provisional fee
        UPDATE library.late_fee f
        SET amount_owed = GREATEST(CAST(NEW.return_timestamp AT TIME ZONE 'America/Chicago' AS DATE) - NEW.due_date, 0)
                          * m.daily_late_fee_rate
        FROM library.client c JOIN library.membership_type m USING (membership_type_id)
        WHERE f.loan_id = NEW.loan_id AND c.client_id = NEW.client_id;
        PERFORM library.assess_late_fee(NEW.loan_id, CAST(NEW.return_timestamp AT TIME ZONE 'America/Chicago' AS DATE));
    END IF;
    PERFORM library.promote_reservation(NEW.item_id);
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION library.checkout_item(
    p_client_id INTEGER, p_item_id INTEGER,
    p_checkout_timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP, p_due_date DATE DEFAULT NULL
) RETURNS INTEGER
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
DECLARE v_id INTEGER;
BEGIN
    PERFORM library.lock_writes();
    IF p_checkout_timestamp IS NULL THEN RAISE EXCEPTION 'Checkout timestamp is required' USING ERRCODE = '23514'; END IF;
    INSERT INTO library.loan (client_id, item_id, checkout_timestamp, due_date)
    VALUES (p_client_id, p_item_id, p_checkout_timestamp,
            COALESCE(p_due_date, CAST(p_checkout_timestamp AT TIME ZONE 'America/Chicago' AS DATE) + 14))
    RETURNING loan_id INTO v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION library.return_item(
    p_loan_id INTEGER, p_return_timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
) RETURNS NUMERIC
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
BEGIN
    PERFORM library.lock_writes();
    IF p_return_timestamp IS NULL THEN RAISE EXCEPTION 'Return timestamp is required' USING ERRCODE = '23514'; END IF;
    UPDATE library.loan SET return_timestamp = p_return_timestamp
    WHERE loan_id = p_loan_id AND return_timestamp IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'Loan is missing or already returned' USING ERRCODE = '23514'; END IF;
    RETURN COALESCE((SELECT amount_owed FROM library.late_fee WHERE loan_id = p_loan_id), 0);
END;
$$;

CREATE OR REPLACE FUNCTION library.reserve_item(
    p_client_id INTEGER, p_item_id INTEGER,
    p_reservation_date DATE DEFAULT CAST(CURRENT_TIMESTAMP AT TIME ZONE 'America/Chicago' AS DATE)
) RETURNS INTEGER
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
DECLARE v_id INTEGER;
BEGIN
    PERFORM library.lock_writes();
    INSERT INTO library.reservation (client_id, item_id, reservation_date)
    VALUES (p_client_id, p_item_id, p_reservation_date) RETURNING reservation_id INTO v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION library.cancel_reservation(p_reservation_id INTEGER) RETURNS VOID
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
BEGIN
    PERFORM library.lock_writes();
    UPDATE library.reservation SET reservation_status = 'cancelled'
    WHERE reservation_id = p_reservation_id AND reservation_status IN ('pending', 'available');
    IF NOT FOUND THEN RAISE EXCEPTION 'Reservation is missing or already completed' USING ERRCODE = '23514'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION library.pay_late_fee(p_fee_id INTEGER, p_amount NUMERIC) RETURNS NUMERIC
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
DECLARE v_balance NUMERIC;
BEGIN
    PERFORM library.lock_writes();
    IF p_amount IS NULL OR p_amount <= 0 OR p_amount <> round(p_amount, 2) THEN
        RAISE EXCEPTION 'Payment must be positive with at most two decimal places' USING ERRCODE = '23514';
    END IF;
    UPDATE library.late_fee SET amount_paid = amount_paid + p_amount WHERE fee_id = p_fee_id
    RETURNING amount_owed - amount_paid INTO v_balance;
    IF NOT FOUND THEN RAISE EXCEPTION 'Fee does not exist' USING ERRCODE = '23503'; END IF;
    RETURN v_balance;
END;
$$;

CREATE OR REPLACE FUNCTION library.generate_notifications(
    p_as_of DATE DEFAULT CAST(CURRENT_TIMESTAMP AT TIME ZONE 'America/Chicago' AS DATE)
) RETURNS INTEGER
LANGUAGE plpgsql SET search_path = pg_catalog, library AS $$
DECLARE v_loans INTEGER; v_reservations INTEGER;
BEGIN
    PERFORM library.lock_writes();
    IF p_as_of IS NULL THEN RAISE EXCEPTION 'Notification date is required' USING ERRCODE = '23514'; END IF;
    INSERT INTO library.notification (client_id, loan_id, notification_type, message, creation_timestamp)
    SELECT l.client_id, l.loan_id, CASE WHEN l.due_date < p_as_of THEN 'overdue' ELSE 'upcoming_due' END,
           'Item ' || l.item_id || ' is due on ' || l.due_date || '.',
           CAST(p_as_of AS TIMESTAMP) AT TIME ZONE 'America/Chicago'
    FROM library.loan AS l
    WHERE l.return_timestamp IS NULL AND l.due_date <= p_as_of + 3
      AND CAST(l.checkout_timestamp AT TIME ZONE 'America/Chicago' AS DATE) <= p_as_of
      AND NOT EXISTS (
          SELECT 1 FROM library.notification AS n
          WHERE n.loan_id = l.loan_id
            AND CAST(n.creation_timestamp AT TIME ZONE 'America/Chicago' AS DATE) = p_as_of
            AND n.notification_type = CASE WHEN l.due_date < p_as_of THEN 'overdue' ELSE 'upcoming_due' END
      );
    GET DIAGNOSTICS v_loans = ROW_COUNT;

    INSERT INTO library.notification (client_id, reservation_id, notification_type, message, creation_timestamp)
    SELECT r.client_id, r.reservation_id, 'reservation_available',
           'Reserved item ' || r.item_id || ' is available for pickup.',
           CAST(p_as_of AS TIMESTAMP) AT TIME ZONE 'America/Chicago'
    FROM library.reservation AS r
    WHERE r.reservation_status = 'available'
      AND r.reservation_date <= p_as_of
      AND NOT EXISTS (
          SELECT 1 FROM library.notification AS n WHERE n.reservation_id = r.reservation_id
      );
    GET DIAGNOSTICS v_reservations = ROW_COUNT;
    RETURN v_loans + v_reservations;
END;
$$;

-- Statement triggers take the lock first
CREATE OR REPLACE TRIGGER serialize_write
    BEFORE INSERT OR UPDATE OR DELETE ON library.membership_type
    FOR EACH STATEMENT EXECUTE FUNCTION library.serialize_write();
CREATE OR REPLACE TRIGGER serialize_write
    BEFORE INSERT OR UPDATE OR DELETE ON library.client
    FOR EACH STATEMENT EXECUTE FUNCTION library.serialize_write();
CREATE OR REPLACE TRIGGER serialize_write
    BEFORE INSERT OR UPDATE OR DELETE ON library.library_item
    FOR EACH STATEMENT EXECUTE FUNCTION library.serialize_write();
CREATE OR REPLACE TRIGGER serialize_write
    BEFORE INSERT OR UPDATE OR DELETE ON library.loan
    FOR EACH STATEMENT EXECUTE FUNCTION library.serialize_write();
CREATE OR REPLACE TRIGGER serialize_write
    BEFORE INSERT OR UPDATE OR DELETE ON library.late_fee
    FOR EACH STATEMENT EXECUTE FUNCTION library.serialize_write();
CREATE OR REPLACE TRIGGER serialize_write
    BEFORE INSERT OR UPDATE OR DELETE ON library.reservation
    FOR EACH STATEMENT EXECUTE FUNCTION library.serialize_write();
CREATE OR REPLACE TRIGGER serialize_write
    BEFORE INSERT OR UPDATE OR DELETE ON library.notification
    FOR EACH STATEMENT EXECUTE FUNCTION library.serialize_write();

CREATE OR REPLACE TRIGGER membership_rules BEFORE UPDATE ON library.membership_type
    FOR EACH ROW EXECUTE FUNCTION library.guard_membership();
CREATE OR REPLACE TRIGGER client_rules BEFORE UPDATE ON library.client
    FOR EACH ROW EXECUTE FUNCTION library.guard_client();
CREATE OR REPLACE TRIGGER item_rules BEFORE INSERT OR UPDATE OR DELETE ON library.library_item
    FOR EACH ROW EXECUTE FUNCTION library.guard_item();
CREATE OR REPLACE TRIGGER loan_rules BEFORE INSERT OR UPDATE OR DELETE ON library.loan
    FOR EACH ROW EXECUTE FUNCTION library.guard_loan();
CREATE OR REPLACE TRIGGER loan_state AFTER INSERT OR UPDATE ON library.loan
    FOR EACH ROW EXECUTE FUNCTION library.after_loan();
CREATE OR REPLACE TRIGGER reservation_rules BEFORE INSERT OR UPDATE OR DELETE ON library.reservation
    FOR EACH ROW EXECUTE FUNCTION library.guard_reservation();
CREATE OR REPLACE TRIGGER reservation_state AFTER INSERT OR UPDATE ON library.reservation
    FOR EACH ROW EXECUTE FUNCTION library.after_reservation();
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA library FROM PUBLIC;
COMMIT;
