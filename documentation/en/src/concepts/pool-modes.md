# Pool Modes

PgDoorman supports two pool modes: `transaction` and `session`. Set per pool, with optional per-user override.

There is no `statement` mode.

## Transaction mode (recommended)

```yaml
pools:
  mydb:
    pool_mode: "transaction"
```

Supports:

- Named and anonymous prepared statements.
- Pipelined batches and asynchronous `Flush`.
- Query cancellation over TLS.

## Session mode

```yaml
pools:
  legacy_app:
    pool_mode: "session"
```

Use for clients that need:

- Session parameters (`SET search_path`, `SET TIME ZONE`).
- `LISTEN` subscriptions.
- `WITH HOLD` cursors and advisory locks held across transactions.

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

The default is `cleanup_server_connections: adaptive` without `cleanup_server_query`. This preserves prepared statements when cleanup is unnecessary and suits PostgreSQL OLTP workloads.

`cleanup_server_query` replaces the built-in cleanup commands. In `adaptive`, it runs when cleanup is needed; in `always`, on every return of a used connection. `always` requires a configured query, adds server work, and can require preparing statements again. `off` disables session cleanup; open transactions are rolled back in every mode.

`adaptive` does not guarantee complete session cleanup. To clean up temporary objects, `LISTEN` subscriptions, or session advisory locks, use `always` with SQL that releases those resources.

See the [pool reference](../reference/pool.md#cleanup_server_connections) for settings, limitations, and PostgreSQL and Greengage examples.

## Reference

- `pool_mode` parameter: [Pool Settings](../reference/pool.md#pool_mode).
- `cleanup_server_connections`: [Pool Settings](../reference/pool.md#cleanup_server_connections).
- Pool sizing: [Pool Coordinator](pool-coordinator.md), [Pool Pressure](../tutorials/pool-pressure.md).
