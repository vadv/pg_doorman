# Pool Modes

PgDoorman supports two pool modes: `transaction` and `session`. Set per pool, with optional per-user override.

There is no `statement` mode. Statement pooling rotates the backend after every statement, which forces clients to give up multi-statement transactions and breaks the prepared-statement protocol entirely; PgDoorman invests its tuning (prepared-statement cache, direct handoff, strict-FIFO scheduling) in transaction mode instead. PgBouncer keeps `statement` mode for backward compatibility; Odyssey omits it.

## Transaction mode (recommended)

```yaml
pools:
  mydb:
    pool_mode: "transaction"
```

A backend connection is held for the duration of a transaction, then returned to the pool on `COMMIT`, `ROLLBACK`, or implicit completion.

This is the mode that delivers PgDoorman's connection efficiency: a `pool_size` of 40 can serve thousands of clients as long as transactions are short.

What works in transaction mode (where most poolers fail):

- Prepared statements. PgDoorman caches them per-pool, remaps statement names across backend connections, and replays preparation transparently. Drivers that pin to `unnamed` statement (Go pgx, .NET Npgsql, Python asyncpg) work without configuration.
- Pipelined batches and async `Flush` flow.
- Cancel requests over TLS.
- `LISTEN` / `NOTIFY` — but only inside a transaction. A `LISTEN` issued and then committed releases the backend, and any notifications delivered to it after that go to whichever client checks it out next, not to the original `LISTEN`-er. PgBouncer behaves the same way; if you need cross-transaction `LISTEN`, use session mode for that client.

What does **not** work in transaction mode:

- `SET` and `RESET` outside a transaction. Use session mode for clients that rely on session-level GUC changes (`SET TIME ZONE`, `SET search_path` once per connection).
- Advisory locks held across transactions. Use session mode.
- Cursors held outside transactions (`WITH HOLD`). Use session mode.
- `SET LOCAL` works as expected — it is transaction-scoped.

## Session mode

```yaml
pools:
  legacy_app:
    pool_mode: "session"
```

A backend connection is held for the duration of the client session. Returned to the pool only when the client disconnects.

Use this when:

- The application uses session-scoped state (`SET search_path`, `SET TIME ZONE`).
- The application uses `WITH HOLD` cursors.
- The application uses advisory locks across transactions.
- You are migrating an unmodified PgBouncer deployment that was using session mode and you want a like-for-like swap.

In session mode, `pool_size` is effectively the maximum number of concurrent clients. Sizing matches PostgreSQL's `max_connections` minus reserves.

## Per-user override

A pool's mode can be overridden per user:

```yaml
pools:
  mydb:
    pool_mode: "transaction"
    users:
      - username: "app"
        password: "md5..."
        pool_size: 40
      - username: "admin_tools"
        password: "md5..."
        pool_size: 4
        pool_mode: "session"
```

Useful when one user (operations tooling, migrations) needs session semantics but the main application stays in transaction mode.

## Cleanup on checkin

`cleanup_server_connections` defaults to `adaptive`. A pool inherits general settings unless it overrides them.
Mode and `cleanup_server_query` inherit independently. Legacy `true` means `adaptive`, and `false` means `off`.
Open transactions are rolled back separately before session cleanup in every mode, including `off`.

In adaptive mode, plain `SELECT` does not require cleanup. It does not cancel an earlier cleanup requirement.
Successful `Parse` and `Bind` operations with managed caching do not themselves require cleanup, so cached statements can be reused.
When built-in cleanup is required, it starts with `RESET ROLE`, followed by the required commands in this order:
`RESET ALL` for SET state, `DEALLOCATE ALL` for prepared statements, and `CLOSE ALL` for cursors.

- Buffered Parse registration left unfinished at checkin requires `DEALLOCATE ALL`.
- An unsent Close from LRU eviction requires `DEALLOCATE ALL`.
- A server error with the backend prepared cache requires prepared-statement cleanup before reuse. Bad backends are closed.

A named Parse without managed caching requires all three cleanup categories, including in session pooling.
CLOSE ALL cancels cursor cleanup. Closing one cursor does not.
Backend CommandComplete tags for DEALLOCATE ALL and DISCARD ALL invalidate the backend prepared-statement LRU.
Internal prepared-statement cleanup does not clear the pool query cache or client prepared-statement name mappings.
SQL PREPARE, temporary objects, LISTEN and function side effects are not independently tracked. RESET ALL does not release advisory locks.
Built-in tracking clears the SET requirement on any RESET tag, including a single-parameter RESET, so other changed parameters can be missed.
DISCARD ALL clears the three cleanup flags. Unfinished Parse registration and unsent Closes are checked separately at checkin.
A configured cleanup query replaces the built-in commands. In this case RESET preserves an earlier SET cleanup requirement,
and client DISCARD ALL also requests the configured cleanup.

`always` requires a configured query and runs it once per used-backend return, including after SELECT.
It adds server work and may require statements to be prepared again.
For PostgreSQL workloads that favor prepared-cache reuse, keep the default:

```yaml
general:
  cleanup_server_connections: adaptive
```

Choose cleanup SQL for the session resources your application uses. `off` skips session cleanup even when a query is configured.
RELOAD applies changed policies to new pools. Existing clients keep their old pool.

Cleanup runs on backend return: client disconnect in session mode, transaction/autocommit end in transaction mode. It does not run within an open transaction or during Flush.

## Reference

- `pool_mode` parameter: [Pool Settings](../reference/pool.md#pool_mode).
- `cleanup_server_connections`: [Pool Settings](../reference/pool.md#cleanup_server_connections).
- Pool sizing: [Pool Coordinator](pool-coordinator.md), [Pool Pressure](../tutorials/pool-pressure.md).
