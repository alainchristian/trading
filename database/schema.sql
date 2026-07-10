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
