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

**Verified:** (fill in once end-to-end test runs)
- [ ] `uvicorn app.main:app` starts and logs `startup` to file + `system_events`.
- [ ] `GET /health` returns 200, no DB.
- [ ] `GET /ping-db` returns 200 and inserts a `heartbeat` row.
- [ ] EA heartbeats visible in MT5 Experts tab every ~30s.
- [ ] Stopping the bridge produces a clear EA-side failure log, not a silent stall.
- [ ] `pytest` passes in `bridge/`.

**Still open:**
- User must log into a demo account in the new isolated MT5 instance
  (`C:\trading\_mt5-instance\terminal64.exe`).
- User must allow-list `http://127.0.0.1:8000` in that instance's WebRequest settings.
- User must attach `Phase0Bridge.mq5` to a chart with AutoTrading enabled.
- Decide whether the bridge runs as a foreground process or scheduled task (deferred
  to Phase 4 per the build doc).
