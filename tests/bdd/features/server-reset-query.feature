@rust @rust-3 @server-reset-query
Feature: Configurable backend reset preserves session isolation
  A configured reset replaces selective cleanup on each backend release.
  It must finish successfully at ReadyForQuery Idle before the same connection
  can serve another client. PostgreSQL exercises the real wire flow here;
  the unsupported-feature NOTICE scenarios are fixtures, not live Greengage.

  Background:
    Given PostgreSQL started with options "-c log_statement=all -c logging_collector=off" and pg_hba.conf:
      """
      local all all trust
      host all all 127.0.0.1/32 trust
      """
    And fixtures from "tests/fixture.sql" applied

  @server-reset-query-session-reuse
  Scenario: Inherited full reset drains rowsets and cleans a reused session backend
    Given pg_doorman started with config:
      """
      [general]
      host = "127.0.0.1"
      port = ${DOORMAN_PORT}
      admin_username = "admin"
      admin_password = "admin"
      pg_hba.content = "host all all 127.0.0.1/32 trust"
      prepared_statements = true
      server_reset_query = "DO $$ BEGIN RAISE NOTICE 'reset progress'; END $$; SET SESSION AUTHORIZATION DEFAULT; RESET ALL; DEALLOCATE ALL; CLOSE ALL; UNLISTEN *; SELECT pg_advisory_unlock_all(); DISCARD PLANS; DISCARD SEQUENCES; DISCARD TEMP"

      [pools.example_db]
      server_host = "127.0.0.1"
      server_port = ${PG_PORT}
      pool_mode = "session"

      [[pools.example_db.users]]
      username = "example_user_1"
      password = ""
      pool_size = 1
      """
    When we create session "old" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "old" and store backend_pid
    And we send SimpleQuery "SET statement_timeout = 10000; CREATE TEMP TABLE reset_secret (value int); PREPARE reset_stmt AS SELECT 42; BEGIN; DECLARE reset_cursor CURSOR WITH HOLD FOR SELECT 1; COMMIT; LISTEN reset_channel" to session "old"
    And we send SimpleQuery "SELECT pg_advisory_lock(7654321)" to session "old"
    # Assert the fixture really dirtied every kind of state before release.
    And we send SimpleQuery "SELECT current_setting('statement_timeout') = '10s' AND to_regclass('pg_temp.reset_secret') IS NOT NULL AND EXISTS (SELECT FROM pg_prepared_statements WHERE name = 'reset_stmt') AND EXISTS (SELECT FROM pg_cursors WHERE name = 'reset_cursor') AND EXISTS (SELECT FROM pg_locks WHERE pid = pg_backend_pid() AND locktype = 'advisory') AND EXISTS (SELECT FROM pg_listening_channels())" to session "old" and store response
    Then session "old" should receive DataRow with "t"
    # A disconnected session may still own a transaction: rollback precedes reset.
    When we send SimpleQuery "BEGIN; INSERT INTO reset_secret VALUES (1)" to session "old" and store response
    Then session "old" should receive ReadyForQuery "T"
    When we close session "old"
    And we create session "next" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "next" and store backend_pid
    Then backend_pid from session "next" should equal backend_pid from session "old"
    When we send SimpleQuery "SELECT current_setting('statement_timeout') = '0' AND to_regclass('pg_temp.reset_secret') IS NULL AND NOT EXISTS (SELECT FROM pg_prepared_statements WHERE name = 'reset_stmt') AND NOT EXISTS (SELECT FROM pg_cursors WHERE name = 'reset_cursor') AND NOT EXISTS (SELECT FROM pg_locks WHERE pid = pg_backend_pid() AND locktype = 'advisory') AND NOT EXISTS (SELECT FROM pg_listening_channels())" to session "next" and store response
    Then session "next" should receive DataRow with "t"
    And session "next" should receive ReadyForQuery "I"

    When we send SimpleQuery "SET SESSION AUTHORIZATION example_user_2" to session "next"
    And we close session "next"
    And we create session "identity" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "identity" and store backend_pid
    Then backend_pid from session "identity" should equal backend_pid from session "old"
    When we send SimpleQuery "SELECT session_user = 'example_user_1' AND current_user = 'example_user_1'" to session "identity" and store response
    Then session "identity" should receive DataRow with "t"

  @server-reset-query-prepared-reuse
  Scenario: Pool override resets between transactions and cached client statements are reparsed
    Given pg_doorman started with config:
      """
      [general]
      host = "127.0.0.1"
      port = ${DOORMAN_PORT}
      admin_username = "admin"
      admin_password = "admin"
      pg_hba.content = "host all all 127.0.0.1/32 trust"
      prepared_statements = true
      prepared_statements_cache_size = 100
      server_reset_query = "SELECT 1 / 0"

      [pools.example_db]
      server_host = "127.0.0.1"
      server_port = ${PG_PORT}
      pool_mode = "transaction"
      server_reset_query = "SET SESSION AUTHORIZATION DEFAULT; RESET ALL; DEALLOCATE ALL; CLOSE ALL; UNLISTEN *; SELECT pg_advisory_unlock_all(); DISCARD PLANS; DISCARD SEQUENCES; DISCARD TEMP"

      [[pools.example_db.users]]
      username = "example_user_1"
      password = ""
      pool_size = 1
      """
    When we create session "one" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "one" and store backend_pid as "before_reset"
    And we send Parse "cached" with query "SELECT $1::int + 10" to session "one"
    And we send Bind "" to "cached" with params "1" to session "one"
    And we send Execute "" to session "one"
    And we send Sync to session "one"
    Then session "one" should receive DataRow with "11"
    And session "one" should receive ReadyForQuery "I"
    # No second client Parse: the pooler's server LRU must reflect DEALLOCATE ALL.
    When we send Bind "" to "cached" with params "2" to session "one"
    And we send Execute "" to session "one"
    And we send Sync to session "one"
    Then session "one" should receive DataRow with "12"
    When we send SimpleQuery "SELECT pg_backend_pid()" to session "one" and store backend_pid as "after_reset"
    Then named backend_pid "after_reset" from session "one" is same as "before_reset"
    When we send SimpleQuery "SELECT count(*) FROM pg_prepared_statements" to session "one" and store response
    Then session "one" should receive DataRow with "0"
    And session "one" should receive ReadyForQuery "I"
    # Check another client can use the released backend after row-returning reset.
    When we create session "two" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send Parse "cached" with query "SELECT $1::int + 10" to session "two"
    And we send Bind "" to "cached" with params "3" to session "two"
    And we send Execute "" to session "two"
    And we send Sync to session "two"
    Then session "two" should receive DataRow with "13"
    And session "two" should receive ReadyForQuery "I"

  @server-reset-query-retire
  Scenario Outline: Failed or incomplete reset retires the dirty backend
    Given pg_doorman started with config:
      """
      [general]
      host = "127.0.0.1"
      port = ${DOORMAN_PORT}
      admin_username = "admin"
      admin_password = "admin"
      pg_hba.content = "host all all 127.0.0.1/32 trust"
      prepared_statements = true
      server_reset_query = "<reset_query>"

      [pools.example_db]
      server_host = "127.0.0.1"
      server_port = ${PG_PORT}
      pool_mode = "session"

      [[pools.example_db.users]]
      username = "example_user_1"
      password = ""
      pool_size = 1
      """
    When we create session "old" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "old" and store backend_pid
    And we send SimpleQuery "SET statement_timeout = 10000; CREATE TEMP TABLE reset_secret (value int); PREPARE reset_stmt AS SELECT 42" to session "old"
    And we send SimpleQuery "SELECT current_setting('statement_timeout') = '10s' AND to_regclass('pg_temp.reset_secret') IS NOT NULL AND EXISTS (SELECT FROM pg_prepared_statements WHERE name = 'reset_stmt')" to session "old" and store response
    Then session "old" should receive DataRow with "t"
    When we close session "old"
    And we create session "next" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "next" and store backend_pid
    Then backend_pid from session "next" should not equal backend_pid from session "old"
    When we send SimpleQuery "SELECT current_setting('statement_timeout') = '0' AND to_regclass('pg_temp.reset_secret') IS NULL AND NOT EXISTS (SELECT FROM pg_prepared_statements WHERE name = 'reset_stmt')" to session "next" and store response
    Then session "next" should receive DataRow with "t"
    And session "next" should receive ReadyForQuery "I"

    Examples:
      | reset_query                                                                                              |
      | RESET ALL; DEALLOCATE ALL; SELECT 1 / 0; DISCARD TEMP                                                       |
      | DO $$ BEGIN RAISE NOTICE USING ERRCODE = '0AM01', MESSAGE = 'command without clusterwide effect'; END $$    |
      | DO $$ BEGIN RAISE NOTICE USING ERRCODE = '0A000', MESSAGE = 'reset not supported'; END $$                    |
      | BEGIN                                                                                                    |

  @server-reset-query-reload
  Scenario: Reload applies a changed inherited reset to new client sessions
    Given pg_doorman started with config:
      """
      [general]
      host = "127.0.0.1"
      port = ${DOORMAN_PORT}
      admin_username = "admin"
      admin_password = "admin"
      pg_hba.content = "host all all 127.0.0.1/32 trust"
      server_reset_query = "DISCARD ALL /* before_reload */"

      [pools.example_db]
      server_host = "127.0.0.1"
      server_port = ${PG_PORT}
      pool_mode = "session"

      [[pools.example_db.users]]
      username = "example_user_1"
      password = ""
      pool_size = 1
      """
    When we create session "old" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT 1" to session "old"
    And we close session "old"
    And we sleep 300ms
    Then PostgreSQL log should contain "DISCARD ALL /* before_reload */"
    When we overwrite pg_doorman config file with:
      """
      [general]
      host = "127.0.0.1"
      port = ${DOORMAN_PORT}
      admin_username = "admin"
      admin_password = "admin"
      pg_hba.content = "host all all 127.0.0.1/32 trust"
      server_reset_query = "DISCARD ALL /* after_reload */"

      [pools.example_db]
      server_host = "127.0.0.1"
      server_port = ${PG_PORT}
      pool_mode = "session"

      [[pools.example_db.users]]
      username = "example_user_1"
      password = ""
      pool_size = 1
      """
    And we create admin session "admin" to pg_doorman as "admin" with password "admin"
    And we execute "RELOAD" on admin session "admin" and store response
    And we sleep 300ms
    And we truncate PostgreSQL log
    And we create session "next" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT 2" to session "next" and store response
    Then session "next" should receive DataRow with "2"
    When we close session "next"
    And we sleep 300ms
    Then PostgreSQL log should contain "DISCARD ALL /* after_reload */"
    And PostgreSQL log should not contain "DISCARD ALL /* before_reload */"

  @server-reset-query-guc-sync
  Scenario: Full reset forgets checkout GUCs so the same client restores its schema
    Given fixtures from "tests/fixture-search-path.sql" applied
    And pg_doorman started with config:
      """
      [general]
      host = "127.0.0.1"
      port = ${DOORMAN_PORT}
      admin_username = "admin"
      admin_password = "admin"
      pg_hba.content = "host all all 127.0.0.1/32 trust"
      sync_server_parameters = true
      server_reset_query = "DISCARD ALL"
      startup_parameters.work_mem = "12MB"

      [pools.example_db]
      server_host = "127.0.0.1"
      server_port = ${PG_PORT}
      pool_mode = "transaction"

      [[pools.example_db.users]]
      username = "example_user_1"
      password = ""
      pool_size = 1
      """
    When we create session "pinned" to pg_doorman as "example_user_1" with password "" and database "example_db" and startup parameters "search_path=schema_a,role=example_user_rollback"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "pinned" and store backend_pid as "first"
    And we send Parse "lookup" with query "SELECT val FROM t" to session "pinned"
    And we send Bind "" to "lookup" with params "" to session "pinned"
    And we send Execute "" to session "pinned"
    And we send Sync to session "pinned"
    Then session "pinned" should receive DataRow with "1"
    When we send Bind "" to "lookup" with params "" to session "pinned"
    And we send Execute "" to session "pinned"
    And we send Sync to session "pinned"
    Then session "pinned" should receive DataRow with "1"
    When we send SimpleQuery "SELECT pg_backend_pid()" to session "pinned" and store backend_pid as "second"
    Then named backend_pid "second" from session "pinned" is same as "first"
    When we send SimpleQuery "SELECT current_user" to session "pinned" and store response
    Then session "pinned" should receive DataRow with "example_user_rollback"
    When we send SimpleQuery "SELECT current_user" to session "pinned" and store response
    Then session "pinned" should receive DataRow with "example_user_rollback"
    When we send SimpleQuery "SHOW work_mem" to session "pinned" and store response
    Then session "pinned" should receive DataRow with "12MB"

  @server-reset-query-selective-role
  Scenario: Selective prepared cleanup also invalidates the RESET ROLE snapshot
    Given pg_doorman started with config:
      """
      [general]
      host = "127.0.0.1"
      port = ${DOORMAN_PORT}
      admin_username = "admin"
      admin_password = "admin"
      pg_hba.content = "host all all 127.0.0.1/32 trust"
      sync_server_parameters = true
      prepared_statements = true

      [pools.example_db]
      server_host = "127.0.0.1"
      server_port = ${PG_PORT}
      pool_mode = "transaction"

      [[pools.example_db.users]]
      username = "example_user_1"
      password = ""
      pool_size = 1
      """
    When we create session "role" to pg_doorman as "example_user_1" with password "" and database "example_db" and startup parameters "role=example_user_rollback"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "role" and store backend_pid as "first"
    And we send SimpleQuery "SELECT current_user" to session "role" and store response
    Then session "role" should receive DataRow with "example_user_rollback"
    When we send SimpleQuery "SELECT 1/0" to session "role" expecting error
    And we send SimpleQuery "SELECT current_user" to session "role" and store response
    Then session "role" should receive DataRow with "example_user_rollback"
    When we send SimpleQuery "SELECT pg_backend_pid()" to session "role" and store backend_pid as "second"
    Then named backend_pid "second" from session "role" is same as "first"
