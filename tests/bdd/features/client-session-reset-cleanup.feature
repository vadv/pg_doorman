@rust @rust-3 @client-session-reset-cleanup
Feature: Client reset commands preserve safe backend cleanup tracking
  PostgreSQL uses the same RESET command tag for RESET ALL and RESET one_guc.
  pg_doorman must conservatively retain SET cleanup after either tag so that
  resetting one setting cannot leak another setting to the next client.
  Unambiguous DISCARD ALL and CLOSE ALL tags can still suppress their cleanup.

  Each scenario logs SQL on PostgreSQL. RESET ROLE identifies pg_doorman's
  selective cleanup batch.

  Background:
    Given PostgreSQL started with options "-c log_statement=all -c logging_collector=off" and pg_hba.conf:
      """
      local all all trust
      host all all 127.0.0.1/32 trust
      """
    And fixtures from "tests/fixture.sql" applied
    And pg_doorman started with config:
      """
      [general]
      host = "127.0.0.1"
      port = ${DOORMAN_PORT}
      admin_username = "admin"
      admin_password = "admin"
      pg_hba.content = "host all all 127.0.0.1/32 trust"
      prepared_statements = true
      prepared_statements_cache_size = 100

      [pools.example_db]
      server_host = "127.0.0.1"
      server_port = ${PG_PORT}
      pool_mode = "transaction"

      [[pools.example_db.users]]
      username = "example_user_1"
      password = ""
      pool_size = 1

      [pools.example_db_session]
      server_host = "127.0.0.1"
      server_port = ${PG_PORT}
      server_database = "example_db"
      pool_mode = "session"

      [[pools.example_db_session.users]]
      username = "example_user_1"
      password = ""
      pool_size = 1
      """

  @client-session-reset-cleanup-pgx-batch
  Scenario: pgx-style session reset batch conservatively retains SET cleanup
    When we create session "one" to pg_doorman as "example_user_1" with password "" and database "example_db"
    # Warm the pool with a trivial query so that server auth and any startup
    # chatter is already in the log before we start asserting on it.
    And we send SimpleQuery "SELECT 1" to session "one"
    And we sleep 100ms
    When we truncate PostgreSQL log
    # Exactly the batch jackc/pgx emits on an internal context deadline.
    And we send SimpleQuery "SET SESSION AUTHORIZATION DEFAULT; RESET ALL; CLOSE ALL; UNLISTEN *; SELECT pg_advisory_unlock_all(); DISCARD PLANS; DISCARD SEQUENCES; DISCARD TEMP" to session "one"
    And we sleep 300ms
    # RESET's ambiguous command tag cannot prove that every GUC was reset.
    # The client batch and the conservative checkin cleanup each reset GUCs.
    Then PostgreSQL log should contain exactly 2 occurrences of "RESET ALL"
    And PostgreSQL log should contain "RESET ROLE"

  @client-session-reset-cleanup-real-set-still-cleans
  Scenario: a genuine SET still arms the checkin cleanup
    # Baseline: if the client actually mutates session state and does not
    # follow up with DISCARD ALL, pg_doorman must still clean up on checkin.
    # This guards against the fix over-correcting and swallowing real cleanups.
    When we create session "two" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT 1" to session "two"
    And we sleep 100ms
    When we truncate PostgreSQL log
    And we send SimpleQuery "SET statement_timeout = 1000" to session "two"
    And we sleep 300ms
    # Client sent `RESET ALL` zero times — the one we expect is pg_doorman's.
    Then PostgreSQL log should contain exactly 1 occurrences of "RESET ALL"
    And PostgreSQL log should contain "RESET ROLE"

  @client-session-reset-cleanup-discard-all
  Scenario: DISCARD ALL after SET suppresses doorman-side cleanup (session mode)
    # DISCARD ALL cannot run inside an implicit transaction block, so it has to
    # be sent as a standalone SimpleQuery. That only works with session mode,
    # where pg_doorman keeps the same server connection across multiple client
    # queries and defers checkin_cleanup until the client disconnects.
    When we create session "three" to pg_doorman as "example_user_1" with password "" and database "example_db_session"
    And we send SimpleQuery "SELECT 1" to session "three"
    And we sleep 100ms
    When we truncate PostgreSQL log
    # SET arms set-cleanup; a subsequent DISCARD ALL in the same session must
    # disarm every cleanup flag because DISCARD ALL is semantically
    # `RESET ALL; DEALLOCATE ALL; CLOSE ALL; UNLISTEN *; ...`.
    And we send SimpleQuery "SET statement_timeout = 1000" to session "three"
    And we send SimpleQuery "DISCARD ALL" to session "three"
    # Close the session so pg_doorman returns the server connection and runs
    # checkin_cleanup — which must be a no-op thanks to the DISCARD ALL disarm.
    And we close session "three"
    And we sleep 300ms
    Then PostgreSQL log should contain "DISCARD ALL"
    # No `RESET ALL` from either side: client did not issue one, and pg_doorman
    # learned from the DISCARD ALL tag that the session is already clean.
    And PostgreSQL log should not contain "RESET ROLE"
    And PostgreSQL log should contain exactly 0 occurrences of "RESET ALL"

  @client-session-reset-cleanup-close-all-disarms-declare
  Scenario: CLOSE ALL in the same batch as DECLARE suppresses declare cleanup
    When we create session "four" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT 1" to session "four"
    And we sleep 100ms
    When we truncate PostgreSQL log
    # DECLARE CURSOR arms declare cleanup (CLOSE ALL on checkin); the same batch
    # explicitly closes every cursor, so pg_doorman must recognise the server
    # state is already clean and skip its own CLOSE ALL.
    And we send SimpleQuery "BEGIN; DECLARE doorman_cur CURSOR FOR SELECT 1; CLOSE ALL; COMMIT" to session "four"
    And we sleep 300ms
    # Sanity-check the client batch is actually in the log (PostgreSQL logs the
    # whole simple-query string on one line when log_statement = 'all').
    Then PostgreSQL log should contain "DECLARE doorman_cur"
    # And the marker for pg_doorman's own checkin cleanup is absent.
    And PostgreSQL log should not contain "RESET ROLE"

  @client-session-reset-cleanup-per-guc-reset
  Scenario: Resetting one GUC does not leak another GUC to the next client
    When we create session "five" to pg_doorman as "example_user_1" with password "" and database "example_db_session"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "five" and store backend_pid
    And we sleep 100ms
    When we truncate PostgreSQL log
    And we send SimpleQuery "SET statement_timeout = 1000" to session "five"
    And we send SimpleQuery "RESET lock_timeout" to session "five"
    And we close session "five"
    And we sleep 300ms
    Then PostgreSQL log should contain "RESET lock_timeout"
    And PostgreSQL log should contain "RESET ROLE"
    When we create session "next" to pg_doorman as "example_user_1" with password "" and database "example_db_session"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "next" and store backend_pid
    Then backend_pid from session "next" should equal backend_pid from session "five"
    When we send SimpleQuery "SHOW statement_timeout" to session "next" and store response
    Then session "next" should receive DataRow with "0"
    And session "next" should receive ReadyForQuery "I"

  @client-session-reset-cleanup-single-close-keeps-armed
  Scenario: Closing one named cursor does not disarm declare-cleanup
    # Only `CLOSE CURSOR ALL` carries the disarm semantics. Closing a single
    # named cursor emits `CLOSE CURSOR` (no ALL), which leaves other cursors
    # open and must not clear the cleanup flag. pg_doorman has to follow up
    # with its own `CLOSE ALL` on checkin.
    When we create session "six" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT 1" to session "six"
    And we sleep 100ms
    When we truncate PostgreSQL log
    And we send SimpleQuery "BEGIN; DECLARE doorman_c1 CURSOR FOR SELECT 1; DECLARE doorman_c2 CURSOR FOR SELECT 2; CLOSE doorman_c1; COMMIT" to session "six"
    And we sleep 300ms
    # The client closed only c1 — c2 is still defined on the server until the
    # implicit transaction ended via COMMIT, so pg_doorman stayed armed and
    # issued its own cleanup batch.
    Then PostgreSQL log should contain "RESET ROLE"
    And PostgreSQL log should contain "CLOSE ALL"

  @client-session-reset-cleanup-error-arms-prepare
  Scenario: PostgreSQL error arms prepare-cleanup, forcing DEALLOCATE ALL on checkin
    # Baseline for the prepare-cleanup path: an ErrorResponse while the
    # prepared-statement cache is enabled sets `needs_cleanup_prepare`, and
    # pg_doorman must still issue `DEALLOCATE ALL` on checkin.
    When we create session "seven" to pg_doorman as "example_user_1" with password "" and database "example_db_session"
    And we send SimpleQuery "SELECT 1" to session "seven"
    And we sleep 100ms
    When we truncate PostgreSQL log
    And we send SimpleQuery "SELECT 1/0" to session "seven" expecting error
    And we close session "seven"
    And we sleep 300ms
    Then PostgreSQL log should contain "DEALLOCATE ALL"

  @client-session-reset-cleanup-discard-after-error
  Scenario: DISCARD ALL after a PostgreSQL error disarms prepare-cleanup
    # After the error arms `needs_cleanup_prepare`, a subsequent DISCARD ALL
    # clears every cleanup flag. No redundant `DEALLOCATE ALL` on checkin.
    When we create session "eight" to pg_doorman as "example_user_1" with password "" and database "example_db_session"
    And we send SimpleQuery "SELECT 1" to session "eight"
    And we sleep 100ms
    When we truncate PostgreSQL log
    And we send SimpleQuery "SELECT 1/0" to session "eight" expecting error
    And we send SimpleQuery "DISCARD ALL" to session "eight"
    And we close session "eight"
    And we sleep 300ms
    Then PostgreSQL log should contain "DISCARD ALL"
    # Neither the client nor pg_doorman issued DEALLOCATE ALL.
    And PostgreSQL log should contain exactly 0 occurrences of "DEALLOCATE ALL"
    And PostgreSQL log should not contain "RESET ROLE"
