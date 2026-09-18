@rust @rust-3 @cleanup-server-query
Feature: Backend cleanup policy

  Background:
    Given PostgreSQL started with pg_hba.conf:
      """
      local all all trust
      host all all 127.0.0.1/32 trust
      """
    And fixtures from "tests/fixture.sql" applied

  @cleanup-server-query-session-reuse
  Scenario Outline: Reuse only after a successful full reset
    Given pg_doorman started with config:
      """
      general:
        host: "127.0.0.1"
        port: ${DOORMAN_PORT}
        admin_username: admin
        admin_password: admin
        connect_timeout: 1000
        cleanup_server_query: "<reset_query>"
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

  @cleanup-server-query-prepared-reuse
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
        cleanup_server_query: "SELECT 1 / 0"
      pools:
        example_db:
          server_host: "127.0.0.1"
          server_port: ${PG_PORT}
          pool_mode: transaction
          cleanup_server_query: "DISCARD ALL"
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
    When we send SimpleQuery "SELECT count(*) FROM pg_prepared_statements" to session "one" and store response
    Then session "one" should receive DataRow with "1"
    When we send SimpleQuery "SET statement_timeout = 10000" to session "one"
    And we send SimpleQuery "SELECT count(*) FROM pg_prepared_statements" to session "one" and store response
    Then session "one" should receive DataRow with "0"
    When we send Bind "" to "cached" with params "11" to session "one"
    And we send Execute "" to session "one"
    And we send Sync to session "one"
    Then session "one" should receive DataRow with "12"
    And session "one" should receive ReadyForQuery "I"
    When we send SimpleQuery "SELECT pg_backend_pid()" to session "one" and store backend_pid as "after"
    Then named backend_pid "after" from session "one" is same as "before"

  @cleanup-server-query-policy
  Scenario Outline: Cleanup scheduling counts each released backend once
    When I run shell command:
      """
      psql -X -h 127.0.0.1 -p ${PG_PORT} -U postgres -d example_db -v ON_ERROR_STOP=1 -c "CREATE TABLE public.cleanup_counter (n int); INSERT INTO public.cleanup_counter VALUES (0)"
      """
    Then the command should succeed
    Given pg_doorman started with config:
      """
      general:
        host: "127.0.0.1"
        port: ${DOORMAN_PORT}
        admin_username: admin
        admin_password: admin
        pg_hba: {content: "host all all 127.0.0.1/32 trust"}
        server_idle_check_timeout: 1
        pooler_check_query: "SELECT 7"
        cleanup_server_connections: <mode>
        cleanup_server_query: "RESET ALL; DEALLOCATE ALL; CLOSE ALL; UPDATE public.cleanup_counter SET n = n + <increment>"
      pools:
        example_db:
          server_host: "127.0.0.1"
          server_port: ${PG_PORT}
          pool_mode: transaction
          <mode_override>
          <query_override>
          users: [{username: example_user_1, password: "", pool_size: 1}]
      """
    When we create session "old" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "old" and store backend_pid
    When I run shell command:
      """
      psql -X -h 127.0.0.1 -p ${PG_PORT} -U postgres -d example_db -v ON_ERROR_STOP=1 -c "UPDATE public.cleanup_counter SET n = 0"
      """
    Then the command should succeed
    When we send SimpleQuery "<first_query>" to session "old"
    When I run shell command:
      """
      psql -X -h 127.0.0.1 -p ${PG_PORT} -U postgres -d example_db -At -v ON_ERROR_STOP=1 -c "SELECT n FROM public.cleanup_counter"
      """
    Then the command should succeed
    And the command output should contain "<intermediate>"
    When we sleep 10ms
    And we send SimpleQuery "<second_query>" to session "old" and store response
    Then session "old" should receive DataRow with "<intermediate>"
    When we close session "old"
    And we sleep 10ms
    And we create session "next" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "BEGIN; SELECT pg_backend_pid()" to session "next" and store backend_pid
    Then backend_pid from session "next" should equal backend_pid from session "old"
    When we send SimpleQuery "SELECT count(*) = 1 AND min(n) = <resets> AND current_setting('statement_timeout') = '0' FROM public.cleanup_counter" to session "next" and store response
    Then session "next" should receive DataRow with "t"
    And session "next" should receive ReadyForQuery "T"

    Examples:
      | mode     | mode_override                       | increment | query_override                                                                                                                                 | first_query                                                                                         | second_query                                       | intermediate | resets |
      | adaptive | # inherit                           | 1         | # inherit                                                                                                                                      | SELECT pg_backend_pid()                                                                             | SELECT min(n) FROM public.cleanup_counter           | 0            | 0      |
      | adaptive | # inherit                           | 1         | # inherit                                                                                                                                      | SET statement_timeout = 10000; SELECT pg_backend_pid()                                              | SELECT min(n) FROM public.cleanup_counter           | 1            | 1      |
      | adaptive | # inherit                           | 1         | # inherit                                                                                                                                      | SET work_mem = '96MB'; RESET application_name; SELECT pg_backend_pid()                               | SELECT min(n) FROM public.cleanup_counter           | 1            | 1      |
      | adaptive | # inherit                           | 1         | # inherit                                                                                                                                      | DISCARD ALL                             | SELECT min(n) FROM public.cleanup_counter           | 1            | 1      |
      | adaptive | # inherit                           | 1         | # inherit                                                                                                                                      | BEGIN; INSERT INTO public.cleanup_counter VALUES (99); SELECT pg_backend_pid()                       | SELECT min(n) FROM public.cleanup_counter           | 0            | 0      |
      | always   | # inherit                           | 1         | # inherit                                                                                                                                      | SELECT pg_backend_pid()                                                                             | SELECT min(n) FROM public.cleanup_counter           | 1            | 2      |
      | always   | # inherit                           | 1         | # inherit                                                                                                                                      | SELECT 7                                                                             | SELECT min(n) FROM public.cleanup_counter           | 1            | 2      |
      | always   | # inherit                           | 1         | # inherit                                                                                                                                      | BEGIN; SELECT pg_backend_pid()                                                                      | SELECT min(n) FROM public.cleanup_counter; COMMIT   | 0            | 1      |
      | off      | # inherit                           | 1         | # inherit                                                                                                                                      | BEGIN; INSERT INTO public.cleanup_counter VALUES (99); SELECT pg_backend_pid()                       | SELECT min(n) FROM public.cleanup_counter           | 0            | 0      |
      | off      | cleanup_server_connections: always  | 1         | # inherit                                                                                                                                      | SELECT pg_backend_pid()                                                                             | SELECT min(n) FROM public.cleanup_counter           | 1            | 2      |
      | always   | cleanup_server_connections: off     | 1         | # inherit                                                                                                                                      | BEGIN; INSERT INTO public.cleanup_counter VALUES (99); SELECT pg_backend_pid()                       | SELECT min(n) FROM public.cleanup_counter           | 0            | 0      |
      | always   | cleanup_server_connections: true     | 1         | # inherit                                                                                                                                      | SELECT pg_backend_pid()                       | SELECT min(n) FROM public.cleanup_counter           | 0            | 0      |
      | always   | # inherit                           | 100       | cleanup_server_query: "RESET ALL; DEALLOCATE ALL; CLOSE ALL; UPDATE public.cleanup_counter SET n = n + 1"                                       | SELECT pg_backend_pid()                                                                             | SELECT min(n) FROM public.cleanup_counter           | 1            | 2      |
