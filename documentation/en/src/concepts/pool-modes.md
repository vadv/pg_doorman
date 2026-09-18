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

`cleanup_server_connections` defaults to `adaptive`. A pool inherits general settings unless it overrides them;
mode and `cleanup_server_query` inherit independently. Legacy `true` means `adaptive`, and `false` means `off`.
Open transactions are rolled back in every mode, including `off`.

In adaptive mode, plain `SELECT` adds no cleanup round trip. Without custom SQL, a tracked SET causes
`RESET ROLE; RESET ALL;`; cursor state adds `CLOSE ALL`. Pending Parses, deferred eviction Closes and errors
with a prepared cache can require `DEALLOCATE ALL`, which also clears the backend prepared cache.
Ordinary cached-statement use keeps that cache. SQL PREPARE is not universally tracked; temporary objects,
LISTEN and function side effects are outside this tracking. `RESET ALL` does not unlock advisory locks.
Legacy RESET/DISCARD tags can clear tracking; configured adaptive cleanup retains SET dirtiness conservatively.

A custom query replaces selective SQL when adaptive cleanup is needed. `always` runs the effective query
after every used backend, including plain SELECT, at the cost of a round trip and prepared-cache rebuild.
For PostgreSQL workloads that favor prepared-cache reuse, keep the default:

```yaml
general:
  cleanup_server_connections: adaptive
```

Choose cleanup SQL for the session resources your application uses. `off` skips session cleanup even when a query is configured.
RELOAD applies changed policies to new pools; existing clients keep their old pool.

Cleanup runs on backend return: client disconnect in session mode, transaction/autocommit end in transaction mode; not within an open transaction or during Flush.

## Reference

- `pool_mode` parameter: [Pool Settings](../reference/pool.md#pool_mode).
- `cleanup_server_connections`: [Pool Settings](../reference/pool.md#cleanup_server_connections).
- Pool sizing: [Pool Coordinator](pool-coordinator.md), [Pool Pressure](../tutorials/pool-pressure.md).
