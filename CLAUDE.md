# CLAUDE.md

## Critical context: this server hosts two unrelated trading systems

This box also has a pre-existing, **unrelated** trading system at `C:\forex-system`
(same directory also reachable as `C:\claude mds`). It has its own MT5 terminal
(demo account `108946279`) and its own PostgreSQL database (`forex_trading_db`,
port 5432, default instance). **Never touch that system, its files, its Postgres
instance, or its MT5 terminal** — this project (`C:\trading`) is deliberately built
as a fully separate, isolated system on the same machine, and must stay that way.

## This project's isolation

- **PostgreSQL**: a second, independent instance at `C:\trading\_postgres`
  (portable binaries, not the Windows installer — see gotcha below), data directory
  `C:\trading\_postgres_data`, running on **port 5433** (not the default 5432).
  Database `trading_platform`, app role `trading_app`. Credentials in `.env`
  (gitignored) — see `PG_SUPERUSER_PASSWORD` there for admin access.
- **MT5**: a second, independent terminal instance at `C:\trading\_mt5-instance`
  (copied install, own data folder under `%APPDATA%\MetaQuotes\Terminal\<hash>`),
  logged into its own demo account (`109430476`), separate from the existing
  system's terminal/account.
- **Bridge service**: FastAPI app in `bridge/`, binds to `127.0.0.1:8000` only —
  never expose on the public interface, there's no auth on it.

## Gotcha: don't use the PostgreSQL Windows installer for a second instance

If you ever need another isolated Postgres instance on this box, use the portable
zip binaries (`postgresql-<version>-windows-x64-binaries.zip` from EDB) plus
`initdb` — **not** the `.exe` installer. The installer detects an existing install
at the default path and silently ignores custom `--prefix`/`--datadir`/
`--servicename` args passed via `Start-Process -ArgumentList` (quoting gets
mangled), then does an in-place repair over the existing install. This caused a
~22 minute outage of the existing system's Postgres service during Phase 0 (no
data loss, but avoidable). Portable binaries + `initdb` have no "existing install"
detection to trip over.

## Gotcha: MT5's WebRequest allow-list can't be set from a script

Editing `common.ini` (`WebRequest=1` / `WebRequestUrl=...`) directly does **not**
actually enable it, even though the change persists across terminal restarts —
confirmed by testing. It must be set via the GUI: Tools → Options → Expert
Advisors → Allow WebRequest for listed URL. Demo login and EA chart-attach, by
contrast, *can* be scripted (MT5 auto-provisions a demo account on first launch of
a fresh install; the EA can be auto-attached via a `/config` startup ini file).

## Running things

```powershell
cd bridge
.venv\Scripts\activate
uvicorn app.main:app --host 127.0.0.1 --port 8000

# Postgres access (isolated instance)
C:\trading\_postgres\bin\psql.exe -U trading_app -h localhost -p 5433 -d trading_platform
```

## Project status

See `docs/phase-log.md` for what's been built and verified per phase. Phase 0
(EA → bridge → Postgres heartbeat, fully logged) is complete. Don't start Phase 1
work without the user's go-ahead — each phase in this build has explicit
non-goals, and scope creep across phases is the main risk called out in the
original build instructions.
