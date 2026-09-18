# Greengage and backend reset

For Greengage pools, configure an explicit full reset:

```yaml
pools:
  analytics:
    # Add the usual server_host, server_port and users settings.
    server_reset_query: |
      SET SESSION AUTHORIZATION DEFAULT;
      RESET ALL;
      DEALLOCATE ALL;
      CLOSE ALL;
      UNLISTEN *;
      SELECT pg_advisory_unlock_all();
      DISCARD PLANS;
      DISCARD SEQUENCES;
      DISCARD TEMP;
```

`general.server_reset_query` supplies a default; a pool value overrides it.
For mixed PostgreSQL/Greengage deployments, leave the general setting unset
and configure only the Greengage pools. An unset effective value preserves
selective cleanup: `RESET ROLE` followed by the required `RESET ALL`,
`DEALLOCATE ALL` and `CLOSE ALL`. pg_doorman does not generate `DISCARD ALL`
unless you configure it. PostgreSQL can use `server_reset_query: DISCARD ALL`.

A configured query runs before a used backend is reused, after a separate
`ROLLBACK` if necessary. In transaction mode this means every transaction;
in session mode it means client disconnect. Idle checks can also require a
reset before checkout. The query must restore **all session state**, including
prepared statements, cursors, identity, GUCs, temporary objects and session
locks. This is a trusted operator contract: `SELECT 1` and `RESET ALL` alone
are not full resets, even if they succeed. Custom SQL is not analyzed or rewritten.

The pooler drains all results, including SELECT rows, and requires
`ReadyForQuery = Idle`. SQL/transport errors, an empty query response, COPY,
an incomplete exchange, timeout or unsupported-feature notices (`0A000`,
Greengage `0AM01`) retire the backend. The timeout is `general.connect_timeout`.
Other informational notices are allowed. Local prepared state and GUC snapshots
are cleared only after successful cleanup. A custom reset therefore loses the
server prepared cache between transactions; client statements are reparsed as needed.
Blank/semicolon-only queries, NUL bytes and a custom query combined with
`cleanup_server_connections: false` are rejected. Comment-only queries retire
backends at runtime. Disabling cleanup retires dirty connections.

`RELOAD` creates new pools for a changed reset policy. Existing client connections
can retain their old pool and policy; reconnect/drain those clients to complete
a policy change. Pool overrides cannot disable an inherited query with an empty value.

## Client DISCARD ALL

Greengage 6.31.0 and 7.5.0 emit `NOTICE 0AM01` for `DISCARD ALL`, then clean
coordinator state, including prepared statements. They do **not** dispatch the
full operation to segments. A successful command tag does not prove clusterwide
cleanup. pg_doorman invalidates the coordinator prepared cache and retains the
need for cleanup; without a configured reset it retires that backend on release.
In transaction mode the completed response is delivered and the next query uses
another backend. This does not make DISCARD a clusterwide reset within a session.

Client SQL stays backend-native in both simple and extended protocol. Configure
client/driver reset SQL separately if it uses `DISCARD ALL`: the query above is
the Greengage alternative. Pool cleanup protects the next borrower; it does not
emulate a clusterwide DISCARD midway through the same client session. A client
can suppress NOTICE with `client_min_messages`; detection by NOTICE alone is
therefore insufficient. Always configure the explicit Greengage recipe, rather
than `DISCARD ALL`, including when the server appears to accept the latter.

The behavior and recipe follow the [Greengage documentation](https://greengagedb.org/en/docs-gg/current/reference/sql_commands/discard.html)
and release sources [6.31.0](https://github.com/GreengageDB/greengage/blob/6.31.0/src/backend/commands/discard.c)
and [7.5.0](https://github.com/GreengageDB/greengage/blob/7.5.0/src/backend/commands/discard.c).
The recipe also includes `UNLISTEN *`: live checks on both releases show that
LISTEN creates coordinator subscriptions and the documentation's eight-command
sequence leaves them in place. This addition clears them before reuse; it does
not promise clusterwide asynchronous notification delivery.

## Service SQL and protocol audit

The following inventory covers the pooler's generated backend operations.
Compatibility below refers to the Greengage 6.31.0/7.5.0 source and the reset
checks described below; it is not a certification of every client workload.

| Operation | Support / operator control |
|---|---|
| Rollback and selective RESET ROLE / RESET ALL / DEALLOCATE ALL / CLOSE ALL | Supported. The optional full reset above replaces selective cleanup. A plain RESET tag is ambiguous, so client RESET keeps cleanup armed. |
| Prepared recovery after errors or interrupted batches | Uses the same cleanup path. Failure retires the backend; stale cache entries are not reused. |
| Parse, Bind, Describe, Execute, Close, Sync, Flush | Standard protocol operations; cache eviction sends Close/Sync, not SQL DISCARD. Prepared queries remain client SQL. |
| Configured `UNLISTEN *` | Clears coordinator LISTEN subscriptions on both tested releases. Included in the full recipe. |
| Idle probe `;` | Supported EmptyQueryResponse/ReadyForQuery; no fork-specific setting needed. |
| Client pooler probe | Existing `general.pooler_check_query` controls matching and response caching. It must have a stable response. |
| StartupMessage | Protocol v3 with user/database/application_name and configured `startup_parameters`. General, pool and auth_query overrides already exist; unknown GUCs fail startup. |
| Checkout SET/RESET of client parameters | Existing `sync_server_parameters` controls this. Reset forgets unreported GUC snapshots so later checkout replays values such as search_path. Operator startup defaults remain backend reset defaults. |
| Authentication lookup | Existing pool `auth_query.query` is operator SQL with `$1` username. No built-in lookup query needs replacement. |
| CLI configuration generation | Reads `pg_shadow(usename, passwd)` and `pg_database(datname, datistemplate)`, present in both releases. Catalog access still requires privileges. |
| TLS, authentication, CancelRequest, Terminate | Protocol operations, not reset SQL. Validate the desired authentication/TLS deployment separately. |
| Deferred BEGIN, COPY, fastpath calls | Forwarded client operations; no additional generated fork-specific SQL. |
| Patroni fallback and proxy | REST discovery and TCP forwarding; no hidden `pg_is_in_recovery()` or read-only SQL probe. Greengage topology support is not implied. |

Selective mode is not full session isolation: it does not track every temporary
object, advisory lock, SQL PREPARE or function side effect. `RESET ROLE; RESET ALL`
also does not undo `SET SESSION AUTHORIZATION`; the full recipe explicitly does.
Use full reset for workloads that alter these session resources.

Greengage SHA-256 password verifiers are not PostgreSQL SCRAM-SHA-256. Ordinary
backend cleartext-password authentication is not supported by pg_doorman's current
backend auth path. Use a tested supported authentication mode (for example MD5);
this change does not add new authentication mechanisms.

## Validation scope

The regression suite covers real PostgreSQL reuse, transaction/session mode,
prepared reparse, GUC state, rollback, reload, row-returning resets and failure
retirement. Wire fixtures cover unsupported notices, incomplete responses and
cancellation. Live reset checks use the official Greengage 6.31.0 and 7.5.0
images with a coordinator and two segments. TLS, HA/failover and distributed
cancellation are outside these reset checks.

Live checks passed 20 scenarios in total (10 per version), using MD5 backend
credentials and trusted local test clients. They cover same-PID reuse after
simple/extended client DISCARD, suppressed NOTICE, pool override, prepared
reparse and retirement after real NOTICE-only/partial failed resets. Temporary
objects were checked on the coordinator **and both segments**.

Run the committed regressions with:

```sh
make test-bdd TAGS=@server-reset-query
make test-bdd TAGS=@client-session-reset-cleanup
cargo test --lib server::reset_tests
```
