# Stack & Runtime

Odoo 19.0 FINAL (`release.py`: `version_info = (19, 0, 0, FINAL, 0, '')`). Requires Python 3.10–3.14 (`MIN_PY_VERSION = (3, 10)`, `MAX_PY_VERSION = (3, 14)`), PostgreSQL ≥ 13 (`MIN_PG_VERSION = 13`).

## Entry points

`odoo-bin` and `setup/odoo` are identical shims — both execute `odoo.cli.main()`:

```
#!/usr/bin/env python3
import odoo.cli
if __name__ == "__main__":
    odoo.cli.main()
```

`odoo` (the installed script from `setup.py`'s `scripts=['setup/odoo']`) is the same. All three are equivalent. Use whichever is on `$PATH` — in this container it is `odoo`.

## Subcommands (`odoo/cli/command.py`)

If no subcommand is given, `server` is the default. Known built-in subcommands (one `.py` per file in `odoo/cli/`):

| Subcommand | Purpose |
|---|---|
| `server` | Start the HTTP/WSGI server (default when no subcommand) |
| `shell` | Interactive Python REPL with ORM env |
| `db` | Database management utilities |
| `module` | Module operations |
| `neutralize` | Neutralize a production database for staging |
| `scaffold` | Generate module skeleton |
| `populate` | Populate database with test data |
| `deploy` | Deploy a module to a running instance |
| `cloc` | Count lines of Odoo-specific code |
| `upgrade_code` | Assist with version upgrades |

Addons can register additional commands via `cli/<command>.py` in their module directory.

## Process model (`odoo/service/server.py`)

Selection logic in `start()`:

- `workers = 0` (default) → **ThreadedServer**: single process, multi-threaded. This is PID 1 in the container.
- `workers > 0` → **PreforkServer**: parent + worker child processes.
- Gevent: selected only if `odoo.evented` is true (not used in this deployment).

**Signal handling (ThreadedServer):**

| Signal | Effect |
|---|---|
| `SIGTERM` (first) | Graceful shutdown — waits up to 1 s for in-flight requests |
| `SIGTERM` (second) | Forced exit (`os._exit(0)`) |
| `SIGINT` (first) | Same as first `SIGTERM` |
| `SIGHUP` | Sets `server_phoenix = True`, initiates re-exec of the process |
| `SIGQUIT` | Dumps stack traces (no shutdown) |

## Restarting Odoo

Odoo is PID 1 in its container: the entrypoint `exec`s into `/usr/bin/python3 /usr/bin/odoo -c /etc/odoo/odoo.conf`, and the clouve-ops `sshd` runs as its child. To restart Odoo, send it `SIGHUP` over the clouve-ops channel:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  'grep -q odoo /proc/1/cmdline && sudo kill -HUP 1'
for i in $(seq 1 30); do
  sleep 2
  curl -fsS -o /dev/null "http://${ODOO_HOST}:8069/web/health" && { echo "Odoo is back"; break; }
done
```

Odoo gives in-flight requests up to a second, logs "Initiating server reload", and re-executes itself with the same arguments (`_reexec()` in `odoo/service/server.py`). The container keeps running, `sshd` and your SSH session survive, and `/web/health` answers again within seconds. Checked on Odoo 19 on 2026-10-20: about half a second on a small database, two restarts in a row, same container, no container restart. The new process reads `odoo.conf` and `addons_path` again, so it loads a module folder just added to `/mnt/extra-addons`. It does not rerun the entrypoint, so environment changes don't apply.

Installing or upgrading a module needs no restart (see [playbooks/install-or-upgrade-module.md](../playbooks/install-or-upgrade-module.md)). Don't send `SIGTERM` or `SIGKILL` to PID 1: Odoo exits and the container stops with it. And don't hand restarts to the tenant: the Clouve dashboard has no restart button.

## Canonical paths (this image)

| Path | Role |
|---|---|
| `/etc/odoo/odoo.conf` | Configuration file (written by entrypoint from env vars) |
| `/var/lib/odoo` | Data directory (`data_dir`): filestore, sessions, addons cache |
| `/mnt/extra-addons` | Custom/community addons mount point |
| `/usr/lib/python3/dist-packages/odoo/addons` | Core Odoo addons (shipped in image) |

These are hardcoded in `entrypoint.sh` (`ODOO_CONF`, `ODOO_DATA_DIR`) and in the generated `odoo.conf` `addons_path` line.
