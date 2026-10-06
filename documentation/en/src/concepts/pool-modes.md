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

The default is `cleanup_server_connections: adaptive` without `cleanup_server_query`: pg_doorman cleans a session only when it sees the session state change, so prepared statements survive a checkin. This suits PostgreSQL OLTP workloads.

`cleanup_server_query` replaces the built-in cleanup and requires `always`: your SQL runs on every checkin of a backend that served a client. It is incompatible with `adaptive`, and validation rejects that pairing. `always` adds server work and can force clients to prepare statements again. `off` disables session cleanup; open transactions are rolled back in every mode.

`adaptive` does not guarantee a fully clean session: temporary objects, `LISTEN` subscriptions and advisory locks are released only by `always` with suitable SQL.

See the [pool reference](../reference/pool.md#cleanup_server_connections) for settings, limitations, and PostgreSQL and Greengage examples.

## Reference

- `pool_mode` parameter: [Pool Settings](../reference/pool.md#pool_mode).
- `cleanup_server_connections`: [Pool Settings](../reference/pool.md#cleanup_server_connections).
- Pool sizing: [Pool Coordinator](pool-coordinator.md), [Pool Pressure](../tutorials/pool-pressure.md).
