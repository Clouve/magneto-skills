# Configuration

## File format

`/etc/odoo/odoo.conf` is a standard INI file with a single `[options]` section. The entrypoint generates this file fresh on every pod start from environment variables.

## Precedence (highest → lowest)

`tools/config.py` uses a `ChainMap` in this order:

1. **Runtime** (`_runtime_options`) — computed post-load (e.g. deduped `log_handler`, `init` dict)
2. **CLI** (`_cli_options`) — flags passed directly to `odoo` or `odoo-bin`
3. **Env** (`_env_options`) — `PG*` variables and `ODOO_`-prefixed vars (e.g. `PGHOST` → `db_host`, `PGPASSWORD` → `db_password`, `ODOO_RC` → config file path)
4. **File** (`_file_options`) — values from `odoo.conf`
5. **Default** (`_default_options`) — compiled-in defaults

## Key operator options

### Database

| Option (conf key) | CLI flag | Env var | Default | Notes |
|---|---|---|---|---|
| `db_host` | `--db_host` | `PGHOST` | `''` | |
| `db_port` | `--db_port` | `PGPORT` | `None` | |
| `db_user` | `-r`/`--db_user` | `PGUSER` | `''` | |
| `db_password` | `-w`/`--db_password` | `PGPASSWORD` | `''` | |
| `db_name` | `-d`/`--database` | `PGDATABASE` | `[]` | |
| `db_maxconn` | `--db_maxconn` | — | `64` | Max physical PG connections |

### Security

| Option | CLI flag | Default | Notes |
|---|---|---|---|
| `admin_passwd` | **none** (file-only) | `'admin'` | Protects DB manager. **File-only**: no `--admin-passwd` CLI flag exists. Declared as `FileOnlyOption` in `config.py`. The entrypoint templates `${ODOO_MASTER_PASSWORD}` → this key; if unset, a random password is generated. At runtime Odoo hashes it with `pbkdf2_sha512`. |
| `list_db` | `--no-database-list` | `True` | Set `list_db = False` in conf (or pass `--no-database-list`) to hide the DB selector and manager — required in production. |

### Web & proxy

| Option | CLI flag | Default | Notes |
|---|---|---|---|
| `dbfilter` | `--db-filter` | `''` | Regex to select DB from request host/domain. Supports `%h` (full host) and `%d` (domain without TLD). |
| `proxy_mode` | `--proxy-mode` | `False` | Must be `True` when Odoo sits behind a reverse proxy (rewrites `X-Forwarded-*` headers). |
| `http_port` | `-p`/`--http-port` | `8069` | |

### Data & addons

| Option | CLI flag | Default |
|---|---|---|
| `data_dir` | `-D`/`--data-dir` | Platform-computed; on Linux: `/var/lib/Odoo` (product name). This image pins it to `/var/lib/odoo` via `ODOO_DATA_DIR` in `entrypoint.sh`. |
| `addons_path` | `--addons-path` | `[]` (built from scan) |

`addons_path` validation: invalid or non-addon directories are **silently dropped** (`_check_addons_path` only appends paths that pass `_is_addons_path()`). If a custom path disappears between restarts, Odoo will not error — the module simply vanishes from the addons list.

### Workers & limits

| Option | CLI flag | Default |
|---|---|---|
| `workers` | `--workers` | `0` (threaded mode) |
| `limit_memory_soft` | `--limit-memory-soft` | `2048 MiB` |
| `limit_memory_hard` | `--limit-memory-hard` | `2560 MiB` |
| `limit_time_cpu` | `--limit-time-cpu` | `60 s` |
| `limit_time_real` | `--limit-time-real` | `120 s` |
| `max_cron_threads` | `--max-cron-threads` | `2` |

### Logging

| Option | CLI flag | Default | Notes |
|---|---|---|---|
| `log_level` | `--log-level` | `info` | Preset; choices: `info`, `debug`, `debug_sql`, `debug_rpc`, `debug_rpc_answer`, `warn`, `error`, `critical` |
| `logfile` | `--logfile` | `''` | Write to file; **mutually exclusive with `syslog`** |
| `syslog` | `--syslog` | `False` | Send to syslog; **mutually exclusive with `logfile`** |
| `log_handler` | `--log-handler` | `[':INFO']` | Per-module overrides (repeatable); see `observability.md` |

### Demo data

`with_demo` / `--without-demo` (default `False` = no demo). Set `with_demo = False` in conf or pass `--without-demo` to suppress demo data in new databases.

## CLI-only options (ignored in conf file)

These options have `file_loadable=False` and are **never read from `odoo.conf`**:

- `-i`/`--init MODULE,...` — install module(s) on startup
- `-u`/`--update MODULE,...` — update module(s) on startup
- `--stop-after-init` — exit after module install/update

Pass them directly on the command line alongside `-c /etc/odoo/odoo.conf` when needed.

## This image's conf template

The entrypoint (`entrypoint.sh`) writes `/etc/odoo/odoo.conf` on every start:

```ini
[options]
db_host = <ODOO_DB_HOST>
db_port = <DB_PORT>
db_user = <ODOO_DB_USER>
db_password = <ODOO_DB_PASSWORD>
data_dir = /var/lib/odoo
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/mnt/extra-addons
admin_passwd = <ODOO_MASTER_PASSWORD or random>
```

`data_dir` is always `/var/lib/odoo` (`ODOO_DATA_DIR` in the script). The file is regenerated on each pod start — manual edits are lost on restart.
