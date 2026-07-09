# Phase Log

## 2026-07-09 — Phase 0: foundation

**Done:**
- Verified environment: MT5 (existing install), Python 3.11.9, PostgreSQL 15 (existing
  instance on port 5432, owned by an unrelated pre-existing project), Git 2.54.
- Discovered a pre-existing, unrelated trading system already on this box
  (`C:\forex-system`, aka `C:\claude mds` — same directory) with a live-looking EA
  (`SignalBridge.mq5`) already deployed to the default MT5 terminal. Decided to build
  this project in full isolation rather than extend/share that system.
- Set up a second, fully isolated MT5 terminal instance at `C:\trading\_mt5-instance`
  (copied install, launched once to generate its own data folder/hash, separate from
  the existing terminal).
- Noted: an `llm-agent` folder auto-populates inside any MT5 terminal data folder on
  this box (cause not identified — no matching process/service/scheduled task found).
  Doesn't interact with anything in this project; left untouched.
- Installed a second, fully isolated PostgreSQL 15.7 instance at `C:\trading\_postgres`
  (data dir `C:\trading\_postgres_data`), service name `postgresql-phase0`, port 5433 —
  independent of the existing Postgres instance on port 5432. Avoided touching the
  existing instance's `postgres` superuser (password unknown/unrecoverable) entirely.
- Backed up the existing project's database (`forex_trading_db`) to
  `C:\trading\_pg_backup\` before any of the above, as a precaution (not otherwise
  used by this project).
- Built repo skeleton: `.gitignore`, `.env.example`, `database/schema.sql`
  (`system_events` table), FastAPI bridge (`bridge/app/*`), `mt5/Phase0Bridge.mq5`.

**Verified:**
- [x] `uvicorn app.main:app` starts and logs `startup` to file + `system_events`.
- [x] `GET /health` returns 200, no DB.
- [x] `GET /ping-db` returns 200 and inserts a `heartbeat` row (confirmed via direct
      query against `system_events`).
- [x] `pytest` passes in `bridge/` (2 passed, 0 warnings).
- [ ] EA heartbeats visible in MT5 Experts tab every ~30s. (blocked on manual steps below)
- [ ] Stopping the bridge produces a clear EA-side failure log, not a silent stall.
      (blocked on manual steps below)
- [x] EA (`Phase0Bridge.mq5`) compiles cleanly (0 errors, 0 warnings) and is deployed
      to the isolated MT5 instance's `MQL5\Experts\` folder.

**Also done (not in original scope, but required to get here safely):**
- Isolated Postgres instance ended up needing two attempts. First attempt (installer
  with custom `--prefix`/`--datadir`/`--servicename`) silently ignored those flags due
  to a `Start-Process -ArgumentList` quoting bug and instead repaired the *existing*
  Postgres install in place, causing a ~22 minute outage of the existing
  `postgresql-x64-15` service (10:29-10:51 local). No data loss confirmed (binary
  untouched, service recovered, `forex_trading_db` intact). Second attempt used the
  portable zip binaries (no installer, no "detect existing install" behavior) — clean,
  fully isolated at `C:\trading\_postgres` / `C:\trading\_postgres_data`, port 5433.
- Initial git commit pushed to `https://github.com/alainchristian/trading.git` (branch
  `main`), using stored Windows Credential Manager credentials for `alainchristian`.

**Still open — manual, GUI-only steps (cannot be done from the CLI):**
- Log into a demo account in the new isolated MT5 instance
  (`C:\trading\_mt5-instance\terminal64.exe`).
- Allow-list `http://127.0.0.1:8000` in that instance's WebRequest settings
  (Tools -> Options -> Expert Advisors -> Allow WebRequest for listed URL).
- Attach `Phase0Bridge.mq5` to a chart with AutoTrading enabled, confirm heartbeat
  lines in the Experts tab, then stop the bridge service and confirm a clear failure
  line appears on the next timer tick.
- Decide whether the bridge runs as a foreground process or scheduled task (deferred
  to Phase 4 per the build doc).
