-- Phase 0 minimal schema
-- Extend this in later phases; do not pre-build tables for features that don't exist yet.

CREATE TABLE IF NOT EXISTS system_events (
    id              BIGSERIAL PRIMARY KEY,
    source          TEXT NOT NULL,           -- 'bridge', 'ea', etc.
    event_type      TEXT NOT NULL,           -- 'heartbeat', 'startup', 'error', etc.
    payload         JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_system_events_created_at ON system_events (created_at);
CREATE INDEX IF NOT EXISTS idx_system_events_source ON system_events (source);

-- Phase 1: rule-based EA schema
-- Every setup the EA evaluates, whether taken or rejected
CREATE TABLE IF NOT EXISTS signals (
    id                  BIGSERIAL PRIMARY KEY,
    strategy_variant    TEXT NOT NULL DEFAULT 'phase1_confluence', -- 'phase1_confluence', 'phase1b_mean_reversion', ...
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
CREATE INDEX IF NOT EXISTS idx_signals_strategy_variant ON signals (strategy_variant);

-- Actual executed trades, linked back to the signal that triggered them
CREATE TABLE IF NOT EXISTS trades (
    id                  BIGSERIAL PRIMARY KEY,
    strategy_variant    TEXT NOT NULL DEFAULT 'phase1_confluence', -- 'phase1_confluence', 'phase1b_mean_reversion', ...
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
    exit_reason         TEXT,                      -- 'tp1', 'tp2', 'trailing_stop', 'sl_hit', 'breakeven', 'manual_close', 'daily_limit_close', 'timeout'
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

-- Phase: decision-support dashboard (post edge-search pivot)
-- Descriptive/mechanical market context, one row per instrument per H1 bar
-- close. Never a prediction/score -- see docs/phase-log.md for why.
CREATE TABLE IF NOT EXISTS market_context (
    id                  BIGSERIAL PRIMARY KEY,
    symbol              TEXT NOT NULL,
    snapshot_time       TIMESTAMPTZ NOT NULL,
    d1_trend            TEXT,
    h4_trend            TEXT,
    atr_value           DOUBLE PRECISION,
    volatility_regime   TEXT,
    session             TEXT,
    spread              DOUBLE PRECISION,
    nearest_level_distance_atr DOUBLE PRECISION,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (symbol, snapshot_time)
);

CREATE INDEX IF NOT EXISTS idx_market_context_symbol_time ON market_context (symbol, snapshot_time DESC);

-- Manually/discretionarily-entered trades. Deliberately separate from
-- `trades` (the automated-strategy table) -- different provenance, should
-- never be mixed into the automated system's own analysis without being
-- clearly distinguishable.
CREATE TABLE IF NOT EXISTS journal_trades (
    id                  BIGSERIAL PRIMARY KEY,
    symbol              TEXT NOT NULL,
    direction           TEXT NOT NULL CHECK (direction IN ('buy', 'sell')),
    open_time           TIMESTAMPTZ NOT NULL,
    close_time          TIMESTAMPTZ,
    open_price          DOUBLE PRECISION NOT NULL,
    close_price         DOUBLE PRECISION,
    stop_loss           DOUBLE PRECISION NOT NULL,
    take_profit         DOUBLE PRECISION,
    lot_size            DOUBLE PRECISION NOT NULL,
    r_multiple          DOUBLE PRECISION,
    rationale           TEXT,
    context_snapshot_id BIGINT REFERENCES market_context(id),
    outcome_notes       TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_journal_trades_symbol ON journal_trades (symbol);
CREATE INDEX IF NOT EXISTS idx_journal_trades_open_time ON journal_trades (open_time);

-- Phase: macro/rate-differential edge test (H1/H2, see docs/phase-log.md).
-- Point-in-time policy rates and 2Y/10Y government bond yields from FRED.
-- `vintage_date` is the real-time-vintage date this row's value was actually
-- published/known as of (FRED ALFRED real-time API) -- NOT the observation
-- date. A rate differential "as of" some hour must only join against rows
-- where vintage_date <= that hour's date, never a later-revised value. Most
-- of these series (market-observed daily rates/yields) are never revised
-- after publication, but this column exists so that assumption is enforced
-- explicitly, not silently relied on -- see Step 1's verification note.
CREATE TABLE IF NOT EXISTS macro_series (
    id                  BIGSERIAL PRIMARY KEY,
    source              TEXT NOT NULL DEFAULT 'fred',
    series_id           TEXT NOT NULL,        -- FRED series id, e.g. 'DGS10', 'DFF'
    currency            TEXT NOT NULL,        -- 'USD','EUR','GBP','JPY','AUD'
    series_type         TEXT NOT NULL,        -- 'short_rate' (policy-linked; see macro/fetch_fred.py for why '2y' isn't used -- FRED has no direct 2Y yield outside the US), 'yield_10y'
    obs_date            DATE NOT NULL,        -- the date the value describes
    vintage_date        DATE NOT NULL,        -- when this value was actually known/published
    value               DOUBLE PRECISION,
    fetched_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (source, series_id, obs_date, vintage_date)
);

CREATE INDEX IF NOT EXISTS idx_macro_series_lookup ON macro_series (currency, series_type, obs_date, vintage_date);

-- High-impact economic calendar events, timestamps only (CPI/NFP/GDP/rate
-- decisions). Sourced free from MT5's own live Calendar API -- confirmed
-- (docs/phase-log.md, Step 0.2) to retain historical actual-value timestamps
-- back to ~2015, but NOT historical consensus/forecast values. H2 was scoped
-- down accordingly: this table backs an event-occurrence study only, never
-- a surprise-magnitude one -- do not add a consensus/forecast column here
-- without re-opening the paid-source decision first.
CREATE TABLE IF NOT EXISTS macro_calendar_events (
    id                  BIGSERIAL PRIMARY KEY,
    currency            TEXT NOT NULL,
    event_name          TEXT NOT NULL,
    event_category      TEXT NOT NULL,        -- 'cpi','employment','gdp','rate_decision'
    release_time        TIMESTAMPTZ NOT NULL,
    actual_value        DOUBLE PRECISION,
    previous_value      DOUBLE PRECISION,
    importance          TEXT,                 -- MQL5 CALENDAR_IMPORTANCE_* as text
    fetched_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (currency, event_name, release_time)
);

CREATE INDEX IF NOT EXISTS idx_macro_calendar_events_lookup ON macro_calendar_events (currency, event_category, release_time);
