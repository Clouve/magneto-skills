---
name: mern
description: Build, run, and operate MERN-stack apps (MongoDB, Express, React, Node) on a Debian/Ubuntu Linux system. Use when the user describes a Node.js / Express backend, a React frontend, MongoDB persistence, or any combination thereof — including phrases like 'MERN', 'Mongo', 'Express', 'Next.js app', 'React app', 'npm', 'pnpm', 'yarn', 'package.json', 'systemd unit for node', 'pm2', or 'mongoose'. Do not use for non-Node web stacks (PHP, Python, Go, Ruby) or for cloud-hosted MongoDB Atlas administration.
type: devops
version: 0.2.0
authoredAgainst: nodejs 22 (LTS), mongodb 7.0
---

# MERN Stack Skill

You build and operate MERN apps — MongoDB + Express + React + Node — running on a Debian/Ubuntu Linux system. Your job is to translate user intent ("build me a notes app", "add user auth", "deploy this to my server") into a running, verified MERN application.

## When to use this skill

Use this skill when the user wants to build, run, or operate a MERN-stack app (Node.js + Express backend + React frontend + MongoDB database), or any meaningful subset (e.g. "just the Express + Mongo backend", "just a React frontend hitting an existing API"). Trigger keywords include `MERN`, `Mongo`/`MongoDB`, `Express`, `Node`/`Node.js`, `React`, `Next.js`, `Vite`, `npm`/`pnpm`/`yarn`, `package.json`, `mongoose`, `systemd unit for node`, `pm2`.

## When NOT to use this skill

- Non-Node web stacks (PHP, Python, Go, Ruby, Rust, Elixir) — not MERN.
- Cloud-hosted MongoDB Atlas administration (you don't have shell access to Atlas; only to the user's own database servers).
- Front-end-only work that doesn't touch Node tooling (pure HTML/CSS/static sites).
- Operating system or platform administration unrelated to a MERN app (firewall, user accounts, system services). Defer to a system-administration skill if one exists.

## Stack version pins (v0)

- **Node.js 22 LTS** via NodeSource apt repo.
- **MongoDB 7.0** community edition via the official mongodb-org apt repo.
- **npm** (bundled with Node). If the user prefers `pnpm` or `yarn`, install on request — npm is the default.

## Project layout convention

```
~/projects/<slug>/
├── backend/                  Express app — package.json, src/, .env
├── frontend/                 React + Vite app — package.json, src/, vite.config.*
├── README.md                 user-facing; what the app does
└── NOTES.md                  your decisions: ports, service (unit/program) names, env-var sources (one line each)
```

Monorepo (`backend/` + `frontend/` under one project dir) is the default. Two-repo split is fine if the user asks for it. `~/projects/<slug>/` is the convention; substitute the user's preferred directory if they have one (e.g. `/srv/www/<slug>/`, `/opt/<slug>/`).

On the Clouve AI Studio workspace this layout ships **pre-seeded as a running starter project** (Express API + Vite React frontend + one Mongo collection, all supervised) — extend that project rather than scaffolding a new one unless the user asks for a separate app.

## Process supervision: systemd or supervisord

This skill's service-management steps depend on the host's init system. Check once with `command -v systemctl && systemctl is-system-running 2>/dev/null` — on hosts where systemd is absent or not PID 1 (notably the **Clouve AI Studio workspace, where supervisord is PID 1 and `systemctl` fails**), substitute the supervisord variants given alongside each systemd step below. On AI Studio, program confs belong in `/opt/clouve/supervisord.d/` (persistent across pod restarts); the seeded starter project is the living example of every pattern in this skill.

## Backend (Express) — production shape

1. **Bind Express to `127.0.0.1:<port>`, not `0.0.0.0`,** unless the user explicitly wants the backend reachable from outside the host. Binding to all interfaces invites accidents on systems with weak firewall rules. For external access, run nginx (or another reverse-proxy) in front of Express and terminate TLS there. **Exception — AI Studio:** services the user should reach in a browser must bind `0.0.0.0`, because the clv-proxy that publishes them lives in a different pod; the ai-studio skill's "Publishing an HTTP service" table governs there, and auth is enforced by the proxy.

2. **Run long-lived backends under the host's supervisor.** A backend started with `&` in an interactive shell dies when the shell exits. On systemd hosts, drop a unit file at `/etc/systemd/system/<slug>-backend.service`:

   ```ini
   [Unit]
   Description=<slug> backend (Express)
   After=network.target mongod.service
   Wants=mongod.service

   [Service]
   Type=simple
   User=<run-as-user>
   WorkingDirectory=/path/to/<slug>/backend
   EnvironmentFile=/path/to/<slug>/backend/.env
   ExecStart=/usr/bin/node src/server.js
   Restart=on-failure
   RestartSec=5

   [Install]
   WantedBy=multi-user.target
   ```

   Then `sudo systemctl daemon-reload && sudo systemctl enable --now <slug>-backend`. Set `User=` to the account that owns the project directory; never run as root.

   On supervisord hosts (AI Studio), drop a program conf at `/opt/clouve/supervisord.d/<slug>-backend.conf` instead:

   ```ini
   [program:<slug>-backend]
   command=/usr/bin/node --env-file=.env src/server.js
   directory=/path/to/<slug>/backend
   user=<run-as-user>
   environment=HOME="/home/<run-as-user>",USER="<run-as-user>"
   autorestart=true
   redirect_stderr=true
   stdout_logfile=/var/log/supervisor/<slug>-backend.log
   ```

   Then `sudo supervisorctl reread && sudo supervisorctl update`. supervisord has no `EnvironmentFile=` — load `.env` in the command itself (`node --env-file=.env`, Node ≥ 20.6) or enumerate vars in `environment=`.

3. **Logs** — systemd hosts: `journalctl -u <slug>-backend -f` for live tail, `journalctl -u <slug>-backend --since '5 minutes ago'` for recent. supervisord hosts: `sudo supervisorctl tail -f <slug>-backend`, or read `/var/log/supervisor/<slug>-backend.log`.

4. **`.env` lives at `backend/.env`, gitignored, mode `0600`,** owned by the same user the service (systemd unit or supervisord program) runs as. Required keys: `PORT`, `MONGO_URL` (default `mongodb://127.0.0.1:27017/<slug>`), `NODE_ENV=production`. Add app-specific keys as needed (`JWT_SECRET`, `SESSION_SECRET`, third-party API keys).

5. **Never echo, log, or commit secrets.** If the user pastes a secret in chat, write it to `.env` only, then verify presence with `grep -c '^KEY=' .env` rather than reading the value back. Keep `.env` in `.gitignore` and never `git add` it.

## Frontend (React + Vite) — production shape

1. Scaffold: `npm create vite@latest frontend -- --template react` (or `react-ts` for TypeScript). For full-framework needs, use `npm create vite@latest frontend -- --template react-ts` then add the user's preferred router/state library on top — don't reach for Next.js unless the user specifically asks.

2. **Default: build for production and serve statics from the backend.** Run `npm run build` to produce `frontend/dist/`, then in Express:

   ```js
   app.use(express.static(path.join(__dirname, '../../frontend/dist')));
   app.get('*', (_req, res) => res.sendFile(path.join(__dirname, '../../frontend/dist/index.html')));
   ```

   One process, one port, simplest deployable shape.

3. **Alternative: separate static server.** If the user wants nginx serving `dist/` on one port and Express on another (clearer separation, easier to tune caching headers), add an nginx `server` block for the frontend and a second systemd unit if needed. Rebuild the frontend (`npm run build`) on every deploy.

4. **Dev:** `npm run dev` runs Vite's dev server with HMR. Useful when iterating with the user attached to a shell, but it's not a production runtime — never wire it into a unit/program conf on a production host. **Exception — dev workspaces (AI Studio):** there the dev server *is* the product being iterated on, and it runs supervised (the seeded `frontend` program) so HMR survives pod restarts.

## MongoDB — install and persistence

1. **Install via the official apt repo** (verify the latest stable version with `apt-cache madison mongodb-org` once the repo is added; the commands below pin to 7.0):

   ```bash
   curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc \
       | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
   . /etc/os-release && CODENAME="$VERSION_CODENAME"
   # If the official repo doesn't ship the host's codename (common on
   # fresh-release LTSes), fall back to the latest available codename
   # that does — MongoDB packages are typically forward-compatible across
   # one LTS step. As a last resort, build from source.
   echo "deb [signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] https://repo.mongodb.org/apt/ubuntu ${CODENAME}/mongodb-org/7.0 multiverse" \
       | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list
   sudo apt-get update
   sudo apt-get install -y mongodb-org
   sudo systemctl enable --now mongod   # systemd hosts
   ```

   On supervisord hosts, instead of the `systemctl` line add a `[program:mongod]` conf (`command=/usr/bin/mongod --config /etc/mongod.conf`, `user=mongodb`) and `sudo supervisorctl reread && sudo supervisorctl update`. **On the AI Studio workspace skip this whole step — MongoDB 7.0 is pre-installed and already supervised as program `mongod`.**

2. **Data persists at `/var/lib/mongodb/`** (the apt-installed default). Make sure `/var` is on storage that survives reboots — on most Linux hosts this is automatic; on some container-based or ephemeral environments it isn't.

3. **Bind to `127.0.0.1:27017` only** (the apt-installed default). Don't enable auth in dev — the loopback-only bind is your security boundary. **Enable auth as soon as you bind to any non-loopback interface or expose Mongo through a reverse proxy.** The auth-enable flow: create an admin user via `mongosh`, edit `/etc/mongod.conf` to set `security.authorization: enabled`, restart `mongod`, then update every connecting app's `MONGO_URL` to include the credentials.

4. **Verify the install** with `mongosh --eval 'db.adminCommand({ping: 1})'` — expects `{ ok: 1 }`.

## Verifying a deploy

Before reporting "MERN app is running" to the user, confirm all four:

1. Both services are up — systemd hosts: `systemctl is-active mongod <slug>-backend` returns `active` for both; supervisord hosts: `sudo supervisorctl status mongod <slug>-backend` shows `RUNNING` for both.
2. `curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:<port>/` returns a 2xx — or the expected response code for the route you're probing.
3. `mongosh --eval "use <slug>; db.stats()"` shows the right database (non-empty `db` field, expected `collections` count).
4. The backend log is clean — systemd hosts: `journalctl -u <slug>-backend --since '5 minutes ago' | grep -iE 'error|fail|exception'`; supervisord hosts: `sudo tail -n 200 /var/log/supervisor/<slug>-backend.log | grep -iE 'error|fail|exception'` — empty (or only matches expected/benign lines).

If any of those four fails, you are NOT done. Report what failed and propose the next step. Don't claim success without evidence.

## Common patterns

- **Auth:** prefer JWT issued by Express (no session store needed) for SPAs; or `express-session` + a Redis or Mongo session store for traditional server-rendered apps. Use `bcrypt` (not `crypto.pbkdf2`) for password hashing.
- **API conventions:** REST is the default. Group routes under `/api/v1/` so the static SPA can serve from `/` without collision.
- **CORS:** if the frontend is served from the same Express process (the default in "Frontend §2"), CORS is unnecessary. If you've split them, enable `cors` middleware with an explicit origin allowlist — never `*` in production.
- **Validation:** validate request bodies with `zod` or `joi` at the route boundary. Don't trust `req.body`.
- **MongoDB schema:** use `mongoose` for schema enforcement unless the user has a strong reason not to. Define indexes in the schema (`schema.index({ field: 1 })`) so they get created on app start.

## Maintaining this skill

If during a session you discover a fact about MERN-stack operation that would help the next session — a quirk of a specific npm package, a MongoDB version-compatibility gotcha, a systemd interaction that bit you — surface it with the standard echo so a human operator can mirror it back into the source repo:

> _Captured to skill learnings: `learnings.md` — <one-line summary>_

Don't try to edit this file from the runtime container; the edit will be wiped on the next plugin-stager refresh.
