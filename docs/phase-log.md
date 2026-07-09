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
- [x] EA heartbeats confirmed end-to-end: `HEARTBEAT OK: HTTP 200` every ~30s in
      the EA's file log, matching new `heartbeat` rows in `system_events` and
      `GET /ping-db 200` entries in the bridge's own access log. (Live Experts-tab
      visibility confirmed via GUI; the on-disk terminal log buffers/flushes
      periodically and lags behind real Print() calls when the window isn't focused
      — cosmetic only, not a functional gap.)
- [x] Stopping the bridge produces a clear EA-side failure, not a silent stall:
      logged `HEARTBEAT FAILED: HTTP 1001` on every 30s tick while the bridge was
      down, then recovered automatically (`HEARTBEAT OK`) within one tick of the
      bridge coming back up.
- [x] EA (`Phase0Bridge.mq5`) compiles cleanly (0 errors, 0 warnings), deployed to
      the isolated MT5 instance's `MQL5\Experts\` folder, and is attached/running on
      an EURUSD Daily chart via MT5's `/config` startup-file mechanism (no manual
      drag-and-drop needed).

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

**Phase 0 acceptance criteria: all met.** Demo login and EA auto-attach ended up
possible without GUI interaction (MT5 auto-provisioned a demo account on first
launch of the copied install; the EA was auto-attached via a `/config` startup
file). The one setting that genuinely required the GUI (WebRequest allow-list —
confirmed by testing: editing `common.ini` directly did *not* actually enable it,
despite persisting correctly across restarts) was completed manually.

**Still open (deferred, not blocking):**
- Decide whether the bridge runs as a foreground process or scheduled task (deferred
  to Phase 4 per the build doc, as intended).
