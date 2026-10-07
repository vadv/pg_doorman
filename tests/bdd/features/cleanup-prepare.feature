@rust @rust-3 @cleanup-review @cleanup-prepare
Feature: Adaptive cleanup removes SQL PREPARE statements left by a client
  SQL PREPARE and an extended-protocol Parse share one server-side
  statement namespace. An untracked PREPARE made the next client on the
  same backend fail with 42P05 duplicate_prepared_statement.

  Background:
    Given PostgreSQL started with pg_hba.conf:
      """
      local all all trust
      host all all 127.0.0.1/32 trust
      """
    And fixtures from "tests/fixture.sql" applied
    And pg_doorman started with config:
      """
      general:
        host: "127.0.0.1"
        port: ${DOORMAN_PORT}
        admin_username: admin
        admin_password: admin
        connect_timeout: 1000
        pg_hba: {content: "host all all 127.0.0.1/32 trust"}
      web:
        enabled: true
        host: "127.0.0.1"
        port: 9129
      pools:
        example_db:
          server_host: "127.0.0.1"
          server_port: ${PG_PORT}
          pool_mode: transaction
          users: [{username: example_user_1, password: "", pool_size: 1}]
        example_db_session:
          server_host: "127.0.0.1"
          server_port: ${PG_PORT}
          server_database: "example_db"
          pool_mode: session
          users: [{username: example_user_1, password: "", pool_size: 1}]
      """

  @cleanup-prepare-statement
  Scenario: A SQL PREPARE statement does not survive a checkin
    When we create session "old" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "old" and store backend_pid
    And we send SimpleQuery "PREPARE leak_stmt AS SELECT 42" to session "old"
    And we close session "old"
    And we create session "next" to pg_doorman as "example_user_1" with password "" and database "example_db"
    And we send SimpleQuery "SELECT pg_backend_pid()" to session "next" and store backend_pid
    Then backend_pid from session "next" should equal backend_pid from session "old"
    # The same name must be preparable again: 42P05 means the statement leaked.
    And we send SimpleQuery "PREPARE leak_stmt AS SELECT 42" to session "next" and store response
    Then session "next" should receive CommandComplete "PREPARE"

  @cleanup-prepare-deallocate-all
  Scenario: A client DEALLOCATE ALL suppresses the checkin DEALLOCATE ALL
    # Session pooling has a single checkin at disconnect, so PREPARE and the
    # client's DEALLOCATE ALL share one lease.
    When we create session "old" to pg_doorman as "example_user_1" with password "" and database "example_db_session"
    And we send SimpleQuery "PREPARE keep_stmt AS SELECT 42" to session "old"
    And we send SimpleQuery "DEALLOCATE ALL" to session "old"
    And we close session "old"
    And we create session "next" to pg_doorman as "example_user_1" with password "" and database "example_db_session"
    And we send SimpleQuery "SELECT count(*) FROM pg_prepared_statements" to session "next" and store response
    Then session "next" should receive DataRow with "0"
    # The client's own DEALLOCATE ALL already emptied the view, so the counter
    # is what pins suppression. Its label is the pool name, and creating the
    # next lease waits for the previous checkin to finish.
    When I run shell command:
      """
      python3 - <<'PY'
      import time
      import urllib.request
      deadline = time.monotonic() + 5
      while True:
          body = urllib.request.urlopen('http://127.0.0.1:9129/metrics', timeout=2).read().decode()
          lines = body.splitlines()
          ok = 'pg_doorman_server_cleanup_total{database="example_db_session",result="ok",user="example_user_1"} 0' in lines
          err = 'pg_doorman_server_cleanup_total{database="example_db_session",result="error",user="example_user_1"} 0' in lines
          if ok and err:
              break
          assert time.monotonic() < deadline, body
          time.sleep(0.05)
      PY
      """
    Then the command should succeed
