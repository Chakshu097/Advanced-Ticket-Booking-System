-- ============================================================
-- Advanced Ticket Booking System
-- File: 01_schema.sql
-- Description: Database schema with tables, constraints, and indexes
-- ============================================================

-- Drop existing tables in reverse dependency order
DROP TABLE IF EXISTS waiting_queue;
DROP TABLE IF EXISTS bookings;
DROP TABLE IF EXISTS seats;
DROP TABLE IF EXISTS shows;
DROP TABLE IF EXISTS users;

-- ============================================================
-- Table: users
-- ============================================================
CREATE TABLE users (
    user_id     SERIAL PRIMARY KEY,
    username    VARCHAR(100) NOT NULL UNIQUE,
    email       VARCHAR(150) NOT NULL UNIQUE,
    phone       VARCHAR(15),
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- Table: shows
-- Represents a movie, concert, or any event with a schedule
-- ============================================================
CREATE TABLE shows (
    show_id         SERIAL PRIMARY KEY,
    title           VARCHAR(200) NOT NULL,
    venue           VARCHAR(200) NOT NULL,
    show_datetime   TIMESTAMP NOT NULL,
    total_seats     INT NOT NULL CHECK (total_seats > 0),
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- Table: seats
-- Each row is one seat in a specific show.
-- version column is used for optimistic locking (Q5).
-- ============================================================
CREATE TABLE seats (
    seat_id     SERIAL PRIMARY KEY,
    show_id     INT NOT NULL REFERENCES shows(show_id) ON DELETE CASCADE,
    seat_number VARCHAR(10) NOT NULL,
    status      VARCHAR(10) NOT NULL DEFAULT 'AVAILABLE'
                    CHECK (status IN ('AVAILABLE', 'LOCKED', 'BOOKED')),
    version     INT NOT NULL DEFAULT 0,
    locked_at   TIMESTAMP,               -- timestamp when seat was locked (used for timeout)
    locked_by   INT REFERENCES users(user_id),
    UNIQUE (show_id, seat_number)
);

-- ============================================================
-- Table: bookings
-- Confirmed booking records linked to a user and a seat.
-- ============================================================
CREATE TABLE bookings (
    booking_id      SERIAL PRIMARY KEY,
    user_id         INT NOT NULL REFERENCES users(user_id),
    seat_id         INT NOT NULL REFERENCES seats(seat_id),
    show_id         INT NOT NULL REFERENCES shows(show_id),
    booked_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status          VARCHAR(10) NOT NULL DEFAULT 'CONFIRMED'
                        CHECK (status IN ('CONFIRMED', 'CANCELLED')),
    payment_status  VARCHAR(10) NOT NULL DEFAULT 'PENDING'
                        CHECK (payment_status IN ('PENDING', 'PAID', 'FAILED'))
);

-- ============================================================
-- Table: waiting_queue
-- Stores users waiting for a seat when show is fully booked (Q8)
-- ============================================================
CREATE TABLE waiting_queue (
    queue_id        SERIAL PRIMARY KEY,
    user_id         INT NOT NULL REFERENCES users(user_id),
    show_id         INT NOT NULL REFERENCES shows(show_id),
    requested_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status          VARCHAR(10) NOT NULL DEFAULT 'WAITING'
                        CHECK (status IN ('WAITING', 'NOTIFIED', 'EXPIRED')),
    UNIQUE (user_id, show_id)
);

-- ============================================================
-- Indexes for performance
-- ============================================================
CREATE INDEX idx_seats_show_status   ON seats (show_id, status);
CREATE INDEX idx_bookings_user       ON bookings (user_id);
CREATE INDEX idx_bookings_show       ON bookings (show_id);
CREATE INDEX idx_waiting_queue_show  ON waiting_queue (show_id, status);
-- ============================================================
-- Advanced Ticket Booking System
-- File: 02_seed_data.sql
-- Description: Sample data for testing all scenarios
-- ============================================================

-- Users
INSERT INTO users (username, email, phone) VALUES
    ('alice',   'alice@example.com',   '9876500001'),
    ('bob',     'bob@example.com',     '9876500002'),
    ('charlie', 'charlie@example.com', '9876500003'),
    ('diana',   'diana@example.com',   '9876500004'),
    ('eve',     'eve@example.com',     '9876500005');

-- Shows
INSERT INTO shows (title, venue, show_datetime, total_seats) VALUES
    ('Inception',     'PVR Cinemas',    '2025-07-10 18:30:00', 5),
    ('Coldplay Live', 'DY Patil Stadium','2025-08-15 20:00:00', 6),
    ('RRR Reloaded',  'INOX Mall',      '2025-07-20 15:00:00', 4);

-- Seats for Show 1 (Inception) — 5 seats
INSERT INTO seats (show_id, seat_number, status) VALUES
    (1, 'A1', 'AVAILABLE'),
    (1, 'A2', 'AVAILABLE'),
    (1, 'A3', 'AVAILABLE'),
    (1, 'A4', 'AVAILABLE'),
    (1, 'A5', 'AVAILABLE');

-- Seats for Show 2 (Coldplay Live) — 6 seats
INSERT INTO seats (show_id, seat_number, status) VALUES
    (2, 'B1', 'AVAILABLE'),
    (2, 'B2', 'AVAILABLE'),
    (2, 'B3', 'AVAILABLE'),
    (2, 'B4', 'AVAILABLE'),
    (2, 'B5', 'AVAILABLE'),
    (2, 'B6', 'AVAILABLE');

-- Seats for Show 3 (RRR Reloaded) — 4 seats (all booked to test waiting queue)
INSERT INTO seats (show_id, seat_number, status) VALUES
    (3, 'C1', 'BOOKED'),
    (3, 'C2', 'BOOKED'),
    (3, 'C3', 'BOOKED'),
    (3, 'C4', 'BOOKED');
-- ============================================================
-- Advanced Ticket Booking System
-- File: 03_booking_transaction.sql
-- Description: Q2 — Transaction-safe booking procedure using
--              FOR UPDATE NOWAIT, explicit COMMIT/ROLLBACK,
--              and seat status management.
-- ============================================================

-- ============================================================
-- Function: book_seat
-- Parameters:
--   p_user_id  — ID of the user booking the seat
--   p_seat_id  — ID of the seat being booked
-- Returns: TEXT message indicating success or failure reason
-- ============================================================
CREATE OR REPLACE FUNCTION book_seat(p_user_id INT, p_seat_id INT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_seat_status   VARCHAR(10);
    v_show_id       INT;
    v_booking_id    INT;
BEGIN
    -- Step 1: Lock the seat row exclusively.
    -- NOWAIT means: if another transaction already holds a lock
    -- on this row, raise an error immediately instead of waiting.
    SELECT status, show_id
    INTO   v_seat_status, v_show_id
    FROM   seats
    WHERE  seat_id = p_seat_id
    FOR UPDATE NOWAIT;

    -- Step 2: Check whether the seat is still available.
    IF v_seat_status <> 'AVAILABLE' THEN
        -- Seat is either LOCKED or BOOKED; abort without making changes.
        RETURN 'FAILED: Seat is not available (current status: ' || v_seat_status || ')';
    END IF;

    -- Step 3: Mark the seat as BOOKED.
    UPDATE seats
    SET    status    = 'BOOKED',
           locked_at = NULL,
           locked_by = NULL
    WHERE  seat_id = p_seat_id;

    -- Step 4: Create the booking record.
    INSERT INTO bookings (user_id, seat_id, show_id, payment_status)
    VALUES (p_user_id, p_seat_id, v_show_id, 'PAID')
    RETURNING booking_id INTO v_booking_id;

    RETURN 'SUCCESS: Booking confirmed. Booking ID = ' || v_booking_id;

EXCEPTION
    -- Raised by FOR UPDATE NOWAIT when the row is already locked.
    WHEN lock_not_available THEN
        RETURN 'FAILED: Seat is currently being processed by another user. Please try again.';

    -- Catch-all for unexpected errors (FK violations, etc.)
    WHEN OTHERS THEN
        RETURN 'FAILED: Unexpected error — ' || SQLERRM;
END;
$$;

-- ============================================================
-- Usage Example
-- Run each in a separate transaction to observe locking behaviour.
-- ============================================================

-- Book seat 1 for user 1 (alice)
BEGIN;
    SELECT book_seat(1, 1);
COMMIT;

-- Attempt to book the same seat for user 2 (bob) — should fail
BEGIN;
    SELECT book_seat(2, 1);
COMMIT;

-- Book a different available seat for bob
BEGIN;
    SELECT book_seat(2, 2);
COMMIT;
-- ============================================================
-- Advanced Ticket Booking System
-- File: 04_parallel_booking.sql
-- Description: Q3 — Parallel booking using FOR UPDATE SKIP LOCKED.
--              Multiple users can book different seats simultaneously
--              without blocking each other.
-- ============================================================

-- ============================================================
-- How SKIP LOCKED works
-- When a session tries to lock rows that are already locked by
-- another transaction, SKIP LOCKED silently skips those rows
-- and returns only the unlocked ones. This avoids waiting and
-- lets concurrent sessions work on different seats.
-- ============================================================

-- ============================================================
-- Function: book_next_available_seat
-- Automatically picks the next unlocked available seat for a
-- given show and assigns it to the user.
-- ============================================================
CREATE OR REPLACE FUNCTION book_next_available_seat(p_user_id INT, p_show_id INT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_seat_id    INT;
    v_booking_id INT;
BEGIN
    -- Pick one available seat that is not currently locked by another session.
    -- SKIP LOCKED ensures we do not wait; we move on to an unlocked row.
    SELECT seat_id
    INTO   v_seat_id
    FROM   seats
    WHERE  show_id = p_show_id
      AND  status  = 'AVAILABLE'
    ORDER BY seat_number
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

    -- No available (and unlocked) seat was found.
    IF v_seat_id IS NULL THEN
        RETURN 'FAILED: No available seats. You have been added to the waiting queue.';
    END IF;

    -- Mark the seat as BOOKED.
    UPDATE seats
    SET    status = 'BOOKED'
    WHERE  seat_id = v_seat_id;

    -- Create confirmed booking record.
    INSERT INTO bookings (user_id, seat_id, show_id, payment_status)
    VALUES (p_user_id, v_seat_id, p_show_id, 'PAID')
    RETURNING booking_id INTO v_booking_id;

    RETURN 'SUCCESS: Seat ' || v_seat_id || ' booked. Booking ID = ' || v_booking_id;
END;
$$;

-- ============================================================
-- Simulation: Three users booking seats for Show 1 simultaneously.
-- In a real concurrent environment these would run in parallel.
-- Here they are shown sequentially to illustrate the logic.
-- ============================================================

-- Session 1 — alice books a seat
BEGIN;
    SELECT book_next_available_seat(1, 1);  -- user_id=1, show_id=1
COMMIT;

-- Session 2 — bob books a seat (different seat, no waiting)
BEGIN;
    SELECT book_next_available_seat(2, 1);
COMMIT;

-- Session 3 — charlie books a seat
BEGIN;
    SELECT book_next_available_seat(3, 1);
COMMIT;

-- Verify: all three should have different seats
SELECT
    b.booking_id,
    u.username,
    s.seat_number,
    b.booked_at
FROM   bookings b
JOIN   users    u ON u.user_id = b.user_id
JOIN   seats    s ON s.seat_id = b.seat_id
WHERE  b.show_id = 1
ORDER BY b.booking_id;
-- ============================================================
-- Advanced Ticket Booking System
-- File: 05_deadlock_simulation.sql
-- Description: Q4 — Deadlock scenario and prevention strategy.
-- ============================================================

-- ============================================================
-- PART A: How a deadlock occurs
-- ============================================================
-- Transaction T1 and T2 try to lock two seats in opposite order.
--
-- Timeline:
--   T1 locks seat_id=1, then tries to lock seat_id=2
--   T2 locks seat_id=2, then tries to lock seat_id=1
--
-- Neither can proceed — PostgreSQL will detect this cycle and
-- automatically abort one of the transactions (the victim).
-- The aborted session receives error code 40P01 (deadlock_detected).
-- ============================================================

-- Open two database sessions (psql tabs or DBeaver connections)
-- and run the blocks below interleaved in the order shown.

-- ---- Session 1 (T1) ----
BEGIN;
    -- Step 1a: T1 locks seat 1
    SELECT * FROM seats WHERE seat_id = 1 FOR UPDATE;

    -- (Now switch to Session 2 and run step 2a before continuing)

    -- Step 1b: T1 tries to lock seat 2 — will WAIT because T2 holds it
    SELECT * FROM seats WHERE seat_id = 2 FOR UPDATE;
    -- PostgreSQL detects deadlock and rolls back one transaction here.
COMMIT;

-- ---- Session 2 (T2) ----
BEGIN;
    -- Step 2a: T2 locks seat 2
    SELECT * FROM seats WHERE seat_id = 2 FOR UPDATE;

    -- Step 2b: T2 tries to lock seat 1 — DEADLOCK occurs
    SELECT * FROM seats WHERE seat_id = 1 FOR UPDATE;
COMMIT;

-- ============================================================
-- PART B: Prevention strategy — always lock seats in ascending
--         order of seat_id so cycles cannot form.
-- ============================================================

CREATE OR REPLACE FUNCTION book_multiple_seats(
    p_user_id  INT,
    p_seat_ids INT[]   -- array of seat IDs requested by the user
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_seat       RECORD;
    v_booking_id INT;
    v_results    TEXT := '';
BEGIN
    -- Lock all requested seats in ascending seat_id order.
    -- Because every transaction uses the same ordering, circular
    -- wait conditions cannot form, eliminating deadlocks.
    FOR v_seat IN
        SELECT seat_id, status, show_id
        FROM   seats
        WHERE  seat_id = ANY(p_seat_ids)
        ORDER BY seat_id ASC          -- consistent ordering prevents deadlock
        FOR UPDATE NOWAIT
    LOOP
        IF v_seat.status <> 'AVAILABLE' THEN
            RAISE EXCEPTION 'Seat % is not available', v_seat.seat_id;
        END IF;

        UPDATE seats SET status = 'BOOKED' WHERE seat_id = v_seat.seat_id;

        INSERT INTO bookings (user_id, seat_id, show_id, payment_status)
        VALUES (p_user_id, v_seat.seat_id, v_seat.show_id, 'PAID')
        RETURNING booking_id INTO v_booking_id;

        v_results := v_results || 'Seat ' || v_seat.seat_id
                     || ' -> Booking #' || v_booking_id || '; ';
    END LOOP;

    RETURN 'SUCCESS: ' || v_results;

EXCEPTION
    WHEN lock_not_available THEN
        RETURN 'FAILED: One or more seats are locked by another session.';
    WHEN OTHERS THEN
        RETURN 'FAILED: ' || SQLERRM;
END;
$$;

-- Example: user alice books seats 3 and 4 together
BEGIN;
    SELECT book_multiple_seats(1, ARRAY[3, 4]);
COMMIT;

-- Example: user bob attempts same seats — will fail cleanly
BEGIN;
    SELECT book_multiple_seats(2, ARRAY[3, 4]);
COMMIT;
-- ============================================================
-- Advanced Ticket Booking System
-- File: 06_optimistic_locking.sql
-- Description: Q5 — Optimistic locking using a version column
--              to prevent lost updates without row-level locks.
-- ============================================================

-- ============================================================
-- Why optimistic locking?
-- Pessimistic locking (FOR UPDATE) holds locks for the entire
-- duration of a transaction. Under high read load this reduces
-- throughput. Optimistic locking reads data without locks and
-- validates at write time using a version counter. If the version
-- has changed since the read, another user beat us to it and the
-- update is rejected — no data is lost.
-- ============================================================

-- The version column already exists in the seats table from 01_schema.sql.
-- It starts at 0 and increments by 1 on every successful update.

-- ============================================================
-- Function: book_seat_optimistic
-- Steps:
--   1. Read the seat and note the current version number.
--   2. Update the seat only if the version still matches.
--   3. If 0 rows were updated, someone else changed the row.
-- ============================================================
CREATE OR REPLACE FUNCTION book_seat_optimistic(
    p_user_id        INT,
    p_seat_id        INT,
    p_known_version  INT   -- version the client read before attempting to book
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_updated INT;
    v_show_id      INT;
    v_booking_id   INT;
BEGIN
    -- Attempt the update only if the version matches what the client saw.
    -- Increment version on success so the next writer must use the new value.
    UPDATE seats
    SET    status  = 'BOOKED',
           version = version + 1
    WHERE  seat_id = p_seat_id
      AND  status  = 'AVAILABLE'
      AND  version = p_known_version;   -- <-- optimistic check

    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

    IF v_rows_updated = 0 THEN
        -- Either seat is no longer AVAILABLE, or version changed (concurrent update).
        RETURN 'FAILED: Seat was modified by another user. Please refresh and try again.';
    END IF;

    -- Fetch show_id for the booking record.
    SELECT show_id INTO v_show_id FROM seats WHERE seat_id = p_seat_id;

    INSERT INTO bookings (user_id, seat_id, show_id, payment_status)
    VALUES (p_user_id, p_seat_id, v_show_id, 'PAID')
    RETURNING booking_id INTO v_booking_id;

    RETURN 'SUCCESS: Booking confirmed. Booking ID = ' || v_booking_id;

EXCEPTION
    WHEN OTHERS THEN
        RETURN 'FAILED: ' || SQLERRM;
END;
$$;

-- ============================================================
-- Simulation: two users read seat 5 at version 0 and then
-- both attempt to book it.
-- ============================================================

-- Both sessions observe version = 0
SELECT seat_id, seat_number, status, version FROM seats WHERE seat_id = 5;

-- Session 1 succeeds (version 0 matches)
BEGIN;
    SELECT book_seat_optimistic(1, 5, 0);
COMMIT;

-- Session 2 fails (version is now 1, not 0)
BEGIN;
    SELECT book_seat_optimistic(2, 5, 0);
COMMIT;

-- Confirm the version incremented
SELECT seat_id, seat_number, status, version FROM seats WHERE seat_id = 5;
-- ============================================================
-- Advanced Ticket Booking System
-- File: 07_failure_rollback.sql
-- Description: Q6 — Simulates payment failure after a seat is
--              locked, and ensures the seat is released via ROLLBACK.
-- ============================================================

-- ============================================================
-- Scenario
-- A user selects a seat. The system locks it and inserts a
-- booking with status PENDING. Payment is then attempted.
-- If payment fails, the entire transaction is rolled back:
--   - The seat returns to AVAILABLE
--   - The booking record is removed
--   - No phantom booking remains in the system
-- ============================================================

CREATE OR REPLACE FUNCTION book_seat_with_payment(
    p_user_id       INT,
    p_seat_id       INT,
    p_payment_ok    BOOLEAN   -- pass FALSE to simulate a payment failure
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_seat_status   VARCHAR(10);
    v_show_id       INT;
    v_booking_id    INT;
BEGIN
    -- Step 1: Lock the seat with NOWAIT.
    SELECT status, show_id
    INTO   v_seat_status, v_show_id
    FROM   seats
    WHERE  seat_id = p_seat_id
    FOR UPDATE NOWAIT;

    IF v_seat_status <> 'AVAILABLE' THEN
        RETURN 'FAILED: Seat is already ' || v_seat_status;
    END IF;

    -- Step 2: Tentatively mark seat as LOCKED.
    UPDATE seats
    SET    status    = 'LOCKED',
           locked_at = CURRENT_TIMESTAMP,
           locked_by = p_user_id
    WHERE  seat_id = p_seat_id;

    -- Step 3: Insert a PENDING booking record.
    INSERT INTO bookings (user_id, seat_id, show_id, payment_status)
    VALUES (p_user_id, p_seat_id, v_show_id, 'PENDING')
    RETURNING booking_id INTO v_booking_id;

    -- Step 4: Simulate payment gateway call.
    IF NOT p_payment_ok THEN
        -- Payment failed. Raise an exception to trigger ROLLBACK.
        -- PostgreSQL will undo both the UPDATE on seats and the INSERT
        -- into bookings, restoring the seat to AVAILABLE automatically.
        RAISE EXCEPTION 'Payment declined by gateway for booking %', v_booking_id;
    END IF;

    -- Step 5: Payment succeeded — finalise the booking.
    UPDATE seats
    SET    status    = 'BOOKED',
           locked_at = NULL,
           locked_by = NULL
    WHERE  seat_id = p_seat_id;

    UPDATE bookings
    SET    payment_status = 'PAID',
           status         = 'CONFIRMED'
    WHERE  booking_id = v_booking_id;

    RETURN 'SUCCESS: Payment accepted. Booking ID = ' || v_booking_id;

EXCEPTION
    WHEN lock_not_available THEN
        RETURN 'FAILED: Seat is locked by another session.';

    WHEN OTHERS THEN
        -- Any exception (including the payment failure above) causes
        -- PostgreSQL to roll back all changes made in this function call.
        RETURN 'FAILED (rolled back): ' || SQLERRM;
END;
$$;

-- ============================================================
-- Test 1: Successful payment — seat should become BOOKED
-- ============================================================
BEGIN;
    SELECT book_seat_with_payment(1, 1, TRUE);
COMMIT;

-- Verify
SELECT seat_id, status, locked_by FROM seats WHERE seat_id = 1;
SELECT booking_id, payment_status, status FROM bookings WHERE seat_id = 1;

-- ============================================================
-- Test 2: Payment failure — seat should remain AVAILABLE
-- ============================================================
BEGIN;
    SELECT book_seat_with_payment(2, 2, FALSE);
COMMIT;

-- Seat 2 must still be AVAILABLE and no booking record should exist.
SELECT seat_id, status FROM seats WHERE seat_id = 2;
SELECT COUNT(*) AS booking_count FROM bookings WHERE seat_id = 2;
-- ============================================================
-- Advanced Ticket Booking System
-- File: 08_isolation_levels.sql
-- Description: Q7 — Tests READ COMMITTED and SERIALIZABLE
--              isolation levels and explains their impact on
--              seat availability and booking consistency.
-- ============================================================

-- ============================================================
-- PostgreSQL Isolation Level Reference
--
-- Level              | Dirty Read | Non-Repeatable Read | Phantom Read
-- -------------------|------------|---------------------|-------------
-- READ COMMITTED      | Not possible | Possible          | Possible
-- REPEATABLE READ     | Not possible | Not possible      | Not possible (PG)
-- SERIALIZABLE        | Not possible | Not possible      | Not possible
-- ============================================================

-- ============================================================
-- PART A: READ COMMITTED (PostgreSQL default)
-- ============================================================
-- Each statement in the transaction sees data committed just
-- before that statement ran. A seat that was AVAILABLE at the
-- start of a transaction may appear BOOKED when re-read later
-- in the same transaction if another session commits between
-- the two reads.
-- ============================================================

-- Session 1 (READ COMMITTED — default)
BEGIN;
    -- First read: seat 3 is AVAILABLE
    SELECT seat_id, status FROM seats WHERE seat_id = 3;

    -- (Another session commits a booking on seat 3 here)

    -- Second read: seat 3 now shows BOOKED — non-repeatable read
    SELECT seat_id, status FROM seats WHERE seat_id = 3;
COMMIT;

-- Session 2: commits between Session 1's two reads
BEGIN;
    UPDATE seats SET status = 'BOOKED' WHERE seat_id = 3;
    INSERT INTO bookings (user_id, seat_id, show_id, payment_status)
    VALUES (4, 3, 1, 'PAID');
COMMIT;

-- Impact on ticket booking:
-- Under READ COMMITTED, two users who each check availability may both
-- see AVAILABLE at the same instant. Whichever runs the UPDATE first
-- wins; the second will either update a BOOKED row (and find 0 rows
-- affected) or be blocked by a FOR UPDATE lock. This is why the
-- FOR UPDATE in book_seat() is essential even under READ COMMITTED.


-- ============================================================
-- PART B: SERIALIZABLE
-- ============================================================
-- Transactions execute as if they ran one at a time. PostgreSQL
-- uses Serializable Snapshot Isolation (SSI) to detect
-- read/write conflicts without locking. If two serializable
-- transactions conflict, one is aborted with:
--   ERROR: could not serialize access due to concurrent update
-- The application must catch this error and retry.
-- ============================================================

-- Session 1 (SERIALIZABLE)
BEGIN ISOLATION LEVEL SERIALIZABLE;
    -- Reads available seats for show 1
    SELECT seat_id, status FROM seats WHERE show_id = 1 AND status = 'AVAILABLE';

    -- ... user selects seat 4 ...

    -- Attempts booking (may fail with serialization error if Session 2
    -- has also modified overlapping rows and committed first)
    UPDATE seats SET status = 'BOOKED' WHERE seat_id = 4 AND status = 'AVAILABLE';
    INSERT INTO bookings (user_id, seat_id, show_id, payment_status)
    VALUES (1, 4, 1, 'PAID');
COMMIT;
-- If another serializable transaction committed a conflicting change,
-- this COMMIT raises: ERROR 40001: could not serialize access.
-- The application should catch code 40001 and retry the transaction.


-- Session 2 (SERIALIZABLE) — concurrent with Session 1
BEGIN ISOLATION LEVEL SERIALIZABLE;
    SELECT seat_id, status FROM seats WHERE show_id = 1 AND status = 'AVAILABLE';

    UPDATE seats SET status = 'BOOKED' WHERE seat_id = 4 AND status = 'AVAILABLE';
    INSERT INTO bookings (user_id, seat_id, show_id, payment_status)
    VALUES (2, 4, 1, 'PAID');
COMMIT;


-- ============================================================
-- Summary comparison
-- ============================================================
-- READ COMMITTED:
--   Advantage  : Lower overhead; works well when combined with
--                FOR UPDATE NOWAIT (as in this project).
--   Disadvantage: Non-repeatable reads require explicit locking.
--
-- SERIALIZABLE:
--   Advantage  : Strongest consistency guarantee; no phantom reads.
--   Disadvantage: Higher abort rate; application must implement retry
--                 logic for error code 40001.
--
-- Recommendation for this system:
--   Use READ COMMITTED (default) + FOR UPDATE NOWAIT for maximum
--   throughput with guaranteed no double booking. Switch to
--   SERIALIZABLE only if multi-row invariants must be enforced
--   without explicit locking throughout the application.
-- ============================================================
-- ============================================================
-- Advanced Ticket Booking System
-- File: 09_bonus_timeout_queue.sql
-- Description: Q8 — Auto-release locked seats after timeout and
--              maintain a waiting queue for fully booked shows.
-- ============================================================

-- ============================================================
-- PART A: Auto-release seats locked beyond a timeout
-- ============================================================
-- Seats that are LOCKED (user started booking but did not
-- complete payment) should be released after a configurable
-- timeout so they become available to other users.
-- This function is designed to be called by a cron job or a
-- pg_cron scheduled task every minute.
-- ============================================================

CREATE OR REPLACE FUNCTION release_expired_locks(p_timeout_minutes INT DEFAULT 10)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_released_count INT;
BEGIN
    -- Release any seat that has been LOCKED longer than the timeout.
    UPDATE seats
    SET    status    = 'AVAILABLE',
           locked_at = NULL,
           locked_by = NULL
    WHERE  status    = 'LOCKED'
      AND  locked_at < (CURRENT_TIMESTAMP - (p_timeout_minutes || ' minutes')::INTERVAL);

    GET DIAGNOSTICS v_released_count = ROW_COUNT;

    RETURN v_released_count || ' seat(s) released after ' || p_timeout_minutes || '-minute timeout.';
END;
$$;

-- Manual execution (called by scheduler in production)
SELECT release_expired_locks(10);

-- Observe: seats with locked_at older than 10 minutes return to AVAILABLE
SELECT seat_id, seat_number, status, locked_at FROM seats WHERE status = 'LOCKED';


-- ============================================================
-- PART B: Waiting queue for fully booked shows
-- ============================================================
-- When all seats for a show are BOOKED, new users are placed on
-- a waiting queue. When a seat is released (cancellation or
-- timeout), the first user in the queue is notified.
-- ============================================================

-- Function to add a user to the waiting list
CREATE OR REPLACE FUNCTION join_waiting_queue(p_user_id INT, p_show_id INT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_available_count INT;
BEGIN
    -- Check whether any seat is still AVAILABLE.
    SELECT COUNT(*)
    INTO   v_available_count
    FROM   seats
    WHERE  show_id = p_show_id
      AND  status  = 'AVAILABLE';

    IF v_available_count > 0 THEN
        RETURN 'INFO: Seats are still available for this show. Please book directly.';
    END IF;

    -- Seat exists in queue already?
    IF EXISTS (
        SELECT 1 FROM waiting_queue
        WHERE  user_id = p_user_id AND show_id = p_show_id AND status = 'WAITING'
    ) THEN
        RETURN 'INFO: You are already in the waiting queue for this show.';
    END IF;

    INSERT INTO waiting_queue (user_id, show_id)
    VALUES (p_user_id, p_show_id);

    RETURN 'SUCCESS: You have been added to the waiting queue.';
END;
$$;


-- Function to notify the first person in the queue when a seat opens
CREATE OR REPLACE FUNCTION notify_next_in_queue(p_show_id INT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_queue_id  INT;
    v_user_id   INT;
    v_username  VARCHAR(100);
BEGIN
    -- Get the user who has been waiting the longest.
    SELECT q.queue_id, q.user_id, u.username
    INTO   v_queue_id, v_user_id, v_username
    FROM   waiting_queue q
    JOIN   users         u ON u.user_id = q.user_id
    WHERE  q.show_id = p_show_id
      AND  q.status  = 'WAITING'
    ORDER BY q.requested_at ASC
    LIMIT 1;

    IF v_queue_id IS NULL THEN
        RETURN 'INFO: No users in the waiting queue for this show.';
    END IF;

    -- Mark them as NOTIFIED.
    UPDATE waiting_queue
    SET    status = 'NOTIFIED'
    WHERE  queue_id = v_queue_id;

    -- In production, send an email/SMS here using pg_notify or an external hook.
    RETURN 'NOTIFIED: User "' || v_username || '" (user_id=' || v_user_id || ') has been notified.';
END;
$$;


-- ============================================================
-- Combining both: cancel a booking, release seat, notify queue
-- ============================================================
CREATE OR REPLACE FUNCTION cancel_booking(p_booking_id INT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_seat_id INT;
    v_show_id INT;
    v_notify  TEXT;
BEGIN
    -- Fetch and validate the booking.
    SELECT seat_id, show_id INTO v_seat_id, v_show_id
    FROM   bookings
    WHERE  booking_id = p_booking_id AND status = 'CONFIRMED';

    IF v_seat_id IS NULL THEN
        RETURN 'FAILED: Booking not found or already cancelled.';
    END IF;

    -- Cancel the booking.
    UPDATE bookings SET status = 'CANCELLED' WHERE booking_id = p_booking_id;

    -- Release the seat.
    UPDATE seats
    SET    status    = 'AVAILABLE',
           locked_at = NULL,
           locked_by = NULL,
           version   = version + 1
    WHERE  seat_id = v_seat_id;

    -- Notify the next person in the waiting queue.
    v_notify := notify_next_in_queue(v_show_id);

    RETURN 'Booking #' || p_booking_id || ' cancelled. Seat released. ' || v_notify;
END;
$$;


-- ============================================================
-- Usage examples
-- ============================================================

-- Add users to queue for show 3 (fully booked)
SELECT join_waiting_queue(1, 3);
SELECT join_waiting_queue(2, 3);
SELECT join_waiting_queue(3, 3);

-- View current queue
SELECT q.queue_id, u.username, q.requested_at, q.status
FROM   waiting_queue q
JOIN   users         u ON u.user_id = q.user_id
WHERE  q.show_id = 3
ORDER BY q.requested_at;

-- Simulate cancellation (booking_id 1) — seat released, first user notified
SELECT cancel_booking(1);

-- Run scheduled timeout job
SELECT release_expired_locks(10);
-- ============================================================
-- Advanced Ticket Booking System
-- File: 10_verification_queries.sql
-- Description: Useful queries to inspect system state after
--              running through all scenarios.
-- ============================================================

-- All users
SELECT user_id, username, email FROM users;

-- All shows with seat availability summary
SELECT
    sh.show_id,
    sh.title,
    sh.venue,
    sh.show_datetime,
    COUNT(s.seat_id)                                         AS total_seats,
    SUM(CASE WHEN s.status = 'AVAILABLE' THEN 1 ELSE 0 END) AS available,
    SUM(CASE WHEN s.status = 'LOCKED'    THEN 1 ELSE 0 END) AS locked,
    SUM(CASE WHEN s.status = 'BOOKED'    THEN 1 ELSE 0 END) AS booked
FROM   shows sh
JOIN   seats s ON s.show_id = sh.show_id
GROUP BY sh.show_id, sh.title, sh.venue, sh.show_datetime
ORDER BY sh.show_id;

-- All seats with current status
SELECT
    s.seat_id,
    sh.title         AS show_title,
    s.seat_number,
    s.status,
    s.version,
    s.locked_at,
    u.username       AS locked_by_user
FROM   seats s
JOIN   shows  sh ON sh.show_id = s.show_id
LEFT JOIN users u  ON u.user_id = s.locked_by
ORDER BY s.show_id, s.seat_number;

-- All confirmed bookings
SELECT
    b.booking_id,
    u.username,
    sh.title         AS show_title,
    s.seat_number,
    b.booked_at,
    b.status,
    b.payment_status
FROM   bookings b
JOIN   users    u  ON u.user_id  = b.user_id
JOIN   shows    sh ON sh.show_id = b.show_id
JOIN   seats    s  ON s.seat_id  = b.seat_id
ORDER BY b.booked_at;

-- Waiting queue status
SELECT
    q.queue_id,
    u.username,
    sh.title    AS show_title,
    q.requested_at,
    q.status
FROM   waiting_queue q
JOIN   users         u  ON u.user_id  = q.user_id
JOIN   shows         sh ON sh.show_id = q.show_id
ORDER BY q.show_id, q.requested_at;

-- Seats currently locked and past timeout (should be released)
SELECT
    s.seat_id,
    s.seat_number,
    sh.title        AS show_title,
    u.username      AS locked_by,
    s.locked_at,
    EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - s.locked_at)) / 60 AS locked_minutes_ago
FROM   seats s
JOIN   shows  sh ON sh.show_id = s.show_id
LEFT JOIN users u  ON u.user_id = s.locked_by
WHERE  s.status    = 'LOCKED'
  AND  s.locked_at < CURRENT_TIMESTAMP - INTERVAL '10 minutes';
