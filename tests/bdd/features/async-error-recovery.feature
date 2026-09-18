@rust @rust-1 @async-error-recovery
Feature: Async errors retire the backend without interrupting client recovery
  A backend marked bad after an extended-query error must deliver the response
  to Sync before being retired. The same client can then use a fresh backend.

  Background:
    Given PostgreSQL started with pg_hba.conf:
      """
      local all all trust
      host all all 127.0.0.1/32 trust
      """
    And fixtures from "tests/fixture.sql" applied

  Scenario Outline: Flush error preserves Sync and rollback responses with <cleanup> cleanup and <transaction> transaction
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
      <reset_setting>

      [pools.example_db]
      server_host = "127.0.0.1"
      server_port = ${PG_PORT}
      pool_mode = "transaction"

      [[pools.example_db.users]]
      username = "example_user_1"
      password = ""
      pool_size = 1
      """
    When we create session "client" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send Parse "cached" with query "SELECT $1::int + 10" to session "client"
    And we send Bind "" to "cached" with params "1" to session "client"
    And we send Execute "" to session "client"
    And we send Sync to session "client"
    Then session "client" should receive DataRow with "11"
    And session "client" should receive ReadyForQuery "I"

    When we send SimpleQuery "<begin_query>" to session "client" and store response
    Then session "client" should receive ReadyForQuery "<before_status>"
    When we send SimpleQuery "SELECT pg_backend_pid()" to session "client" and store backend_pid as "before_error"
    And we send Parse "" with query "bad sql syntax" to session "client"
    And we send Flush to session "client"
    # Consume the actual error before sending Sync; there is no ReadyForQuery yet.
    And we read ErrorResponse from session "client"
    Then session "client" should receive error containing "syntax error" with code "42601"
    When we send Sync to session "client"
    Then session "client" should receive ReadyForQuery "<error_status>"
    # An explicit failed transaction stays pinned until the client's ROLLBACK.
    When we send SimpleQuery "<recovery_query>" to session "client" and store response
    Then session "client" should receive ReadyForQuery "I"

    # Re-Bind without another Parse: the client statement must survive retirement.
    When we send Bind "" to "cached" with params "2" to session "client"
    And we send Execute "" to session "client"
    And we send Sync to session "client"
    Then session "client" should receive DataRow with "12"
    And session "client" should receive ReadyForQuery "I"
    When we send SimpleQuery "SELECT pg_backend_pid()" to session "client" and store backend_pid as "after_error"
    Then named backend_pid "after_error" from session "client" is different from "before_error"

    Examples:
      | cleanup    | transaction | reset_setting                      | begin_query | before_status | error_status | recovery_query |
      | selective  | implicit    | # server_reset_query unset         | SELECT 1    | I             | I            | SELECT 1       |
      | selective  | explicit    | # server_reset_query unset         | BEGIN       | T             | E            | ROLLBACK       |
      | configured | implicit    | server_reset_query = "DISCARD ALL" | SELECT 1    | I             | I            | SELECT 1       |
      | configured | explicit    | server_reset_query = "DISCARD ALL" | BEGIN       | T             | E            | ROLLBACK       |
