# Trading Platform

Phase 0 skeleton: EA -> Python bridge -> Postgres -> EA heartbeat, fully logged.
No trading logic, no ML, no Telegram, no dashboard yet — see `docs/phase-log.md`.

This project is fully isolated from any other trading system on this machine:
- Its own PostgreSQL instance (port 5433, see `.env.example`), separate from any
  Postgres instance on the default port.
- Its own MT5 terminal instance (`C:\trading\_mt5-instance`), separate data folder,
  separate account — not the terminal any other EA is attached to.

## Setup

```powershell
cd bridge
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
copy ..\..env.example ..\.env   # then fill in real values
psql -h localhost -p 5433 -U trading_app -d trading_platform -f ..\database\schema.sql
uvicorn app.main:app --host 127.0.0.1 --port 8000
```

## MQL5 EA

`mt5/Phase0Bridge.mq5` — copy into the isolated MT5 instance's `MQL5\Experts\` folder.
Requires `http://127.0.0.1:8000` allow-listed under
Tools -> Options -> Expert Advisors -> Allow WebRequest for listed URL (manual, GUI-only step).
