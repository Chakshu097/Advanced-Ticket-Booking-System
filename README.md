# Advanced Ticket Booking System

A PostgreSQL-based ticket booking system built to handle high-concurrency scenarios. The project covers database design, transaction safety, deadlock prevention, optimistic locking, and failure recovery — implemented entirely in SQL with documented examples for each scenario.

This is an MCA DBMS practical mini-project.

---

## Table of Contents

- [Project Overview](#project-overview)
- [Database Schema](#database-schema)
- [Setup Instructions](#setup-instructions)
- [File Structure](#file-structure)
- [Task Breakdown](#task-breakdown)
  - [Q1 — Database Design](#q1--database-design)
  - [Q2 — Transaction-Safe Booking](#q2--transaction-safe-booking)
  - [Q3 — Parallel Booking with SKIP LOCKED](#q3--parallel-booking-with-skip-locked)
  - [Q4 — Deadlock Simulation and Prevention](#q4--deadlock-simulation-and-prevention)
  - [Q5 — Optimistic Locking](#q5--optimistic-locking)
  - [Q6 — Failure and Rollback Handling](#q6--failure-and-rollback-handling)
  - [Q7 — Isolation Level Analysis](#q7--isolation-level-analysis)
  - [Q8 — Auto-Release Timeout and Waiting Queue](#q8--auto-release-timeout-and-waiting-queue)
- [Key Concepts Used](#key-concepts-used)
- [Expected Outcomes](#expected-outcomes)

---

## Project Overview

The system models a scenario where many users book seats for shows (movies, concerts, events) at the same time. The main challenges it addresses are:

- Preventing two users from booking the same seat (double booking)
- Handling payment failures without leaving the system in an inconsistent state
- Allowing multiple users to book different seats simultaneously without blocking each other
- Avoiding deadlocks when multiple seats are locked in a single transaction
- Releasing seats that were locked but never confirmed

---

## Database Schema

The schema consists of five tables:

```
users
  user_id (PK), username, email, phone, created_at

shows
  show_id (PK), title, venue, show_datetime, total_seats, created_at

seats
  seat_id (PK), show_id (FK), seat_number, status, version, locked_at, locked_by

bookings
  booking_id (PK), user_id (FK), seat_id (FK), show_id (FK), booked_at, status, payment_status

waiting_queue
  queue_id (PK), user_id (FK), show_id (FK), requested_at, status
```

The `version` column in `seats` supports optimistic locking. The `locked_at` and `locked_by` columns track when and by whom a seat was tentatively locked during the payment process.

---

## Setup Instructions

### Prerequisites

- PostgreSQL 13 or higher
- `psql` command-line client or any SQL client (pgAdmin, DBeaver, TablePlus)

### Steps

1. Clone the repository:

```bash
git clone https://github.com/your-username/ticket-booking-system.git
cd ticket-booking-system
```

2. Create the database:

```bash
createdb ticket_booking
```

3. Run the SQL files in order:

```bash
psql -d ticket_booking -f sql/01_schema.sql
psql -d ticket_booking -f sql/02_seed_data.sql
psql -d ticket_booking -f sql/03_booking_transaction.sql
psql -d ticket_booking -f sql/04_parallel_booking.sql
psql -d ticket_booking -f sql/05_deadlock_simulation.sql
psql -d ticket_booking -f sql/06_optimistic_locking.sql
psql -d ticket_booking -f sql/07_failure_rollback.sql
psql -d ticket_booking -f sql/08_isolation_levels.sql
psql -d ticket_booking -f sql/09_bonus_timeout_queue.sql
```

4. Run verification queries to inspect system state:

```bash
psql -d ticket_booking -f sql/10_verification_queries.sql
```

> Note: Files 03 through 09 define functions and include example usage. To test deadlock scenarios (Q4) and isolation levels (Q7), open two separate `psql` sessions and run the indicated blocks interleaved, as described in the comments inside each file.

---

## File Structure

```
ticket-booking-system/
├── README.md
└── sql/
    ├── 01_schema.sql               -- Table definitions, constraints, indexes
    ├── 02_seed_data.sql            -- Sample users, shows, and seats
    ├── 03_booking_transaction.sql  -- Q2: book_seat() with FOR UPDATE NOWAIT
    ├── 04_parallel_booking.sql     -- Q3: book_next_available_seat() with SKIP LOCKED
    ├── 05_deadlock_simulation.sql  -- Q4: deadlock scenario and prevention
    ├── 06_optimistic_locking.sql   -- Q5: book_seat_optimistic() with version check
    ├── 07_failure_rollback.sql     -- Q6: payment failure and automatic rollback
    ├── 08_isolation_levels.sql     -- Q7: READ COMMITTED vs SERIALIZABLE
    ├── 09_bonus_timeout_queue.sql  -- Q8: timeout release and waiting queue
    └── 10_verification_queries.sql -- Inspection queries for all tables
```

---

## Task Breakdown

### Q1 — Database Design

**File:** `sql/01_schema.sql`

Five tables are created with appropriate primary keys, foreign keys, and check constraints. The `seats` table includes a `status` column constrained to `AVAILABLE`, `LOCKED`, or `BOOKED`. Indexes are added on frequently filtered columns to support concurrent query performance.

---

### Q2 — Transaction-Safe Booking

**File:** `sql/03_booking_transaction.sql`

The `book_seat(p_user_id, p_seat_id)` function performs a booking in a single atomic operation:

1. Acquires an exclusive row lock using `SELECT ... FOR UPDATE NOWAIT`. If the row is already locked, an exception is raised immediately rather than waiting.
2. Checks that the seat status is `AVAILABLE`.
3. Updates the seat status to `BOOKED`.
4. Inserts a confirmed record into the `bookings` table.
5. On any exception, PostgreSQL rolls back all changes automatically.

**Example:**

```sql
BEGIN;
    SELECT book_seat(1, 1);
COMMIT;
```

---

### Q3 — Parallel Booking with SKIP LOCKED

**File:** `sql/04_parallel_booking.sql`

The `book_next_available_seat(p_user_id, p_show_id)` function allows multiple sessions to book seats at the same time without blocking each other. It uses `FOR UPDATE SKIP LOCKED`, which skips rows that are already locked by another transaction and picks the next available one. This eliminates queuing at the database level and improves throughput significantly under concurrent load.

---

### Q4 — Deadlock Simulation and Prevention

**File:** `sql/05_deadlock_simulation.sql`

**Part A — Simulation:**

A deadlock is created by having two transactions lock the same two rows in opposite order:

- Session 1 locks seat 1, then tries to lock seat 2
- Session 2 locks seat 2, then tries to lock seat 1

PostgreSQL detects the cycle and aborts one transaction with error code `40P01`.

**Part B — Prevention:**

The `book_multiple_seats(p_user_id, p_seat_ids[])` function prevents deadlocks by always locking seats in ascending `seat_id` order using `ORDER BY seat_id ASC`. When all transactions acquire locks in the same sequence, circular waits cannot form.

---

### Q5 — Optimistic Locking

**File:** `sql/06_optimistic_locking.sql`

The `seats` table has a `version` integer column. The `book_seat_optimistic(p_user_id, p_seat_id, p_known_version)` function:

1. Reads the seat without acquiring any lock.
2. At update time, includes `AND version = p_known_version` in the `WHERE` clause.
3. If 0 rows are updated, another user has already modified the row — the booking is rejected.
4. On success, `version` is incremented by 1.

This approach is suitable for workloads with many reads and few write conflicts, as it avoids holding locks during the user's decision time.

---

### Q6 — Failure and Rollback Handling

**File:** `sql/07_failure_rollback.sql`

The `book_seat_with_payment(p_user_id, p_seat_id, p_payment_ok)` function simulates a real two-phase booking:

1. The seat is locked and set to `LOCKED`.
2. A `PENDING` booking record is inserted.
3. Payment is attempted.

If payment fails, a `RAISE EXCEPTION` is triggered. PostgreSQL rolls back the entire transaction, including the seat update and the booking insert. The seat automatically returns to `AVAILABLE` and no orphaned booking record is left in the database.

---

### Q7 — Isolation Level Analysis

**File:** `sql/08_isolation_levels.sql`

**READ COMMITTED (default):**

Each statement sees the most recently committed data at the time it runs. A row that was `AVAILABLE` at the start of a transaction may be `BOOKED` when read again later if another session committed between the two reads. This non-repeatable read behaviour makes explicit locking (`FOR UPDATE`) necessary.

**SERIALIZABLE:**

Transactions are guaranteed to produce results consistent with some serial (one-at-a-time) execution order. PostgreSQL uses Serializable Snapshot Isolation (SSI). If a conflict is detected, one transaction is aborted with error `40001` and must be retried by the application. This provides the strongest consistency guarantee but requires retry logic.

**Recommendation:** For this system, `READ COMMITTED` combined with `FOR UPDATE NOWAIT` provides sufficient consistency with better throughput. `SERIALIZABLE` is appropriate when multi-row invariants need to be enforced without explicit locking everywhere.

---

### Q8 — Auto-Release Timeout and Waiting Queue

**File:** `sql/09_bonus_timeout_queue.sql`

**Auto-release:**

The `release_expired_locks(p_timeout_minutes)` function resets any `LOCKED` seat whose `locked_at` timestamp is older than the specified timeout back to `AVAILABLE`. This function is designed to be called by a scheduler such as `pg_cron` or an external cron job.

```sql
-- Release seats locked for more than 10 minutes
SELECT release_expired_locks(10);
```

**Waiting queue:**

- `join_waiting_queue(p_user_id, p_show_id)` — adds a user to the queue when a show is fully booked.
- `notify_next_in_queue(p_show_id)` — marks the longest-waiting user as `NOTIFIED` when a seat opens up.
- `cancel_booking(p_booking_id)` — cancels a booking, releases the seat, and automatically triggers `notify_next_in_queue`.

---

## Key Concepts Used

| Concept | Where Used |
|---|---|
| FOR UPDATE NOWAIT | Q2, Q6 — exclusive lock with immediate failure |
| FOR UPDATE SKIP LOCKED | Q3 — parallel booking without blocking |
| Deadlock detection (40P01) | Q4 — observed in simulation |
| Consistent lock ordering | Q4 — prevention strategy |
| Optimistic locking (version column) | Q5 — lost update prevention |
| RAISE EXCEPTION + ROLLBACK | Q6 — payment failure recovery |
| READ COMMITTED isolation | Q7 — default PostgreSQL level |
| SERIALIZABLE isolation | Q7 — strongest consistency |
| Timeout-based seat release | Q8 — stale lock cleanup |
| Waiting queue with FIFO notification | Q8 — demand management |

---

## Expected Outcomes

- No double booking is possible regardless of concurrent load.
- A payment failure leaves zero trace in the database.
- Multiple users booking different seats do not block each other.
- Deadlocks are either detected and recovered from, or prevented by design.
- Seats locked by abandoned sessions are automatically freed after a configurable timeout.
- Users can join a waiting list when a show is full and are notified when a seat becomes available.
