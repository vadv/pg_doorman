@rust @rust-3 @cleanup-policy-adaptive
Feature: Built-in cleanup without cleanup_server_query
  A configured query belongs to `always`. Without one, `adaptive` sends built-in
  cleanup only when it observed a session change, and `off` sends none.
  The mode is inherited by every pool.

  Background:
    Given PostgreSQL started with options "-c log_statement=all -c logging_collector=off" and pg_hba.conf:
      """
      local all all trust
      host all all 127.0.0.1/32 trust
      """
    And fixtures from "tests/fixture.sql" applied

  @cleanup-policy-adaptive-modes
  Scenario Outline: Mode <mode> with pool setting <mode_override> sends <resets> built-in cleanups
    Given pg_doorman started with config:
      """
      [general]
      host = "127.0.0.1"
      port = ${DOORMAN_PORT}
      admin_username = "admin"
      admin_password = "admin"
      pg_hba.content = "host all all 127.0.0.1/32 trust"
      cleanup_server_connections = <mode>

      [pools.example_db]
      server_host = "127.0.0.1"
      server_port = ${PG_PORT}
      pool_mode = "session"
      <mode_override>

      [[pools.example_db.users]]
      username = "example_user_1"
      password = ""
      pool_size = 1
      """
    When we create session "one" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "one"
    And we sleep 100ms
    When we truncate PostgreSQL log
    And we send SimpleQuery "<first_query>" to session "one"
    And we send SimpleQuery "<second_query>" to session "one"
    And we close session "one"
    And we sleep 300ms
    Then PostgreSQL log should contain exactly <resets> occurrences of "RESET ALL"

    Examples:
      | mode     | mode_override                         | first_query                          | second_query | resets |
      | "adaptive" | # inherit                           | SELECT 1                             | SELECT 1     | 0      |
      | "adaptive" | # inherit                           | SET statement_timeout = 10000        | SELECT 1     | 1      |
      | "adaptive" | # inherit                           | SET statement_timeout = 10000        | DISCARD ALL  | 0      |
      | "adaptive" | # inherit                           | BEGIN; SET statement_timeout = 10000 | SELECT 1     | 1      |
      | "off"    | # inherit                           | SET statement_timeout = 10000        | SELECT 1     | 0      |
      | "adaptive" | cleanup_server_connections = "off"  | SET statement_timeout = 10000        | SELECT 1     | 0      |
      | "off"    | cleanup_server_connections = "adaptive" | SET statement_timeout = 10000  | SELECT 1     | 1      |
      | "adaptive" | cleanup_server_connections = true   | SET statement_timeout = 10000        | SELECT 1     | 1      |
      | "adaptive" | cleanup_server_connections = false  | SET statement_timeout = 10000        | SELECT 1     | 0      |
