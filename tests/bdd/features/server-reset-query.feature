@rust @rust-3 @server-reset-query
Feature: Pool reset query

  Background:
    Given PostgreSQL started with pg_hba.conf:
      """
      local all all trust
      host all all 127.0.0.1/32 trust
      """
    And fixtures from "tests/fixture.sql" applied

  @server-reset-query-session-reuse
  Scenario Outline: Reuse only after a successful full reset
    Given pg_doorman started with config:
      """
      general:
        host: "127.0.0.1"
        port: ${DOORMAN_PORT}
        admin_username: admin
        admin_password: admin
        connect_timeout: 1000
        server_reset_query: "<reset_query>"
        pg_hba: {content: "host all all 127.0.0.1/32 trust"}
      pools:
        example_db:
          server_host: "127.0.0.1"
          server_port: ${PG_PORT}
          pool_mode: session
          users: [{username: example_user_1, password: "", pool_size: 1}]
      """
    When we create session "old" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "old" and store backend_pid
    And we send SimpleQuery "SET statement_timeout = 10000; CREATE TEMP TABLE reset_secret (value int); PREPARE reset_stmt AS SELECT 42" to session "old"
    And we send SimpleQuery "SELECT current_setting('statement_timeout') = '10s' AND to_regclass('pg_temp.reset_secret') IS NOT NULL AND EXISTS (SELECT FROM pg_prepared_statements WHERE name = 'reset_stmt')" to session "old" and store response
    Then session "old" should receive DataRow with "t"
    When we send SimpleQuery "BEGIN" to session "old"
    And we close session "old"
    And we create session "next" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "next" and store backend_pid
    Then backend_pid from session "next" should <comparison> backend_pid from session "old"
    When we send SimpleQuery "SELECT current_setting('statement_timeout') = '0' AND to_regclass('pg_temp.reset_secret') IS NULL AND NOT EXISTS (SELECT FROM pg_prepared_statements WHERE name = 'reset_stmt')" to session "next" and store response
    Then session "next" should receive DataRow with "t"
    And session "next" should receive ReadyForQuery "I"

    Examples:
      | reset_query                                                                               | comparison |
      | RESET ALL; DEALLOCATE ALL; CLOSE ALL; UNLISTEN *; SELECT repeat('x', 20000), pg_advisory_unlock_all(); DISCARD PLANS; DISCARD SEQUENCES; DISCARD TEMP; SET SESSION AUTHORIZATION DEFAULT                                                     | equal      |
      | RESET ALL; DEALLOCATE ALL; SELECT 1 / 0; DISCARD TEMP                                       | not equal  |
      | DO $$ BEGIN RAISE NOTICE USING ERRCODE = '0AM01', MESSAGE = 'partial reset'; END $$         | not equal  |
      | DO $$ BEGIN RAISE NOTICE USING ERRCODE = '0A000', MESSAGE = 'unsupported reset'; END $$     | not equal  |
      | BEGIN                                                                                     | not equal  |
      | COPY reset_secret FROM STDIN                                                              | not equal  |
      | SELECT pg_sleep(5)                                                                        | not equal  |
      | /* empty reset */                                                                         | not equal  |

  @server-reset-query-prepared-reuse
  Scenario: Cached Bind reparses and restores startup parameters after reset
    Given fixtures from "tests/fixture-search-path.sql" applied
    And pg_doorman started with config:
      """
      general:
        host: "127.0.0.1"
        port: ${DOORMAN_PORT}
        admin_username: admin
        admin_password: admin
        connect_timeout: 1000
        pg_hba: {content: "host all all 127.0.0.1/32 trust"}
        prepared_statements: true
        sync_server_parameters: true
        server_reset_query: "SELECT 1 / 0"
      pools:
        example_db:
          server_host: "127.0.0.1"
          server_port: ${PG_PORT}
          pool_mode: transaction
          server_reset_query: "DISCARD ALL"
          users: [{username: example_user_1, password: "", pool_size: 1}]
      """
    When we create session "one" to pg_doorman as "example_user_1" with password "" and database "example_db" and startup parameters "search_path=schema_a"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "one" and store backend_pid as "before"
    And we send Parse "cached" with query "SELECT val + $1::int FROM t" to session "one"
    And we send Bind "" to "cached" with params "10" to session "one"
    And we send Execute "" to session "one"
    And we send Sync to session "one"
    Then session "one" should receive DataRow with "11"
    And session "one" should receive ReadyForQuery "I"
    When we send Bind "" to "cached" with params "11" to session "one"
    And we send Execute "" to session "one"
    And we send Sync to session "one"
    Then session "one" should receive DataRow with "12"
    And session "one" should receive ReadyForQuery "I"
    When we send SimpleQuery "SELECT pg_backend_pid()" to session "one" and store backend_pid as "after"
    Then named backend_pid "after" from session "one" is same as "before"
