# Observability

## Log destination

By default Odoo's `init_logger()` (`odoo/netsvc.py`) installs a `logging.StreamHandler()` — output goes to **stderr**. The container ships with **no `--logfile`** in `odoo.conf`, so logs do not go to a file. Read them via the platform log view (`kubectl logs`, Docker logs, or the Clouve console).

There is no `/var/log/odoo` in this container (that path is only used when `--logfile` is configured, typically in systemd deployments). There is no Apache — Odoo runs its own Werkzeug HTTP server.

## Log line format

```
%(asctime)s %(pid)s %(levelname)s %(dbname)s %(name)s: %(message)s %(perf_info)s
```

The `perf_info` field appends SQL query count, query time, and remaining wall time per request — useful for catching slow endpoints.

## Verbosity controls

### `--log-level` presets

The `--log-level` flag maps to module-level presets defined in `PSEUDOCONFIG_MAPPER` (`netsvc.py`):

| Value | Effective config |
|---|---|
| `info` (default) | Root logger at INFO |
| `debug` | `odoo:DEBUG`, `odoo.sql_db:INFO` |
| `debug_sql` | `odoo.sql_db:DEBUG` |
| `debug_rpc` | `odoo:DEBUG`, `odoo.sql_db:INFO`, `odoo.http.rpc.request:DEBUG` |
| `debug_rpc_answer` | `odoo:DEBUG`, `odoo.sql_db:INFO`, `odoo.http.rpc:DEBUG` |
| `warn` | `odoo:WARNING`, `werkzeug:WARNING` |
| `error` | `odoo:ERROR`, `werkzeug:ERROR` |
| `critical` | `odoo:CRITICAL`, `werkzeug:CRITICAL` |

### Per-module overrides: `--log-handler`

`--log-handler MODULE:LEVEL` (repeatable; also `log_handler = MODULE:LEVEL` in conf, one per line) sets a specific logger to a specific level, applied on top of the `--log-level` preset.

Useful patterns:

```
# SQL query logging
--log-handler odoo.sql_db:DEBUG
# Shortcut: --log-sql

# HTTP request/response detail
--log-handler odoo.http:DEBUG
# Shortcut: --log-web

# Full RPC tracing
--log-handler odoo.http.rpc:DEBUG

# Silence werkzeug access log
--log-handler werkzeug:ERROR
```

In `odoo.conf`, use repeated `log_handler` lines:

```ini
log_handler = odoo.sql_db:DEBUG
log_handler = werkzeug:ERROR
```

### `--log-db`

Writes log records into the `ir_logging` table in a PostgreSQL database. Implemented via `PostgreSQLHandler` (`netsvc.py`), which inserts a row per log record with a 1-second statement timeout to avoid deadlocks. **Avoid in production** — high request volume generates table bloat and contention on `ir_logging`. Use only for short debugging sessions.

## Exclusive options

`--logfile` and `--syslog` are mutually exclusive (`config.py` line 650: `if self.options['syslog'] and self.options['logfile']: parser.error(...)`). Passing both aborts startup.

The container uses neither — stderr is the only active handler.
