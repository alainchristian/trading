# Phase 1 Build Instructions — Rule-Based EA (No AI, No Telegram)

**Audience:** Claude Code, running on the Contabo Windows Server. Phase 0 is complete and verified — bridge and Postgres are up, EA↔bridge heartbeat works.

**Goal of this phase:** Build the complete rule-based trading system described in the original spec — multi-timeframe trend, entry confluence, ATR stops, position sizing, partial TPs, trailing stop, and hard risk limits — as a standalone MQL5 EA that trades correctly in the Strategy Tester with **zero live dependency on the Python bridge**. The bridge is used only for logging (every signal, taken or rejected), not for any trading decision in this phase.

**This is the phase that determines whether the project has an edge at all.** Treat the acceptance criteria at the end as a real go/no-go gate, not a formality.

---

## 0. Decisions to confirm with the user before writing code

Do not assume these — ask, or if the user already answered in chat, use that answer explicitly rather than re-deriving it:

1. **Instrument(s) for the first pass.** Recommend starting with a single liquid pair (EURUSD) rather than multiple instruments at once — confluence and risk logic is hard enough to validate on one symbol before generalizing. If the user hasn't specified, propose EURUSD and confirm.
2. **How much historical M1/M15 data is available** in MT5 for backtesting. Strategy Tester needs enough history across the D1/H4/H1 stack to cover multiple market regimes (at minimum a trending period, a ranging period, and a high-volatility period — realistically 3-5+ years). Check via MT5's History Center and report what's actually available before assuming.
3. **News filter approach for this phase.** MT5's Strategy Tester can incorporate the built-in Economic Calendar in recent builds, but calendar-based backtesting is less mature and less transparent than price-based logic. Recommended approach: build the news filter as a togglable module (`InpUseNewsFilter`), verify whether the installed MT5 build actually supports calendar data in the tester, and if not, treat it as live-only for now (works on demo/real, disabled during backtests) rather than blocking the whole phase on it. Confirm this plan with the user rather than silently deciding.

---

## 1. Database additions

Phase 0 only has `system_events`. Phase 1 needs real structured logging — of every setup the EA *considers*, not just the ones it takes, because Phase 3's "should I trade at all?" model will need negative examples too.

Add to `database/schema.sql` (append, don't rewrite the file):

```sql
-- Every setup the EA evaluates, whether taken or rejected
CREATE TABLE IF NOT EXISTS signals (
    id                  BIGSERIAL PRIMARY KEY,
    symbol              TEXT NOT NULL,
    signal_time         TIMESTAMPTZ NOT NULL,
    direction           TEXT NOT NULL CHECK (direction IN ('buy', 'sell')),
    d1_trend            TEXT,               -- 'bullish', 'bearish', 'sideways'
    h4_setup_valid      BOOLEAN,
    h1_entry_trigger    TEXT,               -- e.g. 'bullish_engulfing', 'rsi_oversold_pullback'
    atr_value           DOUBLE PRECISION,
    proposed_entry      DOUBLE PRECISION,
    proposed_sl         DOUBLE PRECISION,
    proposed_tp1        DOUBLE PRECISION,
    proposed_tp2        DOUBLE PRECISION,
    risk_percent        DOUBLE PRECISION,
    lot_size            DOUBLE PRECISION,
    spread_at_signal    DOUBLE PRECISION,
    session             TEXT,               -- 'london', 'ny', 'overlap', 'asia', 'off_hours'
    taken               BOOLEAN NOT NULL,
    rejection_reason    TEXT,               -- null if taken; e.g. 'daily_loss_limit', 'spread_too_wide', 'outside_session'
    features            JSONB,              -- full feature snapshot for later ML use
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_signals_symbol_time ON signals (symbol, signal_time);
CREATE INDEX IF NOT EXISTS idx_signals_taken ON signals (taken);

-- Actual executed trades, linked back to the signal that triggered them
CREATE TABLE IF NOT EXISTS trades (
    id                  BIGSERIAL PRIMARY KEY,
    signal_id           BIGINT REFERENCES signals(id),
    ticket              BIGINT NOT NULL UNIQUE,
    symbol              TEXT NOT NULL,
    direction           TEXT NOT NULL CHECK (direction IN ('buy', 'sell')),
    open_time           TIMESTAMPTZ NOT NULL,
    close_time          TIMESTAMPTZ,
    open_price          DOUBLE PRECISION NOT NULL,
    close_price         DOUBLE PRECISION,
    initial_sl          DOUBLE PRECISION NOT NULL,
    initial_tp1         DOUBLE PRECISION,
    initial_tp2         DOUBLE PRECISION,
    lot_size            DOUBLE PRECISION NOT NULL,
    r_multiple          DOUBLE PRECISION,          -- realized R, computed on close
    mfe                 DOUBLE PRECISION,          -- max favorable excursion, in price units
    mae                 DOUBLE PRECISION,          -- max adverse excursion, in price units
    exit_reason         TEXT,                      -- 'tp1', 'tp2', 'trailing_stop', 'sl_hit', 'breakeven', 'manual_close', 'daily_limit_close'
    profit              DOUBLE PRECISION,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_trades_symbol ON trades (symbol);
CREATE INDEX IF NOT EXISTS idx_trades_open_time ON trades (open_time);

-- Daily/weekly risk state, one row per trading day per symbol-group (or 'all')
CREATE TABLE IF NOT EXISTS risk_state (
    id                  BIGSERIAL PRIMARY KEY,
    trading_date        DATE NOT NULL,
    scope               TEXT NOT NULL DEFAULT 'account',  -- 'account' for now; per-symbol later if needed
    starting_balance    DOUBLE PRECISION NOT NULL,
    realized_pnl        DOUBLE PRECISION NOT NULL DEFAULT 0,
    loss_limit_hit       BOOLEAN NOT NULL DEFAULT false,
    trading_halted      BOOLEAN NOT NULL DEFAULT false,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (trading_date, scope)
);
```

Do not add tables for predictions, model versions, or Telegram logs yet — still premature.

---

## 2. Bridge additions

Add two endpoints to the existing FastAPI app (`bridge/app/routers/`), following the same pattern as `health.py`:

- `POST /log-signal` — accepts a JSON body matching the `signals` columns, inserts a row, returns the new `id`.
- `POST /log-trade` — accepts a JSON body matching `trades` columns for trade open, and a separate `PATCH /log-trade/{ticket}` for updating on close (close_time, close_price, r_multiple, mfe, mae, exit_reason, profit).

Keep these simple — direct inserts/updates, pydantic models for validation, no business logic in the bridge. All trading logic lives in MQL5; the bridge is a dumb logger in this phase, consistent with the AI Decision Policy's separation of concerns (execution and rules stay in the EA even before any AI is involved).

The EA calls these over the same `WebRequest` mechanism proven in Phase 0. **Logging calls must never block or fail a trade decision** — wrap them so that if the bridge is unreachable, the EA logs locally (file) and proceeds; a down logger should not stop the EA from managing an open position. This is the inverse of the Phase 4 policy (where a down AI service blocks new entries) — logging failure is not a reason to fail closed, because it can't affect risk, only record-keeping.

---

## 3. EA architecture

Build this as multiple `.mqh` include files plus one `.mq5` entry file, not one monolithic script — you'll be iterating on entry logic far more than risk logic, and mixing them makes that iteration error-prone.

```
mt5/
├── Phase1EA.mq5              # main entry: OnInit/OnTick/OnTimer, wires modules together
└── Include/
    ├── Trend.mqh              # D1/H4 trend classification
    ├── Structure.mqh          # support/resistance, swing highs/lows, supply/demand zones
    ├── Momentum.mqh           # RSI, MACD, ADX confluence checks
    ├── Volatility.mqh         # ATR calculations, volatility regime
    ├── EntryLogic.mqh         # H1 confluence check, produces a Signal struct
    ├── RiskManager.mqh        # position sizing, daily/weekly loss limits, max exposure
    ├── ExitManager.mqh        # partial TPs, trailing stop, breakeven logic
    ├── SessionFilter.mqh      # London/NY/overlap session checks
    ├── SpreadFilter.mqh       # spread/slippage guards
    ├── NewsFilter.mqh         # togglable, see Section 0.3
    └── BridgeLogger.mqh       # wraps WebRequest calls to /log-signal, /log-trade
```

### `Trend.mqh` — D1 strategic direction
- EMA 50/200 relationship on D1 for baseline direction.
- ADX on D1 to distinguish trending vs. ranging (e.g. ADX > 25 = trending).
- Market structure check: higher highs/higher lows (or the inverse) over a configurable lookback of swing points.
- Output: an enum `TREND_STRONG_UP`, `TREND_WEAK_UP`, `TREND_STRONG_DOWN`, `TREND_WEAK_DOWN`, `TREND_SIDEWAYS` — this maps directly onto the market regime classification the AI will later refine, so get the definition right now rather than renaming it in Phase 3.

### `Structure.mqh` — support/resistance, supply/demand
- Swing high/low detection (fractal-based or N-bar lookback, your choice, but document which and make the lookback an input parameter, not a magic number).
- A basic supply/demand zone definition (e.g. the last strong impulse candle's origin range) — keep this simple in v1; this is an area that's easy to over-engineer before you know if it adds predictive value.

### `Momentum.mqh` — H1/H4 confirmation
RSI, MACD, ADX as configurable-threshold confirmations, not hardcoded to one setting — position sizing and entry confluence will need tuning per instrument later.

### `Volatility.mqh`
ATR on the relevant timeframes, feeding both the stop-loss calculation (Section 4) and a simple volatility regime classifier (e.g. current ATR vs. its own N-period average → "high"/"normal"/"low").

### `EntryLogic.mqh` — the confluence check
Implement exactly the sequence from the original spec, as an explicit ordered checklist, each step producing a pass/fail plus a reason string (this reason string is what populates `rejection_reason` in the `signals` table):

1. D1 trend must be `STRONG_UP`/`STRONG_DOWN` (or configurably include `WEAK_*` — make this an input flag; you'll want to backtest both).
2. H4 confirms the same direction and shows a valid pullback/continuation setup (not a fresh breakout without pullback, per the "recommended workflow" — pullback entries are the default logic here).
3. Price is at/near a key H4/D1 support or resistance level or supply/demand zone (Section on `Structure.mqh`).
4. H1 momentum confirms (RSI not extended against the trade direction, e.g. RSI < 40 recovering for a long).
5. H1 candlestick trigger present (engulfing, pin bar, etc. — pick 2-3 patterns for v1, not an exhaustive library).
6. Volume/tick-volume increase on the trigger candle, if available for the instrument.

Every one of these six checks must independently pass or fail and be logged — do not collapse them into a single boolean. When Phase 3 trains "was this setup good," it needs to see *which* conditions were marginal, not just a final yes/no.

Only if all six pass does `EntryLogic.mqh` produce a `Signal` struct, which then goes through `RiskManager.mqh` before any order is placed.

---

## 4. Position sizing and stop loss

### Position sizing (`RiskManager.mqh`)
```
lot_size = (account_balance × risk_percent) / (stop_loss_distance_in_points × point_value)
```
- `risk_percent` is an input parameter, default 1%, configurable range 0.5-2% per the spec.
- Round down to the broker's allowed lot step, never up — rounding up silently increases risk beyond the configured percentage, which defeats the purpose of this whole module.
- Reject the trade (log `rejection_reason = 'lot_size_below_minimum'`) if the calculated size rounds to below the broker's minimum lot — do not silently bump it up to the minimum, since that would violate the risk percentage the user configured.

### Stop loss
Implement ATR-based as the default (`SL = entry - (ATR × multiplier)`, multiplier as an input, e.g. 1.5-2.0), with swing-high/low as an alternative mode selectable via input parameter. Whichever is used, the resulting SL distance is what feeds the position-sizing formula above — sizing must always be calculated *after* the SL is set, never the reverse.

---

## 5. Exit management (`ExitManager.mqh`)

- Partial close 30% at 1R, 30% at 2R, per the spec — implement the R-multiple calculation from the *initial* SL distance, and keep that initial distance fixed for R-multiple purposes even after the SL is later moved to breakeven or trailed (otherwise "1R" drifts and your logged `r_multiple` becomes meaningless for later analysis).
- Move remaining 40% to breakeven after TP1 hits.
- Trail the remainder — implement ATR trailing as the default mode, with structure trailing (below swing lows / above swing highs) as an alternate input-selectable mode.
- Every partial close and SL modification should update the `trades` row via `/log-trade` (or log locally if the bridge is unreachable, per Section 2).

---

## 6. Risk controls (`RiskManager.mqh`, continued)

- Daily loss limit: check `risk_state` at the start of each trading day (create the row if missing, using current balance as `starting_balance`); block new entries once `realized_pnl` breaches the configured daily loss percent, and log every blocked attempt with `rejection_reason = 'daily_loss_limit'`.
- Weekly loss limit: same mechanism, aggregated across the week.
- Max drawdown: track equity peak since EA start (or since a configurable reset point) and halt new entries past the configured max drawdown percent.
- Max open trades / max exposure per symbol: straightforward counters checked before any new entry.

Decide now, and document in `docs/phase-log.md`, whether hitting the daily loss limit should also **close existing open positions** or just **block new entries**. The spec's Section 7 lists this as a control on new trading, and Section 10 separately mentions closing trades early "if market conditions change" — these are different behaviors. Default recommendation: block new entries only; forcibly closing open positions on a daily-limit breach is a separate, more aggressive policy that deserves its own explicit backtest comparison rather than being bundled in by default.

---

## 7. Session and spread filters

- `SessionFilter.mqh`: define London/NY/overlap hours in server time, with an explicit note in code comments about the offset between the broker's server time and UTC (this varies by broker and DST — do not hardcode assuming server time = UTC).
- `SpreadFilter.mqh`: reject entries when `SymbolInfoInteger(symbol, SYMBOL_SPREAD)` exceeds a configurable max, logged as `rejection_reason = 'spread_too_wide'`.

---

## 8. What "done" looks like structurally

Every rejected and every taken setup ends up as a row in `signals`. Every executed trade ends up as a row in `trades`, linked to its signal, updated through its life (partial closes, SL moves) and finalized on close with `r_multiple`, `mfe`, `mae`, and `exit_reason` populated. Nothing about this requires the AI/Telegram/dashboard pieces — it's a complete, self-contained, testable trading system.

---

## 9. Validation plan — this is the actual point of the phase

1. **In-sample backtest** in Strategy Tester across the full available history for the confirmed instrument, using realistic spread/commission/slippage settings (do not use the tester's default "every tick based on real ticks" without confirming it's actually using real historical spread rather than a fixed one — check the symbol's data quality in the tester report).
2. **Walk-forward validation**: split history into sequential windows (e.g. optimize on 12 months, test forward on the next 3, roll forward). Do not optimize parameters on the full history and then claim the same period as out-of-sample — that's the single most common source of a backtest that looks great and fails live.
3. **Report, per window and in aggregate**: net profit, profit factor, max drawdown, win rate, average R-multiple, largest losing streak. Compare against a simple benchmark (e.g. the same entry logic with fixed 1% risk but no confluence filters at all) to check whether the confluence conditions are actually adding value or just reducing trade count without improving expectancy.
4. **Go/no-go**: only if walk-forward windows show consistent (not just aggregate-positive) expectancy after realistic costs should this move to demo-account forward testing, and only after that to Phase 2/3 planning.

---

## Explicit non-goals for this phase

- No calls to any prediction/ML endpoint — none exists yet.
- No Telegram notifications.
- No dashboard.
- No live/real-money trading — Strategy Tester and, once validated, demo account only.
- Do not let `EntryLogic.mqh` grow to include indicators or patterns "just in case" beyond what Section 3 specifies — add complexity only after the simpler version has been walk-forward tested and shown to need it.

---

## Acceptance criteria

- [ ] EA compiles with zero warnings and runs in Strategy Tester on the confirmed instrument/date range.
- [ ] Every one of the six entry-confluence checks logs its individual pass/fail state, visible in the `signals` table (or local log if bridge down during the test run — confirm which applies to Strategy Tester specifically, since `WebRequest` behaves differently in the tester than live).
- [ ] Position sizing never exceeds the configured risk percent, verified by spot-checking several `trades` rows against the formula by hand.
- [ ] Daily/weekly loss limits demonstrably block new entries in at least one backtest window that had a bad enough day/week to trigger them.
- [ ] Walk-forward report produced per Section 9, with at least 3 sequential out-of-sample windows.
- [ ] A documented go/no-go decision recorded in `docs/phase-log.md`, based on the walk-forward results — not a subjective "looks promising."
