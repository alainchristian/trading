# Phase Log

## Bug vs. strictness criterion

A confluence gate change is treated as a **bug fix** only if it corrects a
logical contradiction against the spec's own stated intent (e.g. the H4
pullback fix — requiring the fast EMA to agree with trend direction
contradicted the spec's explicit pullback-entry description). A change made
**because trade frequency was too low, with no such contradiction
identified**, is a **strictness change** — it may still be the right call,
but it must be labeled as such, tested in isolation, and never justified by
"it produced more trades" alone.

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

## 2026-07-09 — Phase 1: rule-based EA (build + initial verification)

**Confirmed with user before building:** instrument = EURUSD only. News filter =
build a real togglable module using MQL5's Calendar API rather than assuming a
live-only fallback (terminal build 5.0.0.5975 seemed modern enough) — see
platform-behavior findings below for how this actually played out empirically.

**Built:**
- `database/schema.sql`: appended `signals`, `trades`, `risk_state` tables per
  the phase doc, applied to the isolated Postgres instance (port 5433).
- Bridge: `POST /log-signal`, `POST /log-trade`, `PATCH /log-trade/{ticket}`,
  `POST /log-risk-state`, `POST /log-event` (generic `system_events` writer),
  and `GET /trades/{ticket}`. The last three are small additions beyond the
  original doc's endpoint list, each flagged at the time: `GET /trades/{ticket}`
  lets the EA reconcile a lost GlobalVariable's `initial_sl` from Postgres
  rather than permanently losing that trade's R-multiple; `/log-risk-state`
  and `/log-event` exist because the doc specified the `risk_state` table and a
  `system_events`-based partial-close audit trail but never defined bridge
  endpoints for either. 22 bridge tests passing (`pytest` in `bridge/`).
- MQL5 EA (`mt5/Phase1EA.mq5` + 11 `Include/*.mqh` modules): D1 trend
  classification (EMA50/200 + ADX + structure), hand-rolled N-bar fractal
  swing detection, RSI/MACD/ADX momentum, ATR volatility + regime, the
  six-step entry confluence checklist (each check always independently
  evaluated and logged, never short-circuited, per the doc's explicit
  requirement), ATR/swing SL modes, risk-percent position sizing (rounds down,
  rejects below min lot rather than bumping up), partial TP at 1R/2R with
  breakeven-after-TP1 and ATR/structure trailing on the remainder, daily/weekly
  loss limits + max drawdown + max exposure computed entirely from MT5's own
  account/history data (never blocking on the bridge), session/spread/news
  filters, and a GlobalVariable-based (`P1_*` prefix) position-state
  persistence layer for R-multiple/MFE/MAE that survives EA restarts and
  reconciles stale state left by prior Strategy Tester runs. Compiles with
  **0 errors, 0 warnings**. Deployed to the isolated MT5 instance's
  `MQL5\Experts\` folder.

**Verified via a live Strategy Tester smoke run (EURUSD H1, 2024.01.02–01.15,
Model=2):**
- [x] EA compiles and runs in Strategy Tester without crashing (216 H1 bars
      processed, clean init/deinit, `automatical testing` reported
      "successfully finished").
- [x] All six confluence checks independently evaluated and logged on every
      closed H1 bar (confirmed via the local fallback log's `features` JSON:
      `check1`–`check6` all present per row, not collapsed into one boolean).
- [x] `taken=false` rows correctly carry a `rejection_reason` matching the
      first failing gate in the documented priority order.

**Platform-behavior findings (Strategy Tester specifically differs from
live/demo — confirmed empirically, not assumed):**
- **`WebRequest` fails in Strategy Tester** with error 4014
  ("function not allowed") on every call, even though `http://127.0.0.1:8000`
  is allow-listed in Tools → Options → Expert Advisors and works fine live
  (confirmed in Phase 0). The allow-list evidently does not extend to the
  Tester's separate agent process. Consequence: **the bridge is unreachable
  during backtests**, and — as designed — the EA's local-file fallback
  (`MQL5\Files\Phase1EA\bridge_fallback.log`, plain `FileOpen`, not
  `FILE_COMMON`) caught every signal/trade log with fully well-formed JSON.
  This matches the acceptance criteria's own anticipated contingency ("or
  local log if bridge down during the test run") — **the local log is the
  authoritative signal/trade record for backtests; Postgres/the bridge is the
  record for live/demo.** No code changes needed; this is documented, expected
  behavior, not a bug. A later phase could bulk-import the local log into
  Postgres for backtest-time ML feature analysis if that becomes valuable.
- **Calendar API (`CalendarValueHistory`) returns `-1` (an error, not just
  zero results) in the Strategy Tester context**, despite terminal build
  5.0.0.5975 being modern enough that calendar-in-tester support was expected.
  The `NewsFilter` smoke test added at `OnInit` caught this directly: `"-1 USD
  calendar events found"`. Because `IsAllowed()` treats a non-positive count as
  "no event nearby" (fails open), this doesn't cause incorrect rejections —
  it just means **`InpUseNewsFilter=true` is a silent no-op during backtests**,
  which happens to match the doc's Section 0.3 fallback recommendation
  ("disabled during backtests") even though we didn't build it as an explicit
  live-only stub. No code changes made; worth re-testing on a live/demo chart
  before trusting the filter operationally.
- **Historical data depth**: the isolated MT5 instance's local `.hcc` cache
  only covered 2023–2024, but Strategy Tester successfully downloaded further
  back on demand. A deep probe requesting data from 2010 confirmed the
  broker's true earliest available EURUSD data is **2008-12-18**, with a
  clean synchronized H1/H4/D1 series usable from **2009-01-02** onward — about
  17 years, comfortably covering multiple trending/ranging/high-volatility
  regimes and far exceeding the doc's 3-5+ year recommendation. Nothing
  further needed here; walk-forward windows can be planned against the full
  2009–present range.

**Walk-forward validation attempt and trade-frequency diagnostic (started,
then paused for a code-fix loop):**

Kicked off a walk-forward sequence (12mo optimize / 3mo forward-test windows,
`ForwardMode=4`/`ForwardDate` splitting one Strategy Tester run into in-sample
vs. out-of-sample segments — confirmed this MT5 feature works as intended,
matching the cache filename to the exact optimize/test boundary). Window 1
(2009 optimize → Q1 2010 forward) and window 2 (2010-04 optimize → Q1 2011
forward) both completed with a 9-combination grid (`InpATRMultiplier` ×
`InpRSIThreshold`).

**Both windows showed the same problem: at most 4-7 trades in a full 12-month
period, and most parameter combinations produced zero trades.** Any profit
factor/win rate computed from that few trades would be statistically
meaningless, so the sequence was paused (windows 3-8 stopped; window 3 was
mid-run and its partial output discarded) to diagnose the cause before
spending more compute on a configuration that couldn't produce a usable
verdict. (Side note on the same run: local optimization without MQL5 Cloud is
slow — a 9-combo/15-month window took ~50 min once actually measured, after an
initial false alarm reading an in-progress per-pass log percentage as a stall.)

**Diagnosed via the local fallback log's `rejection_reason` distribution
(WebRequest doesn't reach Postgres during backtests, but the fallback log
captures every signal — see the platform findings above), iterating one gate
at a time. Found and fixed three real logic issues:**

1. **`CTrend::Classify()` (`Trend.mqh`) required the D1 EMA50/200 direction
   AND a D1 swing-structure check (2 confirmed higher-highs/higher-lows, or
   the inverse) to independently agree before returning anything but
   `SIDEWAYS`.** This compounded AND-gate classified 60-67% of all H1 bars as
   sideways. Fixed by switching to the conventional two-threshold ADX usage:
   below a low "sideways floor" (`InpAdxSidewaysThreshold`, default 18) =
   genuinely ranging regardless of EMA noise; above it, direction comes from
   EMA, STRONG vs. WEAK from the existing higher `InpAdxTrendThreshold`.
   Structure/swing detection is unaffected elsewhere (S/R zones, structure
   trailing) — only its use as a *Trend*-classification gate was removed.
   Result: `d1_trend_not_directional` dropped from ~67% to ~33% of rejections,
   but total trades stayed at 0 — bottleneck moved to `h4_setup_invalid`.
2. **`H4SetupValid()` (`EntryLogic.mqh`) required the H4 EMA20/50 cross to
   agree with the trade direction.** This is close to a logical contradiction
   with the doc's own pullback-entry design: a genuine pullback is exactly
   when the faster H4 average dips against the trend, so requiring it to
   still agree was systematically excluding the setups this check exists to
   confirm. Fixed by checking H4 close price against the slower EMA50 only
   (confirms the broader H4 trend is intact; tolerates the faster average
   dipping through it during a pullback). Result: roughly flat — the
   dominant bottleneck stayed `h4_setup_invalid` at a similar rate, but this
   is arguably a more correct implementation of the doc's intent regardless.
3. **`RSIConfirms()` (`Momentum.mqh`) compared current RSI only to the single
   immediately-prior bar** (`curr > prev` for a long) — close to a coinflip
   given ordinary bar-to-bar RSI noise, and empirically the tightest of all
   six checks by far (~2% conditional pass rate among bars that had already
   cleared trend/H4/structure). Fixed by checking recovery against the
   low/high over a short rolling window (default 5 bars) instead of one bar.
   Result: momentum's conditional pass rate roughly doubled.

**With all three fixes plus `InpRequireVolumeIncrease=false` (the tick-volume
gate, which turned out to be blocking the few remaining near-miss bars),
the same 12-month window (2010-04 to 2011-04) went from 0 trades to
1 trade — a real, profitable trade ($114.74 net, no losers), confirming
partial-close/logging mechanics work correctly end-to-end. But 1 trade/year
is still far too sparse for any walk-forward statistic to mean anything.**

`d1_trend_not_directional` (2056/6238 = 33%) and `h4_setup_invalid`
(2687/6238 = 43%) remain the two largest absolute blockers even after both
were already loosened once — together they eliminate ~76% of all bars before
the other four checks are ever reached. Whether further loosening these two,
accepting genuinely low trade frequency as characteristic of this confluence
spec, or a bigger design change (e.g., not requiring all six checks to align
on the exact same bar) is the right path is an open decision, not yet made.

**Not yet done (Stage 5 of the build plan — the actual point of this phase):**
walk-forward validation across ≥3 sequential out-of-sample windows, a
no-confluence-filter benchmark comparison, and the documented go/no-go
decision this phase's acceptance criteria require, is still blocked on
reaching a trade frequency that can produce a statistically meaningful
verdict. Windows 1-2's results (computed against the pre-fix EA) are stale
and would need to be re-run once trade frequency is resolved.

## 2026-07-09 — Phase 1 addendum, Step 1: d1_trend/h4_setup overlap diagnosis

Built the full 2×2 contingency table from per-bar `check1_d1_trend` /
`check2_h4_confluence` booleans (both always logged independently in
`features_json`, regardless of which was the first-failing gate) across the
same 12-month window (2010-04 to 2011-04, 6238 H1 bars):

|                | check2 pass | check2 fail | Total |
|----------------|------------:|------------:|------:|
| **check1 pass**|       1,495 |       2,687 | 4,182 |
| **check1 fail**|         690 |       1,366 | 2,056 |
| **Total**      |       2,185 |       4,053 | 6,238 |

Unconditional pass rates: `d1_trend` alone = 4182/6238 = **67.1%**;
`h4_setup` alone = 2185/6238 = **35.0%**.

Overlap: of bars failing `d1_trend`, 66.4% also fail `h4_setup`. Of bars
failing `h4_setup`, only 33.7% also fail `d1_trend` — the majority (66.3%) of
h4 failures occur on bars where `d1_trend` independently passed.

Independence check: P(both pass) under independence = 67.1% × 35.0% =
23.49%; actual observed = 1495/6238 = 23.97% — a 0.48pp gap, essentially
indistinguishable from statistical independence.

**Conclusion: the two gates are not redundant — they compound as if close to
statistically independent.** No shared root cause found in the overlap;
each gate does its own moderately-selective filtering (67% and 35%), and
their product (~24%) is exactly what plain independence predicts. This
doesn't identify a bug (no logical contradiction found, per the bug-vs-
strictness criterion) — whether 67%/35% individually represent reasonable
selectivity is a separate, open question from overlap, addressed in Step 2
(bar-alignment hypothesis) rather than by further overlap analysis.

**Decision (2026-07-09): stop here for this session rather than keep
loosening `d1_trend`/`h4_setup`.** Three real logic bugs were found and fixed
tonight (see above) — genuine progress, not busywork. Continuing to loosen
the two remaining dominant gates specifically to hit a target trade count
risks curve-fitting the confluence logic to "make it trade" rather than
"make it trade well," which would undermine the whole point of Stage 5
rather than serve it. Trade frequency (still ~1/year even after three fixes)
is an open problem to revisit with fresh eyes, not a solved one — options on
the table for next time: further loosen `d1_trend`/`h4_setup` (with the same
"is this a real bug or a deliberate strictness" scrutiny applied to the first
three), accept low frequency as characteristic of this confluence spec and
size the walk-forward windows accordingly (e.g. multi-year windows instead of
12-month, to accumulate enough trades per window), or reconsider the
requirement that all six checks align on the exact same H1 bar close.
Walk-forward validation, the benchmark comparison, and the go/no-go decision
remain not started.

## 2026-07-09 — Phase 1 addendum, Step 2: bar-alignment hypothesis test

**Category: TIMING change, isolated from strictness.** Added `ENUM_CONFLUENCE_MODE`
(`CONFLUENCE_STRICT_SAME_BAR` / `CONFLUENCE_ROLLING_WINDOW`, input
`InpConfluenceMode`, default `STRICT_SAME_BAR` so existing behavior is
unchanged unless explicitly toggled) to `EntryLogic.mqh`. In `ROLLING_WINDOW`
mode, checks 4-6 (momentum, candlestick trigger, volume) each independently
scan a trailing window (`InpRollingWindowBars`, default 3) instead of
requiring all three on the exact same H1 bar. Checks 1-3 (D1 trend, H4 setup,
structure/zone) are evaluated at the current bar in both modes, unchanged. No
threshold values were touched.

**Test:** re-ran the identical 12-month window used in the diagnostic
(2010-04-02 to 2011-04-02, EURUSD H1, `InpRequireVolumeIncrease=false` —
same settings as the 1-trade `STRICT_SAME_BAR` baseline), changing only
`InpConfluenceMode=ROLLING_WINDOW` and `InpRollingWindowBars=3`
(`_mt5-instance/diag_step2.ini`, report `Phase1_diag_step2`).

**Result: 3 completed trades** (up from 1 in the `STRICT_SAME_BAR` baseline on
the same window), plus a 4th position still open when the test window ended
(report's "Total Trades: 4" / "Total Deals: 7" includes this open position;
Net Profit -$85.12 reconciles exactly against the 3 *closed* trades logged to
the bridge fallback log: -$97.90 (`sl_hit`), -$95.51 (`sl_hit`), +$108.29
(`trailing_stop`) — Profit Factor 0.56, 2 losers/1 winner). The
`STRICT_SAME_BAR` baseline on this same window was a single profitable trade
(+$114.74, no losers) — small-sample performance comparison isn't meaningful
either way, but frequency roughly tripled.

**Rejection-reason breakdown over the same 6,238 H1 bars, `ROLLING_WINDOW`
mode:**

| Reason                     | Count | % of bars |
|----------------------------|------:|----------:|
| `h4_setup_invalid`         | 2,687 |     43.1% |
| `d1_trend_not_directional` | 2,056 |     33.0% |
| `momentum_not_confirmed`   |   788 |     12.6% |
| `not_at_key_level`         |   640 |     10.3% |
| `no_candlestick_trigger`   |    56 |      0.9% |
| `outside_session`          |     6 |      0.1% |
| `max_open_trades`          |     2 |     0.03% |
| taken                      |     3 |     0.05% |

`d1_trend_not_directional` (33.0%) and `h4_setup_invalid` (43.1%) are
**exactly unchanged** from Step 1's diagnosis on this same window (2,056/6,238
and 2,687/6,238 respectively) — confirming the rolling-window change was
cleanly isolated to checks 4-6 only, with zero effect on the two upstream
gates, as intended.

**Conclusion: the bar-alignment hypothesis is partially confirmed but is not
the dominant bottleneck.** Allowing the trigger checks to fire within a 3-bar
window instead of requiring exact same-bar alignment did increase trade count
(~3x on this window), so same-bar alignment was contributing some
unnecessary strictness. But it's a secondary effect — `d1_trend`/`h4_setup`
together still eliminate ~76% of all bars, completely untouched by this
change, and remain the primary constraint on trade frequency per Step 1's
diagnosis. Loosening trigger-check timing alone cannot get EURUSD to a
statistically usable single-instrument trade count; per the addendum, further
loosening `d1_trend`/`h4_setup` is a separate, not-yet-made decision (still
requires the same bug-vs-strictness scrutiny), and Step 3 (multi-instrument
pooling) is the next lever to pull without touching confluence logic further.

Stopping here per the addendum's reporting discipline — Step 3 not started.

## 2026-07-10 — Phase 1 addendum, Step 3: multi-instrument pooling

**Infrastructure fix found and applied mid-step (not a confluence-logic
change):** `BridgeLogger::WriteLocalLog()` was doing `FileOpen` /
`FileSeek(SEEK_END)` / `FileClose` on **every single** fallback-log write. Fine
at small file sizes, but a full-history single-pass run pushes the fallback
log (WebRequest still fails with error 4014 in the Tester, per the Phase 1
platform-behavior findings) past 100MB, and the first attempt at a
full-history GBPUSD run was on pace for 5+ more hours (~11x slower than linear
scaling from the Step 2 timing would predict) before being killed. Fixed by
opening the file once (`Init`) and closing it once (`Deinit`), seeking to end
per write instead of reopening. Recompiled clean (0 errors, 0 warnings, via
MetaEditor64 `/compile`), redeployed. After the fix, all three full-history
runs below completed in a few minutes total.

**History depth (confirmed via the Tester's own history-sync log lines, not
assumed):** GBPUSD, USDJPY, and AUDUSD all synchronized **1999.01.04 to
2026.07.09** on this broker/demo account — deeper than EURUSD's previously
confirmed 2008-12-18 start. Tested range: 2000.01.01–2026.07.09 (~26.5 years)
for all three, identical `ROLLING_WINDOW` settings as Step 2
(`InpRollingWindowBars=3`, `InpRequireVolumeIncrease=false`), **no
per-instrument threshold changes.**

**Trade frequency.** The Tester report's own "Total Trades" figure
double-counts partial TP1/TP2 closes as separate trades (confirmed via the
Total Deals : Total Trades ratio — GBPUSD 22:11 = exactly 2.0, i.e. no
partial ever reached, consistent with 100% of its trades being straight
SL-hit losers; USDJPY 191:115 ≈ 1.66; AUDUSD 213:134 ≈ 1.59). The number of
**distinct trade entries** (`"taken":true` count in the fallback log) is the
figure that actually answers "how often did the EA trade":

| Instrument | Entries | ~Entries/yr | Net P/L    | Profit Factor |
|------------|--------:|------------:|-----------:|--------------:|
| GBPUSD     |      11 |        0.42 | -$1,070.29 | 0.00 (all losers) |
| USDJPY     |      76 |        2.87 |   -$751.45 | 0.83 |
| AUDUSD     |      79 |        2.98 | +$1,002.49 | 1.21 |
| EURUSD*    |       3 |         ~3  |    -$85.12 | 0.56 |

\* EURUSD figure is Step 2's single 12-month sample window, not a full-history
run — directionally comparable only, not a controlled apples-to-apples count.

**Finding: EURUSD's low frequency is not an EURUSD-specific problem.** USDJPY
and AUDUSD trade at a rate roughly comparable to EURUSD's Step 2 sample rate
(~3/year) under byte-for-byte identical rules — this confluence logic is
inherently low-frequency across most majors, not uniquely broken for EURUSD.
**GBPUSD is a clear outlier**, trading at roughly 1/7th the rate of the other
three under the exact same rules. Per the addendum's explicit instruction,
this was **not** treated as a bug to fix or tune away — it's reported as a
finding. (Worth a future look at *why* — e.g. GBPUSD's historically higher
volatility interacting with ATR/ADX thresholds implicitly shaped around
EURUSD's character — but that investigation is out of scope for this step.)

**Rejection-reason breakdown** (USDJPY/AUDUSD only — see data-quality note
below):

| Reason                     |      USDJPY |      AUDUSD |
|-----------------------------|------------:|------------:|
| `h4_setup_invalid`          | 60,824 (37.0%) | 60,392 (36.7%) |
| `d1_trend_not_directional`  | 59,762 (36.3%) | 63,317 (38.5%) |
| `momentum_not_confirmed`    | 25,220 (15.3%) | 23,103 (14.0%) |
| `not_at_key_level`          | 17,304 (10.5%) | 16,351 (9.9%)  |
| `no_candlestick_trigger`    |  1,049 (0.6%)  |    993 (0.6%)  |
| `max_open_trades`           |          60 |          74 |
| `outside_session`           |         148 |         193 |
| `spread_too_wide`           |          59 |          47 |
| taken                       |          76 |          79 |

`d1_trend_not_directional` and `h4_setup_invalid` remain the two dominant
gates (combined ~73-75%) at magnitudes consistent with EURUSD's Step 1/2
findings — reinforcing that these two gates are a **structural, cross-
instrument bottleneck**, not an EURUSD-specific quirk.

**Data-quality note:** GBPUSD's local fallback log (the authoritative
per-bar record during backtests, since WebRequest fails in the Tester) was
lost to a Tester agent-pool quirk — each separate `/config` launch got routed
to whichever local Tester agent slot (3000, 3001, ...) happened to be free,
not always the same one, and the archiving script's hardcoded path only
captured whichever instrument landed on agent-3000 that run (AUDUSD).
USDJPY's log was recovered directly from its actual agent folder after the
fact; GBPUSD's per-bar log is gone. This doesn't affect the trade-count/P&L
figures above (independent, from the `.htm` report), only the rejection-
reason breakdown, which is unavailable for GBPUSD specifically.

**Decision (2026-07-10, user):** pool GBPUSD into Step 4's walk-forward
sample as-is (no down-weighting, no exclusion) — just flag its outlier-low
frequency and all-losers record plainly wherever aggregate/per-instrument
walk-forward results are reported, so it isn't silently smoothed over by the
pooled statistics.

Stopping here per the addendum's reporting discipline — Step 4 not started.

## 2026-07-10 — Phase 1 addendum, Step 4: walk-forward, benchmark, go/no-go

**Design, declared before running (not adjusted after seeing results):**
- **No per-window parameter optimization.** Trade frequency is still too low
  for a meaningful in-window grid search (the original problem this whole
  addendum exists to diagnose), and re-tuning would reopen the exact
  curve-fitting risk the addendum's guardrail exists to prevent. Every window
  below uses the same fixed configuration throughout (Step 1's bug fixes +
  Step 2's `ROLLING_WINDOW` timing change + Step 3's settings, unchanged) — so
  every window is a genuine out-of-sample test relative to any data-driven
  fitting.
- **5 sequential windows**, 2000-01-01 to 2026-07-09 (~5.3 years each):
  w1 2000-01-01→2005-06-01, w2 2005-06-01→2010-12-01, w3 2010-12-01→2016-06-01,
  w4 2016-06-01→2021-12-01, w5 2021-12-01→2026-07-09.
- **4 instruments** (EURUSD, GBPUSD, USDJPY, AUDUSD) × **2 configurations**
  per window: confluence-gated, and a new `InpBypassConfluence` benchmark
  (added to `Phase1EA.mq5`/`EntryLogic.mqh` — checks 1-6 still evaluated and
  logged exactly as normal for comparability, but the confluence gate itself
  is skipped; session/spread/news/risk gates and all exit management are
  identical). Recompiled clean (0 errors, 0 warnings). 40 runs total.
- **Sample-size bar, declared in advance:** a window/instrument cell needs
  ≥15 pooled trades to be individually meaningful; the full aggregate needs
  ≥100 pooled confluence-gated trades before the go/no-go is treated as more
  than "directionally suggestive."
- GBPUSD pooled in as-is per the user's decision, flagged wherever it
  materially affects a result (see Step 3's outlier-low-frequency finding).

**Infrastructure note:** the Step 3 data-loss quirk (Tester agent-pool
assignment is nondeterministic; the archiving script must not assume a fixed
agent port) was fixed in `step4_run_sequence.ps1` by searching all
`Agent-*` folders for a fallback log touched since the run's own start time.
All 40 runs captured a report and a fallback log cleanly this time.

**Data-quality finding (directly the check Section 9.1 of the original build
doc calls for — "confirm it's using real historical spread, not a fixed
one"): windows 1 and 2 have synthetic, not real, historical spread data.**
Checked `spread_at_signal` across the benchmark runs (which trade on nearly
every eligible bar, so they're the clearest signal of what spread the Tester
is actually feeding the EA):

| Window | Span | EURUSD spread | GBPUSD spread | USDJPY spread | AUDUSD spread |
|--------|------|---------------|---------------|---------------|---------------|
| w1 | 2000-2005.5 | flat 50 (1 value) | flat 50 (1 value) | flat 50 (1 value) | flat 50 (1 value) |
| w2 | 2005.5-2010.12 | 20-30 (2 values) | 20-40 (3 values) | flat 30 (1 value) | 30-40 (2 values) |
| w3 | 2010.12-2016.6 | 1-360 (65 values) | 1-1725 (104 values) | 1-154 (76 values) | 1-280 (87 values) |

Windows 1-2 are a flat/near-flat synthetic spread substituted by the Tester
before real historical spread data exists for these symbols on this
broker/demo feed — not representative market conditions (this is *why*
AUDUSD/GBPUSD showed zero trades in w1 even in the no-filter benchmark: their
synthetic floor of 40-50 points sits above `InpMaxSpreadPoints=30` and blocks
every single bar; EURUSD/USDJPY's synthetic floor happens to sit exactly at
the 30-point boundary, letting a trickle through — an artifact of the
synthetic substitution, not a real edge). **Windows 1 and 2 are excluded from
the primary aggregate below on this objective, pre-checked data-quality
ground — decided from spread realism, before looking at any P&L result.**
This still leaves exactly 3 sequential windows (w3, w4, w5, 2010.12-2026.07,
~15.7 years), meeting the acceptance criteria's stated minimum.

**Per-window pooled results (all 4 instruments, w3-w5 only):**

| Window | Mode | Entries | Win% | Net Profit | PF | Avg R |
|--------|------|--------:|-----:|-----------:|---:|------:|
| w3 | gated | 127 | 48.8% | +$2,840.50 | 1.421 | +0.297 |
| w3 | bench | 271 | 41.0% | -$1,380.84 | 0.916 | -0.056 |
| w4 | gated |  93 | 33.3% | -$2,785.80 | 0.540 | -0.338 |
| w4 | bench | 362 | 43.6% | +$1,059.32 | 1.047 | +0.004 |
| w5 | gated |  78 | 35.9% | -$1,679.17 | 0.658 | -0.249 |
| w5 | bench | 202 | 39.6% | -$2,551.36 | 0.788 | -0.129 |

**Aggregate, w3-w5 pooled (all 4 instruments, GBPUSD included as-is):**

|                  | Confluence-gated | No-filter benchmark |
|------------------|-----------------:|---------------------:|
| Entries          |              298 |                   835 |
| Win rate         |            40.6% |                 41.8% |
| Net profit       |       -$1,624.47 |            -$2,872.88 |
| Profit Factor    |            0.908 |                 0.944 |
| Avg R-multiple   |           -0.044 |                -0.048 |

**Go/no-go, grounded in the numbers above per Section 9.4 (not a subjective
equity-curve read):**

1. **Consistency check fails.** The gated config is profitable in w3
   (+0.297 avg R) but loses money in both w4 (-0.338) and w5 (-0.249) — one
   good window out of three, not the "consistent (not just
   aggregate-positive) expectancy" the doc's own go/no-go criterion requires.
2. **Aggregate is negative, not just thin.** 298 pooled gated trades clears
   the declared ≥100 sample-size bar, so this is a real reading, not noise
   from too few trades: PF 0.908, avg R -0.044, net -$1,624 over 15.7 years
   across 4 instruments.
3. **Confluence filtering does not demonstrate added expectancy over the
   naive benchmark** — the stated purpose of the benchmark comparison. PF
   (0.908 vs 0.944), win rate (40.6% vs 41.8%), and avg R (-0.044 vs -0.048)
   are all close, with the *unfiltered* benchmark marginally ahead on every
   metric. The six-check confluence gate mainly reduces trade count (298 vs
   835) without buying better expectancy in return.

**Decision: NO-GO.** Per Section 9.4 ("only if walk-forward windows show
consistent... expectancy after realistic costs should this move to demo-
account forward testing"), this does not clear that bar. Do not proceed to
demo-account forward testing or Phase 2/3 planning on the current confluence
logic as-is. This is a result to report plainly, not a prompt to start
loosening gates again in this session — any redesign (different checks,
different instruments, different regime filtering, abandoning the six-check
confluence structure in favor of something else) is a new design decision for
the user to make, not an automatic next step.

**Caveats on this verdict:**
- Max drawdown is reported per-run (in each `.htm` report) but was not
  blended into a single combined equity curve across instruments/windows —
  doing so properly requires interleaving trades by timestamp across all 4
  instruments' own equity curves, which wasn't done here. The PF/avg-R/net-
  profit comparison above is sound; a blended max-DD figure is not included
  and shouldn't be assumed.
- GBPUSD (Step 3's outlier-low-frequency, all-losers instrument) is pooled
  into every number above per the user's instruction; it pulls the aggregate
  down somewhat but is not the sole reason for the negative result — USDJPY
  and EURUSD's own gated avg-R are negative in 2 of 3 windows each too.
- Windows 1-2 are excluded for a specific, checkable data-quality reason
  (synthetic spread), not because their results were unfavorable — worth an
  independent sanity check by the user if this verdict is surprising.

## 2026-07-10 — Phase 1 addendum 2: exit structure diagnosis

**Context:** addendum 1's benchmark comparison showed the no-filter version
*also* losing money (PF 0.944, w3-w5 pooled) — meaning entries alone can't be
the whole story. This addendum measures whether the exit structure (ATR-based
SL, 1R/2R partials, ATR trailing) is itself giving back edge, using data
already on disk. **Measurement only — no SL/TP/trailing parameter was
touched in this step**, per the addendum's explicit instruction, regardless
of what the numbers showed.

### Step 0 — data verification

`RiskManager::UpdateMFE`/`UpdateMAE` are real, wired-up tracking (called every
`OnTick` from `ExitManager::ManageOne`, monotonic max-only, persisted via
`P1_MFE_*`/`P1_MAE_*` GlobalVariables, written on close) — **not** null or
placeholder. Spot-checked `w3_EURUSD_gated`: values are varied and
trade-specific (a winner shows `mfe=0.01082`; several `sl_hit` losers show
`mfe=0` exactly, meaning those specific trades never once traded favorably —
itself a real data point, not a bug).

Two things to account for before using this data:
1. **Stored in raw price units, not R-multiples.** Converted per-trade using
   `r_distance = |open_price - initial_sl|` (both already logged at trade-open)
   — `mfe_R = mfe / r_distance`, same for `mae_R`.
2. **All addendum-1 backtests used `Model=2` (open-prices-only).** MFE/MAE are
   therefore sampled only at H1 bar-opens, not true intrabar ticks. This is a
   **lower-bound approximation** of true intrabar excursion, not tick-exact —
   flagged wherever it plausibly affects a specific finding below.

WebRequest still fails in the Tester (unchanged from every prior finding), so
none of this reached Postgres — reused the 12 already-archived fallback logs
from addendum 1 Step 4 (w3/w4/w5 × 4 instruments, gated mode only, the same
298-trade pooled dataset). No re-run needed.

### Step 1 — core distributions (298 trades, w3-w5 pooled, gated)

| Metric | N | Min | P25 | P50 | P75 | Max | Mean |
|---|---:|---:|---:|---:|---:|---:|---:|
| MFE_R, pooled | 298 | 0 | 0.046 | 0.718 | 1.346 | 7.793 | 1.013 |
| MAE_R, pooled | 298 | 0 | 0.055 | 0.396 | 0.645 | 0.957 | 0.386 |

Per instrument (MFE_R median / MAE_R median): EURUSD 0.409 / 0.287 (n=70),
GBPUSD 0.767 / 0.368 (n=83), USDJPY 0.571 / 0.417 (n=65), AUDUSD 0.810 / 0.465
(n=80). No instrument stands out as qualitatively different in shape;
GBPUSD's MFE_R distribution is not obviously worse than the others despite
its all-losers record from Step 3 of addendum 1.

**Reached vs. captured — no execution gap:**

| | n | Reached ≥1R | Captured TP1 | Reached ≥2R | Captured TP2 |
|---|---:|---:|---:|---:|---:|
| Pooled | 298 | 121 (40.6%) | 121 (40.6%) | 42 (14.1%) | 41 (13.8%) |
| EURUSD | 70 | 26 (37.1%) | 26 (37.1%) | 9 (12.9%) | 9 (12.9%) |
| GBPUSD | 83 | 36 (43.4%) | 36 (43.4%) | 8 (9.6%) | 8 (9.6%) |
| USDJPY | 65 | 22 (33.8%) | 22 (33.8%) | 7 (10.8%) | 7 (10.8%) |
| AUDUSD | 80 | 37 (46.2%) | 37 (46.2%) | 18 (22.5%) | 17 (21.2%) |

Reached and captured match **exactly** everywhere except one AUDUSD trade
(ticket 26: MFE_R 3.19, TP2 never fired, likely the documented lot-rounding
skip in `TryPartialClose` — original lot too small for 30% of it to clear
the broker's minimum tradable volume after TP1 already reduced the position).
**Finding: TP1/TP2 execution is not losing anything worth mentioning** — when
a trade reaches a level, the partial-close mechanism captures it, essentially
every time.

### Step 2 — loser diagnosis (`sl_hit` exits, 177 of 298 trades)

1. **Trades with MFE_R ≥ 1.0 before reversing into the stop: 0 of 177 (0%).**
   Every single `sl_hit` loss never once reached 1R unrealized. This is the
   central number for this step, and it's about as clean as this kind of
   read ever gets.
2. MAE_R among `sl_hit` trades: median 0.549, P75 0.715, max **0.957** — never
   reaches 1.0. This looks alarming out of context but is explained fully by
   the Model=2 sampling caveat: the stop executes on the broker's continuous
   price check, not on the EA's bar-open-only MAE sample, so the last sampled
   point before an intrabar stop-out is mechanically always < 1.0R. Not
   evidence of slippage or a bad stop distance — a backtest-resolution
   artifact, expected and consistent across all 177 trades.
3. Time in trade: `sl_hit` losers median **7h** (P25 3h, P75 18h, mean 14.6h)
   vs. winners median **23h** (P25 13h, P75 43h, mean 34.3h). Losers get cut
   roughly 3x faster than winners are allowed to run — the intended
   cut-losses-fast/let-winners-ride asymmetry **is** showing up in the data.
   This is a point in the exit structure's favor, not against it.

**Explicit read: the data points toward "wrong from the start," not "stopped
too tight."** If the SL distance were the problem, some real fraction of
losers should show a meaningful favorable excursion before reversing — 0 of
177 is a strong, not ambiguous, signal against that. Exit reasons in this
dataset are cleanly binary (177 `sl_hit` = all 177 losers, 121
`trailing_stop` = all 121 winners, no `breakeven`/`tp2`/`manual_close` exits
occurred at all) — win/loss and exit-reason are perfectly correlated here,
which is itself informative: there's no meaningful third bucket of
"stopped near breakeven after going favorable" trades that a tighter/looser
SL would plausibly have flipped into a winner.

### Step 3 — winner / trailing-stop giveback (42 trades reaching ≥2R)

**Giveback (MFE_R − final realized R on the runner portion):** min 0.502,
P25 0.649, **median 0.801**, P75 0.912, max 1.296, mean 0.822. This *is* a
real, sizeable, consistent cost — every single one of the 42 trades that got
to 2R+ gave back at least half an R by the time the runner (the untouched
40% after both partials) finally closed. Distribution is tight (0.50-1.30),
not dominated by a few outliers.

**TP1/TP2 partials fire later than their nominal level, not exactly on it:**
TP1 fires at a median of 1.19R (P75 1.36, max 3.78 — overshoot median +0.19R);
TP2 fires at a median of 2.30R (overshoot median +0.30R). This overshoot is a
**positive** for expectancy (more captured than the nominal target, not
less) and is best explained by the same Model=2 bar-open-sampling coarseness
as Step 2's MAE finding — live tick-by-tick execution would likely track the
nominal level far more tightly. Price continues running after each partial
fires by a further median of 0.27R (after TP1) and 0.66R (after TP2) before
the eventual peak — the runner does keep finding more room, which is exactly
what the trailing giveback above then surrenders a large fraction of.

### Step 4 — plain-language summary

**Primarily the entries, with a real secondary cost from the trailing
mechanism.** The evidence is not an ambiguous "some of both, can't tell":

- The loser side is unusually clean: 0 of 177 stop-outs ever traded
  favorably first. That's much stronger evidence for "these entries were
  wrong from the start" than for "the stop is too tight" — a too-tight stop
  would show up as some real fraction of losers having gone favorable before
  reversing, and essentially none did.
- TP1/TP2 execution itself is not losing anything — reached and captured
  match almost exactly, with a mild positive-overshoot bias, not a negative
  one.
- The trailing stop on winning runners (≥2R trades) **is** giving back a
  real, consistent amount — a median 0.80R out of whatever peak the trade
  reached, on every single one of the 42 trades in that bucket. This is a
  genuine, separate finding from the entry-quality question, and a plausible
  contributor to the flat/negative expectancy alongside (not instead of) weak
  entries.
- Cut-losses-fast/let-winners-ride timing asymmetry (7h vs 23h median) is
  present and working as the exit spec intends — not a source of the
  problem.

**No SL/TP/trailing parameter was changed in this pass.** If a next step is
wanted, the giveback finding is the one piece of this diagnosis that points
at a specific, testable lever (the ATR trailing multiplier/mode) rather than
at the entry logic — but per the guardrail, that would be a new, separate,
isolated test, not a bundled change alongside anything else.

## 2026-07-10 — Phase 1 addendum 3: trailing-stop giveback test

**Context:** addendum 2 found the trailing stop gives back a real, consistent
median 0.80R on trades reaching ≥2R. This addendum tests **only** that one
lever, in isolation, against the exact same w3-w5 / 4-instrument / gated
dataset — expected to be "somewhat better, still likely not profitable,"
not a rescue of the strategy.

**Step 1 — no code change needed.** `InpAtrTrailMultiplier` (default 1.5,
driving `ExitManager::TryTrail`'s ATR branch) is already a generic input
parameter — the exact "A/B via input parameter, not a replacement" the task
called for already exists. Tested the single recommended alternative,
**3.0x** (double the current), by re-running the unchanged compiled EA with
only that one `TesterInputs` value changed. Zero lines of code touched.

**Step 2 — re-ran the same 12 window/instrument combinations** (w3-w5 ×
EURUSD/GBPUSD/USDJPY/AUDUSD, gated mode, `ROLLING_WINDOW`/settings
unchanged), only `InpAtrTrailMultiplier=3.0` different.

**Side effect noticed before interpreting anything else:** trade count
shifted from 298 to 297 (w4 GBPUSD 28→25, w4 USDJPY 15→17). This is a real,
explainable mechanism, not noise: a wider trail keeps winning positions open
longer before they're finally stopped out, and under `InpMaxOpenTrades=1`
that can block a subsequent entry signal that would otherwise have been
taken. Entry logic itself is byte-for-byte unchanged. 295 of 298 original
trades were matched to their identical entry (same window/symbol/open-time)
in the new run for a proper paired comparison below.

### Step 3 — results, directly comparable to addendum 2

**Cross-sectional giveback distribution (trades reaching ≥2R MFE) — got
*worse*, not better:**

| | n | Min | P25 | P50 | P75 | Max | Mean |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1.5x (addendum 2) | 42 | 0.502 | 0.649 | 0.801 | 0.912 | 1.296 | 0.822 |
| 3.0x (this test) | 62 | 0.622 | 1.206 | 1.400 | 1.696 | 2.721 | 1.491 |

**Pooled aggregate, w3-w5:**

| | n | Win% | Net Profit | PF | Avg R |
|---|---:|---:|---:|---:|---:|
| 1.5x (addendum 1/2 baseline) | 298 | 40.6% | -$1,624.47 | 0.908 | -0.044 |
| 3.0x (this test) | 297 | 40.7% | -$1,147.39 | 0.935 | -0.022 |

**Paired, trade-level comparison (295 matched pairs, same entry in both
runs) — this is the number that resolves the apparent contradiction above:**

- 175 of 295 pairs: zero delta (never reached TP1, trailing multiplier never
  engaged — these are the sl_hit losers, completely untouched by this change,
  exactly as expected).
- Of the ~120 trades where trailing *did* engage: **32 improved, 88 got
  worse.** Median delta across all 295 pairs: 0. Mean: +0.023 (pulled
  positive by a few large outliers, not representative of the typical case).
- **Restricted to the 42 original ≥2R trades specifically — the population
  the giveback finding was about — the median individual outcome *worsened*
  by 0.591R** (11 improved, 31 worsened, of 42). The cross-sectional
  giveback numbers above got worse for real reasons at the trade level, not
  just because more trades qualified for the bucket.
- The pooled net-profit/PF improvement is a **tail effect, not a median
  effect**: a handful of exceptional trades rode much further under the
  wider trail (e.g. one USDJPY trade went from R=2.98 to R=9.88 — alone
  worth roughly $690 of the ~$477 net pooled improvement once other
  regressions are netted against it). The typical trade in the affected
  population did worse under the wider trail; a small number of outliers
  did dramatically better and carried the aggregate.

### Step 4 — plain verdict

- **The 0.80R median giveback was not recovered — it got worse (to 1.40R
  cross-sectionally; -0.591R median at the matched trade level).** This is
  the opposite of the tested hypothesis. A wider trail did not "give the
  trade room to breathe without surrendering as much" for the typical case;
  it mostly let more of the eventual reversal happen before the stop caught
  it.
- **Net effect on the pooled aggregate: small net-positive** (net profit
  -$1,624 → -$1,147, PF 0.908 → 0.935, avg R -0.044 → -0.022) — still net
  losing, still PF < 1, and this improvement is concentrated in a few
  outlier trades rather than broad-based, which is a real tail-risk/variance
  consideration if this were ever a live decision, not just a backtest
  curiosity.
- **This does not address the entry-logic finding from addendum 2.** All 177
  `sl_hit` losers are completely untouched (delta = 0 for every one) — they
  never reach TP1, so no trailing multiplier can affect them. Even taking
  this result at face value, the majority of the sample is unaffected, and
  the overall aggregate remains net-negative. **This is the ceiling on
  exit-side improvement from this one lever, not a reason to revisit
  addendum 1's NO-GO.**

No further trailing variant, entry change, or anything else was tested in
this pass — reported and stopped, per the guardrail.

## 2026-07-10 — Post-Phase-1 pivot: minimal signal-detection test, Step 0 (pre-declared, before any result)

**Context:** three addenda produced a consistent NO-GO with no ambiguity left
in it (no entry edge, exit structure roughly sound, a wider trail helps the
aggregate only via outlier tail effect). This is a different question: does
the data already logged contain *any* out-of-sample predictable signal at
all, via a simple model, before committing to real ML infrastructure. One
model, one pre-declared bar, walk-forward only, reported once — not iterated
on if the answer is no.

**Target definition, committed now:**
- Binary classification: for every bar that reached the six-check gate
  (taken **and** rejected — the full per-bar signal population, not just
  executed trades), label = 1 if price moves favorably by ≥0.5R within the
  next **N=24 H1 bars** (24h lookahead — chosen to sit near the winner-side
  median hold time found in addendum 2, ~23h, giving the label a realistic
  window without being an arbitrarily long lookahead).
- **R-distance for the label** (needed for every row, including rejected
  signals that never had a real position/SL): `atr_value × 1.75`
  (`InpATRMultiplier`'s default under `SL_MODE_ATR`), applied uniformly.
  This is a hypothetical, not the trade's real SL — stated plainly since
  most rows never became real trades.
- **Favorable move computed from forward bar-close prices only** (the
  already-logged `proposed_entry` field, sequential per bar), not intrabar
  highs/lows — reusing already-logged data rather than pulling fresh price
  history, consistent with the bar-level resolution already used throughout
  this investigation. A real limitation, stated up front, not discovered
  after the fact.
- **Data source:** the 12 fallback logs already on disk from addendum 1 Step
  4 (w3/w4/w5 × EURUSD/GBPUSD/USDJPY/AUDUSD, gated mode — every signal row,
  taken or rejected, is already logged there). No new MT5 runs, no EA
  changes, no new data pulled — a pure offline re-read of existing data.
- **Features** (already-logged only, no engineering, no MFE/MAE or any other
  outcome-derived field as input): `atr_value`, the six check pass/fail
  booleans, `rsi_h1`, `rsi_h4`, `adx_h1`, `vol_regime` (one-hot),
  `session` (one-hot), `spread_at_signal`.
- **Model:** logistic regression, sane defaults, no hyperparameter tuning.
  One model, not a comparison.
- **Walk-forward split:** the same ~15.7-year reliable-spread span
  established in addendum 1 (2010-12-01 to 2026-07-09, w3-w5 combined,
  pooled across all 4 instruments) split into **6 sequential ~2.6-year
  sub-windows (f1-f6)**, rolling train-on-fold-k / test-on-fold-(k+1) — 5
  out-of-sample test folds. (Not reusing w3/w4/w5 directly as 2 folds — that
  would be too few to judge "consistent, not one lucky window" the same way
  addendum 1 did; splitting finer gives 5 folds from the same data with no
  new backtests required.)

**Success bar, declared now, before any model is fit:**
- **AUC ≥ 0.55 in at least 3 of the 5 out-of-sample folds** counts as
  **signal found**. 0.55 is a modest-but-real edge above chance (0.50) — a
  common rule-of-thumb floor for "probably something here" in weak-signal
  financial classification, not proof of a tradeable edge by itself.
- **One fold clearing the bar with the rest at or below chance counts as
  no signal found** — the same "one good window isn't enough" standard
  addendum 1's own go/no-go used.
- Accuracy will be reported alongside as a sanity check, but AUC (threshold-
  independent) is the metric the verdict is graded against.

## 2026-07-10 — Post-Phase-1 pivot: minimal signal-detection test, Steps 1-3 (result)

**Implementation note on the regex parse:** the first parsing pass silently
dropped ~76% of rows — a character class (`[a-z_]+`) used to capture
`rejection_reason` and similar string fields doesn't include digits, and
`h4_setup_invalid` (and other fields) contain one. Fixed to `[a-z0-9_]+`
before computing anything; caught by a sanity check against the already-known
per-year signal-row count (~6,200/year), not discovered downstream. Final
parse: **387,366 signal rows** (taken and rejected) across all 4 instruments,
2010-11-30 to 2026-07-08 — matches the expected rate exactly.

**Feature set used** (already-logged only, per Step 1): `atr_value`, the six
check pass/fail booleans, `rsi_h1`, `rsi_h4`, `adx_h1`, `spread_at_signal`,
`session` and `vol_regime` (one-hot). No MFE/MAE, no engineered features, no
new data pulled — a pure offline re-read of the 12 fallback logs already on
disk from addendum 1.

**Label base rate: 67.7%** ("price moves favorably by ≥0.5R within 24 bars,
in the signal's own predicted direction" is true most of the time). This is
expected, not a red flag — a 0.5R threshold over a 24-bar/24h window is loose
relative to typical H1 ATR-scale volatility, so it clears often regardless of
which direction is guessed. This is exactly why **AUC**, not accuracy, is the
graded metric — a model that just learns the base rate can hit ~68% accuracy
by predicting "favorable" almost always, without discriminating anything.

**Walk-forward results, 5 out-of-sample folds (train fold k, test fold k+1,
logistic regression, no tuning):**

| Train | Test | n train | n test | AUC | Accuracy |
|---|---|---:|---:|---:|---:|
| f1 | f2 | 64,592 | 64,146 | 0.522 | 0.686 |
| f2 | f3 | 64,146 | 64,778 | 0.522 | 0.672 |
| f3 | f4 | 64,778 | 64,333 | 0.528 | 0.678 |
| f4 | f5 | 64,333 | 65,096 | 0.516 | 0.680 |
| f5 | f6 | 65,096 | 64,325 | 0.526 | 0.673 |

**Folds clearing AUC ≥ 0.55: 0 of 5.**

**Verdict: NO SIGNAL FOUND**, against the bar pre-declared in Step 0 before
this was run. Not ambiguous — every fold clusters tightly in a narrow 0.516-
0.528 band, consistently a hair above pure chance (0.50) but nowhere near the
declared 0.55 floor, in every single fold. This is a cleaner "no" than a
scattered result would have been: there's no one lucky window inflating an
average, and no real instability between folds to argue over — the currently-
logged features (six-check booleans, RSI/ADX/ATR, session, spread) contain
at most a negligible, not-actionable amount of information about forward
0.5R-in-24h moves, under a simple linear model.

**What this does and doesn't say, per the addendum's own framing:** this
doesn't prove no signal exists in this market at any timeframe or feature
set — it says the specific, already-logged, already-cheap-to-test feature
set does not clear a modest bar. Per the addendum's pre-committed framing,
this is the point to have the bigger conversation (broader feature
engineering, a different market hypothesis such as mean-reversion tested
with the same rigor, or reconsidering project scope) rather than to retune
this same test. No second model, no new features, and no hyperparameter
search were run in this pass — reported once, per the guardrail.

## 2026-07-10 — Phase 1 formal closeout: risk control verification

**Scope:** the entry-logic question is answered (five independent tests, all
NO-GO/no-signal — summarized below). What remained was unrelated to entries:
a handful of Phase 1 acceptance-criteria items around risk controls were
never independently verified (all diagnostic attention went to entries and
exits), plus formal documentation closeout. No new hypotheses, no entry-logic
changes — verification and closeout only.

**Data-source note, consistent with every prior finding:** the Postgres
`trades`/`signals`/`risk_state` tables are empty for all backtest runs
(WebRequest fails in the Tester). All verification below uses the fallback
logs already on disk from addendum 1's Step 3/4 (both gated and, where
noted, bench-mode runs — the risk-control code is identical and shared
regardless of `InpBypassConfluence`, so bench-mode's higher trade frequency
was used to find real examples where gated mode's low frequency never
happened to trigger a given control).

### Step 1 — position sizing spot-check

Ground truth for the sizing formula (`RiskManager::CalculateLotSize`) needed
real broker tick-value/tick-size data, which isn't logged anywhere — a small
read-only diagnostic EA (`SymbolInfoDumpEA.mq5`, no trading, no live changes)
was compiled and run once per instrument through the Tester (same mechanism
as every other backtest in this project) to print `SYMBOL_TRADE_TICK_VALUE`/
`SYMBOL_TRADE_TICK_SIZE`/lot step/min/max directly from the broker. Confirmed:
EURUSD/GBPUSD/AUDUSD have a constant tick_value of $1.00 (USD-quoted, no
conversion needed — genuinely time-invariant, not just a snapshot). USDJPY's
tick_value is rate-dependent (JPY profit converted to USD) and was derived
per-trade from that trade's own logged price as an approximation, not a
constant.

**Methodology correction caught before trusting a result:** the first pass
verified against the `trades` table's post-fill `open_price`/`initial_sl`,
which can differ slightly from the pre-fill basis actually used for sizing
(`sig.proposed_entry`/`proposed_sl`, logged in the signal row at the moment
`CalculateLotSize` was called) — real fill price shifts slightly between
signal evaluation and order execution. Re-verified against the signal row's
own pre-fill fields instead, matched sequentially to trade opens (both are
1:1 ordered streams) to reconstruct running account balance.

**12 rows spot-checked, 4 instruments, 2 windows, spanning $9,177-$12,309
balance:**

| Window | Symbol | Balance | Logged lot | Expected lot | Match | Realized risk% |
|---|---|---:|---:|---:|---|---:|
| w3 | EURUSD | 10,000.00 | 0.17 | 0.17 | OK | 0.996% |
| w3 | EURUSD | 9,551.37 | 0.29 | 0.29 | OK | 0.991% |
| w3 | EURUSD | 9,207.24 | 0.34 | 0.34 | OK | 0.990% |
| w4 | USDJPY | 10,000.00 | 0.29 | 0.29 | OK | 0.970% |
| w4 | USDJPY | 10,014.02 | 0.35 | 0.34 | MISMATCH | 1.015% |
| w4 | USDJPY | 9,338.04 | 0.76 | 0.74 | MISMATCH | 1.020% |
| w3 | AUDUSD | 10,000.00 | 0.32 | 0.32 | OK | 0.984% |
| w3 | AUDUSD | 10,957.53 | 0.30 | 0.30 | OK | 0.985% |
| w3 | AUDUSD | 12,309.03 | 0.38 | 0.38 | OK | 0.992% |
| w4 | GBPUSD | 10,000.00 | 0.17 | 0.17 | OK | 0.997% |
| w4 | GBPUSD | 9,342.13 | 0.22 | 0.22 | OK | 0.961% |
| w4 | GBPUSD | 9,176.83 | 0.27 | 0.27 | OK | 0.976% |

**Result: 10 of 12 exact matches — a clean PASS on every non-JPY pair
(9 of 9, where the tick-value conversion is exact, not approximated).** The
2 USDJPY rows are off by 1-2 lot-steps and land at 1.015-1.020% realized risk
— slightly over the configured 1.00%. This is **not called a confirmed
bug**: the code itself (read directly) unambiguously floors, never rounds up
(`MathFloor(raw_lots / lot_step) * lot_step`), and the discrepancy is fully
consistent with the known limitation that USDJPY's tick_value had to be
approximated from a bar-close price rather than the exact live tick MT5 used
at the sizing instant — a verification-precision limit, not a reproduced
defect. Flagged honestly rather than rounded to a clean pass; would need
tick-level historical FX data to fully resolve either way.

### Step 2 — daily/weekly loss limit verification

Found real (not synthetic) examples in the existing bench-mode backtest
history: **daily** — 2010-12-15, AUDUSD (w3 bench), three consecutive
same-day signals rejected with `rejection_reason":"daily_loss_limit"`
(19:00, 20:00, 21:00) following a string of same-day realized losses;
trading resumed normally the next day (2010-12-16, `taken:true` at 08:00,
matching the prior day's pattern exactly). **Weekly** — 2016-09-01, USDJPY
(w4 bench), 21 hourly rejections with `"weekly_loss_limit"`.

| Check | Result | Evidence |
|---|---|---|
| `risk_state` row shows `loss_limit_hit=true` | **FAIL** | 0 occurrences of `"loss_limit_hit":true` anywhere across any log checked (searched the full w3 AUDUSD bench file — 1,429 `loss_limit_hit:false` rows, zero `true`) |
| Subsequent signal rejected with correct reason | **PASS** | Direct log lines, both examples above |
| Trading resumes at next valid period | **PASS** | 2010-12-16 08:00 signal taken normally |

**Real finding, not a clean pass:** `RiskManager::CheckRollover` is the
*only* call site for `LogRiskState`, and it unconditionally passes hardcoded
`0.0`/`false`/`false` regardless of what actually happens that day —
confirmed by reading the code, then confirmed empirically (zero `true`
values in the data). **The protective blocking behavior works correctly;
the audit trail for it does not.** A future session inspecting `risk_state`
alone would have no way to tell a loss-limit-halted day from a normal one —
only the `signals` table's `rejection_reason` field currently proves it
happened.

### Step 3 — max drawdown / max open trades / exposure

**Max open trades — PASS.** Same 2010-12-15 AUDUSD example: `"max_open_trades"`
rejection appears on every signal from 09:00-18:00 while a position was open,
consistent with `InpMaxOpenTrades=1`.

**Max exposure — not a distinct control, worth stating plainly.**
`CheckMaxExposure()` uses the identical `m_max_open_trades` threshold and
produces the identical `"max_open_trades"` rejection string as the max-open-
trades check — there is no separate per-symbol exposure cap in this
codebase. Fully expected given Phase 1's single-instrument-per-chart
architecture, but this is one mechanism, not two independently-verified
ones, and should be understood as such before anything more instrument-
concurrent is built.

**Max drawdown — PASS, behaviorally, with a methodology caveat.** Found a
real example (w3 AUDUSD bench): first `"max_drawdown_halt"` rejection at
2011-02-11T08:00, after which **zero** signals were taken for the remaining
32,796 signals in that ~5.3-year window — the halt engages and correctly
blocks every subsequent entry, with no incorrect early resumption. Caveat:
`CheckMaxDrawdown` gates on live `ACCOUNT_EQUITY` (balance plus unrealized
floating P&L on any open position), which isn't logged tick-by-tick — only
closed-trade realized P&L could be reconstructed after the fact (-2.53% at
the halt instant), which understates true equity drawdown at that moment
since it excludes whatever floating loss was open then. The mechanism's
*triggering and blocking* behavior is directly confirmed; the *exact*
10%-threshold crossing is taken on the code's own logic (independently read
and confirmed correct) rather than independently recomputed bar-by-bar.

### Step 4 — final verdict and reusable-vs-replace inventory

**Final verdict: NO-GO**, unchanged and now closed. Five independent tests
all concluded the same way: the walk-forward comparison was inconsistent
across windows and didn't beat a no-filter benchmark (addendum 1); losing
trades showed a clean zero-favorable-move signature — 0 of 177 `sl_hit`
losses ever traded favorably first (addendum 2); a wider trailing stop made
the typical trade worse and only helped the pooled aggregate via a few
outlier trades (addendum 3); and a minimal ML signal-detection test found a
flat ~0.52 AUC in every one of 5 out-of-sample folds, consistently short of
the pre-declared 0.55 bar (post-Phase-1 pivot). No test found a reason to
revisit an earlier one's conclusion.

**Reusable as-is** (pending Step 1's USDJPY caveat above, which doesn't
block reuse — it's a verification-precision gap, not a demonstrated bug):
the bridge service and its endpoints, the full database schema (`signals`,
`trades`, `risk_state`, `system_events`), `RiskManager.mqh` (position
sizing, loss limits, drawdown/exposure caps), `BridgeLogger.mqh`,
`SessionFilter.mqh`, `SpreadFilter.mqh`, the walk-forward/benchmark
validation harness and methodology built across all three addenda, and the
`ROLLING_WINDOW` confluence-timing mechanism as a reusable *pattern* (allow
trigger-type checks to fire within a trailing window) even where the
specific six checks themselves are replaced.

**Specific to this hypothesis, needs replacing for anything new:**
`Trend.mqh`, `Structure.mqh`, `Momentum.mqh`, `EntryLogic.mqh` — the actual
confluence logic and its six checks, since these embody the specific,
now-falsified hypothesis that this combination of trend/momentum/candlestick/
volume signals predicts direction.

**Needs a decision either way, not yet resolved:** `ExitManager.mqh`'s
specific parameters (1.5x ATR trail, 1R/2R partial levels) — the *mechanism*
tested fine (Step 1/3 of addendum 2 found no execution-timing losses in the
partial-close logic), but its specific tuning was only ever validated
against this now-rejected entry logic. A new hypothesis should re-derive or
re-test these rather than assume they carry over unchanged.

**Also flagged for whoever picks this up next:** the `risk_state`
audit-trail gap from Step 2 above (blocking works, logging doesn't reflect
it) is worth fixing before it's relied on for anything, independent of
whatever entry hypothesis comes next.

**No further work proceeds on the current confluence logic.** This is the
formal, plain closing line of Phase 1, consistent with every addendum's own
conclusion along the way: the six-check confluence hypothesis is closed out
NO-GO. Anything that follows — a redesigned entry hypothesis, a different
market thesis, broader feature engineering for the ML angle, or a decision
to pause the project — is a new decision for the user to make, not an
automatic next step from here.

### Update, same day — Fix 1: `risk_state` audit-trail bug

The gap flagged above (blocking works, `risk_state` never shows it) is
fixed. Scoped to exactly one function, nothing else touched.

**Fix:** `RiskManager::CheckRollover` was the only call site for
`LogRiskState`, and it only ever ran at the *start* of a new day/week — by
construction it could never observe a mid-day breach, since a fresh day's
realized P&L is trivially 0 and its hit-flag trivially false. Fixed by
additionally logging the *outgoing* day's final tally right before resetting
for the new one, computed from the exact same source of truth
`CheckDailyLossLimit`/`CheckWeeklyLossLimit` already use
(`SumClosedProfitSince(m_day_start_time)` and the latched
`m_daily_loss_limit_hit`/`m_weekly_loss_limit_hit` flags) — not a parallel
calculation, so `risk_state` can't drift from what actually gated entries
that day. `loss_limit_hit` and `trading_halted` are both set to
`daily_hit OR weekly_hit` (either one blocks entries; the schema has no
separate weekly row). `realized_pnl` reflects that day's own realized P&L,
even on the 2016-09-01 row below where it was the *weekly* cumulative loss
that actually tripped the halt — a necessary, stated caveat given one row
per day, not per scope.

**Known, accepted gap:** each trading day now produces two `risk_state` rows
(an opening 0.0/false snapshot, and — logged one day later, retroactively —
the closing tally). The very last day of any run never gets its closing row,
since there's no subsequent rollover to trigger it. Both are acceptable
given the fix's scope; not a hidden defect.

**Verification — did not require a fresh multi-window run**, per the
guidance to check first: re-ran only the 2 specific bench-mode
window/instrument combinations containing the known real examples
(w3 AUDUSD, w4 USDJPY — same date ranges, same settings, only the compiled
binary changed), not the full addendum-1 batch.

| Date | Scope | Realized P&L | `loss_limit_hit` | Context |
|---|---|---:|---|---|
| 2010-12-15 (opening row) | daily | $0.00 | false | as expected, day just started |
| **2010-12-15 (closing row)** | daily | **-$320.86** | **true** | -3.08% of day-start balance ($10,428.94) — correctly crosses the 3% daily limit |
| 2010-12-16 (next day) | daily | $0.00 | false | balance $10,108.08 = $10,428.94 - $320.86, exact carry-forward, trading resumed |
| 2016-09-01 (opening row) | daily | $0.00 | false | as expected |
| **2016-09-01 (closing row)** | weekly (via OR) | **-$204.55** | **true** | only -1.97% *that day* alone (below the 3% daily bar) — correctly reflects the *weekly* cumulative loss tripping the halt |

**Normal-case spot check, 5 non-breach days, real trading activity, w3
AUDUSD:** all correctly show `loss_limit_hit=false` with real (nonzero,
both positive and negative) realized P&L, none near the 3% threshold
(-0.68%, +0.32%, +0.34%, +1.50%, +2.77% of day-start balance) — the fix
didn't just make the failure case work, the ordinary case is still correct
too.

**Recompiled clean (0 errors, 0 warnings).** Committed and re-tagged
`phase1-closed-no-go-v2`, superseding `phase1-closed-no-go` — same NO-GO
verdict, unchanged; only the risk_state logging defect is new information
since the original tag.

## 2026-07-10 — Phase 1b: mean-reversion hypothesis, build + pre-declaration

**A genuinely new hypothesis, not a Phase 1 redesign**: price that becomes
locally overextended during range-bound conditions tends to revert toward
its recent mean — close to the opposite bet of Phase 1's trend-following
premise. Reuses Phase 1's verified infrastructure as-is (bridge, full DB
schema, `RiskManager.mqh`, `BridgeLogger.mqh`, `SessionFilter.mqh`,
`SpreadFilter.mqh`, the walk-forward/benchmark methodology, the w3-w5 window
boundaries, the same four instruments) and replaces only the entry/exit
logic.

**Four decisions confirmed with the user before any code was written:**
1. Regime-filter timeframe: **H4** (not D1) — reuses `Trend.mqh`'s existing
   ADX sideways threshold/classifier unmodified, just timeframe-parameterized
   (defaults to D1, so Phase 1 itself is untouched) so it can run on H4.
2. Band definition: **20-period SMA ± 2.0 SD on H1** (Bollinger-standard).
3. Holding-period cap: **48 H1 bars**.
4. Schema approach: **`strategy_variant` column** added to `signals`/`trades`
   (default `'phase1_confluence'`, migrated live against the running
   Postgres instance and reflected in `database/schema.sql`), rather than
   separate parallel tables.

**Built:**
- `MeanReversionEntry.mqh` — five independently-evaluated, never-short-
  circuited checks (regime filter, band touch, momentum extreme, reversal
  candlestick, structural-level integrity), logged into the same `signals`
  schema via a new `features` JSON shape specific to this hypothesis (no
  schema change needed beyond `strategy_variant` — `features` was always
  free-form JSONB). Reuses `Structure.mqh`'s swing detection and
  `EntryLogic.mqh`'s exact candlestick-pattern detector (made `public` for
  this reuse, previously `private`) rather than rebuilding either. Check 3
  (momentum extreme) deliberately uses a *different condition shape* than
  Phase 1's `RSIConfirms` — the same threshold value, but checking the
  extreme itself rather than a recovery-already-underway pattern, since
  that's the shape mean reversion actually needs; stated here as the reason
  for the change, per the task's own instruction.
- `MeanReversionExit.mqh` — its own exit structure, not inherited from
  `ExitManager.mqh`: TP is the band's moving mean (re-read live every tick,
  not a static broker order), SL is ATR-based by default with band-extreme
  as an A/B-toggleable alternative (`InpMRSLMode`, same pattern as addendum
  3's trailing-stop test), a simple breakeven-after-0.5R rule (reusing
  `RiskManager`'s existing generic breakeven flag), and the 48-bar holding
  cap forcing a market close tagged `exit_reason='timeout'`.
- `Phase1bEA.mq5` — new EA (magic number `20260102`, distinct from Phase 1's
  `20260101`), wiring the above plus unmodified reuse of `RiskManager.mqh`,
  `SessionFilter.mqh`, `SpreadFilter.mqh`, `NewsFilter.mqh`,
  `BridgeLogger.mqh`. Includes `InpBypassMeanReversion`, the same
  no-filter-benchmark pattern Phase 1 used. Compiles clean (0 errors, 0
  warnings).
- `BridgeLogger.mqh` gained one small addition (`LogSignalJson`, a generic
  JSON-body variant of `LogSignal` for strategies that don't share Phase 1's
  specific `Signal` struct field names) and `LogTradeOpen` gained a
  `strategy_variant` parameter — Phase 1's own call site updated to pass
  `"phase1_confluence"` explicitly. `RiskManager.mqh` itself: untouched.

**Smoke test** (EURUSD, 2020-01-01 to 2020-03-01, gated mode): ran without
error, all five checks logged independently on every bar (confirmed: even
the very first rejected signal carries all five `check1`-`check5` booleans,
not a collapsed pass/fail), one real trade taken and closed correctly
(`exit_reason:"tp_mean"`, r_multiple 0.159, profit +$13.86 matching the
report exactly, mfe/mae both tracked and sensible).

**Frequency check before finalizing the walk-forward design** (per Section 4
— don't assume): ran EURUSD gated mode across the full w3-w5 span
(2010.12-2026.07, ~15.7 years) — **57 trades**, ~3.6/year, net +$396.20, PF
1.17, max drawdown 3.92%. Meaningfully more frequent than Phase 1's original
~1/year problem. Pooled across 4 instruments this should land in the
~200+ range across the full span — comfortably clearing a ≥100 pooled bar
using the **same w3-w5 three-window structure Phase 1 used**, not a
finer sub-window split like the ML signal-detection test needed.

### Pre-declared design and success criteria (before the full batch runs)

- **Walk-forward:** same w3-w5 windows (2010.12-2016.06, 2016.06-2021.12,
  2021.12-2026.07), same 4 instruments (EURUSD, GBPUSD, USDJPY, AUDUSD),
  gated mode and `InpBypassMeanReversion` benchmark mode for each — 24 runs
  total, directly comparable to Phase 1's own addendum 1 Step 4 design.
- **No per-window optimization** — same guardrail as every Phase 1 addendum.
  Fixed configuration throughout (the four user-confirmed defaults above,
  reused RSI/ADX thresholds); no threshold tuned based on early results
  without the same bug-vs-strictness scrutiny Phase 1 held to.
- **Consistency standard: reused directly from Phase 1's own go/no-go** — 
  positive expectancy in most/all sequential windows counts as consistent;
  one good window with the rest flat or negative counts as **inconsistent**,
  same bar addendum 1 held the confluence strategy to.
- **Sample-size bar: ≥100 pooled gated trades in aggregate** before treating
  the go/no-go as more than directionally suggestive — same bar as Phase 1's
  own walk-forward.
- **Benchmark comparison is mandatory, not optional** — bypass the five-check
  gate (`InpBypassMeanReversion=true`), identical risk sizing and exit
  management, to check whether the entry conditions add expectancy over
  fading any band touch unconditionally. This is exactly the check that
  caught Phase 1's real problem (entries reducing trade count without adding
  expectancy) and is held to the same importance here, not skipped.
- **Go in expecting NO-GO is a real possibility** — this hypothesis being
  "close to the opposite bet" of Phase 1's is a reason to test it, not a
  reason to expect it to pass.

Full walk-forward + benchmark batch not yet run — reported next, per the
same "declare before running" discipline as every prior addendum.

## 2026-07-10 — Phase 1b: walk-forward + benchmark result, go/no-go

Ran the pre-declared 24-run batch (w3/w4/w5 × EURUSD/GBPUSD/USDJPY/AUDUSD ×
gated/benchmark), archived cleanly (all 24 `COMPLETE.marker` + fallback logs
present).

**Per-instrument, gated mode:**

| Window | Symbol | n | Win% | Net | PF | Avg R |
|---|---|---:|---:|---:|---:|---:|
| w3 | EURUSD | 24 | 41.7% | +$80.41 | 1.077 | +0.046 |
| w3 | GBPUSD | 19 | 42.1% | -$38.26 | 0.953 | -0.007 |
| w3 | USDJPY | 20 | 45.0% | +$421.39 | 1.690 | +0.190 |
| w3 | AUDUSD | 17 | 64.7% | +$495.13 | 2.447 | +0.302 |
| w4 | EURUSD | 19 | 52.6% | +$304.92 | 1.588 | +0.169 |
| w4 | GBPUSD | 17 | 17.6% | -$685.77 | 0.260 | -0.403 |
| w4 | USDJPY | 8 | 37.5% | -$293.30 | 0.416 | -0.357 |
| w4 | AUDUSD | 13 | 46.2% | -$85.65 | 0.866 | -0.025 |
| w5 | EURUSD | 14 | 42.9% | +$2.73 | 1.004 | +0.005 |
| w5 | GBPUSD | 24 | 50.0% | +$205.94 | 1.224 | +0.092 |
| w5 | USDJPY | 14 | 14.3% | -$630.63 | 0.172 | -0.464 |
| w5 | AUDUSD | 11 | 27.3% | -$272.41 | 0.547 | -0.238 |

**Per-window pooled (all 4 instruments), gated vs. benchmark:**

| Window | Mode | n | Win% | Net | PF | Avg R |
|---|---|---:|---:|---:|---:|---:|
| w3 | gated | 80 | 47.5% | +$958.67 | 1.340 | +0.124 |
| w3 | bench | 477 | 47.8% | -$1,343.19 | 0.934 | -0.026 |
| w4 | gated | 57 | 38.6% | -$759.80 | 0.706 | -0.120 |
| w4 | bench | 233 | 47.6% | -$3,598.27 | 0.640 | -0.155 |
| w5 | gated | 63 | 36.5% | -$694.37 | 0.767 | -0.109 |
| w5 | bench | 857 | 53.7% | +$1,979.30 | 1.056 | +0.023 |

**Aggregate, w3-w5 pooled:**

|  | Confluence-gated (5-check) | No-filter benchmark |
|---|---:|---:|
| n | 200 (clears the ≥100 bar) | 1,567 |
| Win rate | 41.5% | 51.0% |
| Net profit | -$495.50 | -$2,962.16 |
| Profit Factor | 0.941 | 0.955 |
| Avg R-multiple | -0.019 | -0.018 |

**Exit reasons (gated, pooled): 112 `sl_hit`, 88 `tp_mean`, 0 `timeout`.** The
48-bar holding cap never once bound across 200 trades — every trade resolved
(one way or the other) faster than that. Not a problem, just never the
active constraint; worth knowing before assuming the cap value matters.

**Go/no-go, against the pre-declared bar:**

1. **Inconsistent across windows — same failure mode as Phase 1's own
   confluence logic.** Gated was strongly profitable in w3 (+0.124 avg R,
   PF 1.34) but lost money in both w4 (-0.120) and w5 (-0.109). One good
   window out of three, again.
2. **Doesn't beat the benchmark.** PF (0.941 vs 0.955) and avg R (-0.019 vs
   -0.018) are essentially indistinguishable between the gated five-check
   version and unconditionally fading any band touch. The five checks
   mainly reduce trade count (200 vs 1,567) without buying better
   expectancy — the same pattern that closed out Phase 1.
3. Sample clears the pre-declared ≥100 bar (200 gated trades), so this is a
   real reading, not a thin-sample artifact.

**Decision: NO-GO.** Same standard as Phase 1's own go/no-go, same result.
The mean-reversion hypothesis — tested with the same rigor, the same
window boundaries, and a mandatory benchmark comparison — does not clear
the bar either. This is not a reason to iterate on band width, RSI
threshold, or holding cap in this same pass (per the guardrail); it's a
second, independent data point alongside Phase 1's that this general
class of "one indicator combination on raw OHLC/RSI/ADX features, four
majors, H1" approach isn't finding an edge on this data, echoing the ML
signal-detection test's own conclusion. Whether the next step is a
materially different feature set, a different market/timeframe, or
reconsidering scope is a decision for the user — not an automatic next
step from here.

## 2026-07-10 — Market-character check: is w3 structurally different from w4/w5?

**Measurement only, no new trading logic, no backtests.** Both Phase 1
(trend-following) and Phase 1b (mean-reversion) — structurally opposite
hypotheses — were profitable in w3 and unprofitable in both w4 and w5.
Before scoping a third hypothesis, checked whether w3 itself is unusual in
basic market-character terms, independent of any strategy.

**Method:** a new read-only logger (`MarketCharacterDumpEA.mq5` — no entries,
no exits, no risk management, not a backtest of anything) reusing `Trend.mqh`
unmodified (a D1 instance matching Phase 1's own usage, an H4 instance
matching Phase 1b's) and `Volatility.mqh` unmodified (H1 ATR), logging real
daily OHLC once per day and D1/H4 regime classification + H1 ATR + spread
once per H1 bar. Run once per window/instrument (12 runs, no trading, fast).

**Cross-instrument averages per window:**

| Metric | w3 | w4 | w5 |
|---|---:|---:|---:|
| Daily range, median (pips) | 89.8 | 72.8 | 83.6 |
| Annualized volatility | 9.28% | 8.43% | 9.18% |
| Avg H1 ATR (pips) | 18.6 | 15.3 | 17.3 |
| **Avg spread (points)** | **12.34** | **7.72** | **7.79** |
| D1 sideways time | 10.0% | 10.3% | 9.9% |
| H4 sideways time | 9.9% | 9.4% | 10.9% |

**Per-instrument detail (daily range median / annualized vol / avg ATR / avg
spread):**

| | EURUSD | GBPUSD | USDJPY | AUDUSD |
|---|---|---|---|---|
| w3 | 98.4p / 9.33% / 20.0p / 8.96 | 105.1p / 7.54% / 20.8p / 14.59 | 69.0p / 9.33% / 15.3p / 10.98 | 86.8p / 10.93% / 18.4p / 14.81 |
| w4 | 69.7p / 6.80% / 13.8p / 5.11 | 98.3p / 9.77% / 20.7p / 10.58 | 65.3p / 7.95% / 14.3p / 6.23 | 57.9p / 9.18% / 12.4p / 8.98 |
| w5 | 71.1p / 7.69% / 14.6p / 5.53 | 88.3p / 8.53% / 18.5p / 9.39 | 114.3p / 10.06% / 23.4p / 8.18 | 60.7p / 10.42% / 12.8p / 8.05 |

**Regime mix (D1 and H4) is essentially flat across all three windows** —
~9-11% sideways time on both timeframes, in every window, for every
instrument. No meaningful trending/ranging mix shift that would favor a
trend-following strategy in w3 over w4/w5, or vice versa for mean reversion.
This directly does not explain either strategy's differential performance.

**Volatility/range is somewhat elevated in w3 vs. w4, but w5 looks similar
to w3 on this dimension** — daily range and annualized vol in w5 (83.6 pips
/ 9.18%) sit much closer to w3 (89.8 / 9.28%) than to w4 (72.8 / 8.43%). If
volatility alone explained the pattern, w5 should have looked more like w4;
it doesn't. Not a clean "w3 uniquely different" story on this dimension —
w4 is more the outlier (lower) than w3 is.

**Spread is the one dimension where w3 is clearly, consistently, and
substantially different — and it points the wrong direction to explain
w3's better performance.** Average spread in w3 (12.34 points) is roughly
60% wider than both w4 (7.72) and w5 (7.79) — consistent across every
single instrument (e.g. EURUSD 8.96→5.11→5.53, AUDUSD 14.81→8.98→8.05). A
wider spread is a real cost headwind, eating into every trade's realized R —
if anything, this should have made w3 *harder* to profit in, not easier.
That both strategies still did best in w3 despite meaningfully worse cost
conditions there makes the outperformance look a little more like it
overcame a headwind than like it was riding a tailwind. Worth noting: w4 and
w5's spread levels are nearly identical (7.72 vs. 7.79) — this reads as a
one-time structural drop somewhere between w3 and w4, not a continuous
narrowing trend across the whole 2010-2026 span. No claim made here about
*why* (broker-side change, industry-wide liquidity shift, etc.) — out of
scope, per the non-goals.

**Direct answer to the question asked:** w3 does **not** look like a
meaningfully different, friendlier trading regime in the ways that would
intuitively explain two opposite strategies both doing well there.
Regime mix is flat. Volatility is only weakly and inconsistently elevated
(w5 looks similar to w3). The one clearly, consistently different
dimension — spread — points toward w3 being a *harder* cost environment,
not an easier one. **This leans toward the shared w3-good/w4-w5-bad pattern
being closer to noise/luck in w3 specifically than to a well-explained
market-character shift** — a useful, if slightly deflating, piece of context
for however a third hypothesis gets scoped: it should not be tuned or
validated with an expectation that w3-like conditions (by any measure found
here) are identifiable or repeatable in advance.

No regime detector or predictive model was built from this, per the
non-goals — reported and stopped.

## 2026-07-10 — ML escalation: richer features, nonlinear model, Step 0 (pre-declared)

**Context:** the first signal-detection test (logistic regression, a modest
already-logged feature set) found no signal — AUC flat 0.516-0.528 across 5
folds. This escalates two things at once: a richer feature set (not limited
to what one strategy's own gate happened to log) and a nonlinear model
(gradient-boosted trees). Deliberately a combined test — isolating which
change mattered, if either does, is a separate later step.

**Kept identical to the first test, for direct comparability:**
- **Target/label**: does price move favorably by ≥0.5R within the next 24 H1
  bars, R = `atr_value × 1.75`. Not redefined.
- **Universe and folds**: same 4 instruments (EURUSD/GBPUSD/USDJPY/AUDUSD),
  same w3-w5 span, same 6 sequential ~2.6-year sub-windows, same 5 rolling
  train-fold-k/test-fold-(k+1) out-of-sample tests.
- **Success bar: AUC ≥ 0.55 in at least 3 of 5 folds = signal found.**
  Explicitly unchanged from the first test — not picked to be easier to
  clear. One fold clearing it with the rest at chance still counts as no
  signal found, same standard as before.

**What's actually new:**
- **Every H1 bar in price history**, not bars filtered through Phase 1's or
  Phase 1b's own entry gate (the first test's data source — Phase 1's
  fallback logs — already logged every bar regardless of taken/rejected
  status, so this is less of a change than it might sound, but stated
  explicitly since the instruction called for it).
- **New features** (Step 1, computed fresh from raw price history, not
  reused from either strategy's logs): multi-timeframe MA distance (D1/H4/H1,
  in ATR units), %B-style range position, lagged returns (1/4/24 bars),
  rolling realized vol and its expansion/contraction vs. its own longer-term
  average, cross-instrument recent returns (the other three pairs' moves as
  features for each pair's own prediction), hour-of-day and day-of-week.
- **Model**: `HistGradientBoostingClassifier` (scikit-learn, already
  installed from the first test) — shallow trees, conservative settings, no
  hyperparameter search. One fixed configuration.

**Data source decision:** rather than extending the first test's log-parsing
approach (which only has H1 close prices and the specific fields Phase 1's
EA happened to compute — no raw OHLC, no H4/D1 bars), a new minimal
read-only export EA (`MLFeatureDumpEA.mq5`) will log real H1 OHLCV plus
`iATR`/`iRSI`(H1)/`iRSI`(H4)/`iADX`(H1)/spread directly per bar — calling
MT5's own indicator functions directly (not importing/modifying `Trend.mqh`,
`Momentum.mqh`, or `Volatility.mqh`) so this stays a standalone, read-only
data pull with zero touch to any shared or live-strategy module, consistent
with the "no changes to MQL5 or live infrastructure" non-goal. All *new*
features (moving averages, %B, lags, rolling vol, cross-instrument returns,
calendar) are then computed fresh in Python from the exported OHLCV — this
is appropriate for genuinely new features (only the baseline ATR/RSI/ADX
values need to match the first test's exact computation method for
comparability, which is why those three alone are pulled from MT5's own
indicators rather than reimplemented).

**Leakage discipline, stated before building:** every feature must use only
information available at the close of the bar being evaluated. All rolling
windows are trailing-only (pandas `.rolling()`, never centered); any lagged
feature is computed relative to the bar being evaluated, never referencing
a later bar. This will be verified explicitly in Step 1, not just assumed.

Building and running next — reported once, per the guardrail.

## 2026-07-10 — ML escalation: result

**Data:** `MLFeatureDumpEA.mq5` (read-only, calls MT5's own `iATR`/`iRSI`/
`iADX` directly — no shared/live-strategy module touched) exported real H1
OHLCV + indicators for all 4 instruments across the full w3-w5 span. Row
counts (96,846 / 96,834 / 96,840 / 96,846) matched the first test's parsed
counts exactly — same underlying price history, confirmed.

**Leakage check (stated, not just assumed):** D1 EMA50/200 and H4 EMA50
distances use `.shift(1)` at the daily/H4-bucket level — every H1 bar within
a given day (or H4 bucket) uses the *prior* day's (or bucket's) closed EMA,
never its own still-forming one, mirroring `Trend.mqh`'s own `shift=1`
convention exactly. All rolling windows (`%B`, realized vol, vol expansion)
use pandas' default trailing (right-aligned, never centered) window. Lagged
returns and cross-instrument returns are contemporaneous-or-past only,
never referencing a bar after the one being evaluated. Final joined dataset:
387,270 rows — identical to the first test's row count after label
dropna, a second independent consistency check.

**Model:** `HistGradientBoostingClassifier`, one fixed conservative
configuration, no tuning: `max_depth=4, max_iter=150, learning_rate=0.05,
min_samples_leaf=200, l2_regularization=1.0`.

**Walk-forward results, same 5 folds:**

| Test fold | AUC (GBM, richer features) | AUC (logistic regression, baseline — first test) | Delta |
|---|---:|---:|---:|
| f2 | 0.524 | 0.522 | +0.002 |
| f3 | 0.531 | 0.522 | +0.009 |
| f4 | 0.533 | 0.528 | +0.005 |
| f5 | 0.526 | 0.516 | +0.010 |
| f6 | 0.517 | 0.526 | -0.009 |
| **mean** | **0.526** | **0.523** | **+0.003** |

**Folds clearing AUC ≥ 0.55: 0 of 5.**

**Verdict: NO SIGNAL FOUND** — same standard as the first test (unchanged
bar, as pre-declared), same result. Not ambiguous: every fold sits in a
0.517-0.533 band, still nowhere near 0.55.

**Did richer features + a nonlinear model move the needle at all?**
Slightly — mean AUC ticked up from 0.523 to 0.526, with 4 of 5 folds
individually higher (one, f6, lower). This is a genuinely different outcome
than "zero movement," worth stating plainly rather than rounding to "nothing
changed" — but a ~0.003 mean shift is not a meaningful step toward the
0.55 bar, and doesn't change the verdict.

**Feature importance (permutation, last fold, descriptive only — not used
for tuning):** the model leaned most on volatility-related features
(`vol_expansion`, `vol_short`, raw `atr`, `vol_regime_low`) and calendar
(`hour`), ahead of the multi-timeframe price-position features
(`h4_ema50_dist_atr`, `d1_ema200_dist_atr`, `h1_sma20_dist_atr`) and
cross-instrument returns (`xret24_AUDUSD`, `xret4_USDJPY`). All importances
are small in absolute terms (largest permutation AUC drop ≈ 0.004),
consistent with a genuinely weak model rather than one variable quietly
carrying real signal.

**Third independent line of evidence, same conclusion.** Two hand-built
strategies (Phase 1's confluence logic, Phase 1b's mean reversion) and now
two ML approaches (linear model / modest features, nonlinear model / richer
features) have all failed to find an edge in this instrument set at H1/H4/D1
granularity using price-action-derived features. This meaningfully shifts
the case for continuing to iterate on this same instrument set and data
class versus a materially different feature source (order flow, sentiment,
cross-asset macro context not derivable from these four pairs' own price
history) or a different market/timeframe entirely — a decision for the user,
not resolved here.

No hyperparameter search, no second model, and no feature added mid-analysis
were run in this pass — reported once, per the guardrail.

## 2026-07-11 — Instrument-class pivot: gold & index, result

**Context:** four independent, rigorous investigations on the four FX
majors — two hand-built strategies, two ML approaches — all found no
exploitable edge. This asks whether the limiting factor is these four pairs
specifically, or this whole style of price-action analysis. **Pre-committed
before running anything**: if this also comes back NO SIGNAL FOUND, the next
step is not a fifth technical test — it's stepping back to reassess the
project itself, specifically a shift toward a decision-support tool rather
than a fully autonomous EA. That decision is recorded in advance here so it
isn't improvised after a disappointing result.

### Step 0 — instrument/history check, confirmed with the user before building

Checked candidate symbols via a small read-only check EA (`InstrumentCheckEA.mq5`,
run once per candidate as the Tester's own symbol — checking non-tested
symbols from within a Tester run is unreliable, established empirically in
Phase 1). Two things came back different than assumed:
- **The gold symbol on this broker is `GOLD`, not `XAUUSD`** — confirmed
  before building anything further.
- **Every non-FX instrument checked (GOLD, US500, US30, US2000, DE40)
  showed only ~3.5 years of history** in the initial narrow-window check —
  meaningfully shorter than FX's 15+ years.

**Confirmed with the user:** proceed with GOLD + US500 (the task's own
stated default, symbol name corrected), and restructure the walk-forward to
**4 sequential folds (3 out-of-sample test folds)** instead of 6/5, with the
consistency bar adjusted to **2 of 3 folds clearing AUC ≥ 0.55**.

Once the actual full-range export ran (rather than the narrow 4-day check
window), real history turned out to extend further back than the initial
check suggested — **2021-12-31 onward** for both instruments (~4.5 years,
not ~3.5) — confirming the earlier `SERIES_FIRSTDATE` check itself was a
narrow-window artifact, not authoritative. Noted for the record, not
re-litigated: the fold design was already confirmed on the (slightly
conservative) 3.5-year assumption and still fits comfortably in the actual
~4.5-year span.

**Real, unplanned finding: GOLD only quotes 9 server-time hours/day
(15:00-23:59)** — a limited-session CFD product on this broker, not
near-continuous like FX or the index (US500: ~15.6 bars/day, close to 24/5).
This means the label's "24 H1 bars" lookahead spans roughly a full calendar
week for GOLD, not roughly a day as for FX/US500 — a different practical
meaning of the same nominal definition. Flagged plainly; the label was kept
unchanged for comparability, per the task's own instruction, not silently
redefined.

### Steps 1-3 — data, model, results

Reused `MLFeatureDumpEA.mq5` unchanged, run once per instrument across the
full available history. Same feature set as the FX ML escalation test
(baseline ATR/RSI/ADX/spread/session/vol-regime + multi-timeframe MA
distance, %B, momentum lags, rolling vol expansion, calendar), with
cross-instrument-return features adapted to GOLD↔US500 (each instrument's
model gets the other's contemporaneous 1/4/24-bar returns, per the task's
explicit allowance). Same model, unmodified: `HistGradientBoostingClassifier,
max_depth=4, max_iter=150, learning_rate=0.05, min_samples_leaf=200,
l2_regularization=1.0`.

**Real data-quality issue found and handled the same way Phase 1 handled
FX's synthetic-spread windows — excluded on an objective, checkable ground,
not a post-hoc cherry-pick:** GOLD's export has a genuine **207-day gap**
(2025-05-08 to 2025-12-02) with a **57% price discontinuity** across it
(18.87 → 29.72) — a broker-side contract reset, not organic price movement.
This landed right at the fold-3/fold-4 boundary of the originally-confirmed
4-fold design, contaminating that test fold. Re-ran GOLD on the clean
pre-gap subset only (2021-12-31 to 2025-05-08, 5,921 of 6,941 rows), 3
folds / 2 test folds, with the standard tightened to **both folds must
clear** (the same n=2 convention already established as the fallback during
Step 0's fold-design discussion).

**GOLD, original 4-fold run (fold 3→4 contaminated by the gap):**

| Test fold | AUC |
|---|---:|
| f2 | 0.568 |
| f3 | 0.533 |
| f4 (contaminated) | 0.455 |

**GOLD, clean pre-gap subset, 2 test folds:**

| Test fold | AUC |
|---|---:|
| f2 | 0.580 |
| f3 | 0.507 |

1 of 2 clean folds clears 0.55 — under the n=2 standard (both must clear),
**NO SIGNAL FOUND**. The one fold that did clear (0.580) did not replicate
in the very next fold (0.507, essentially chance) — the same "doesn't
replicate" pattern this entire investigation has consistently treated as
insufficient evidence, not signal, going back to addendum 1's own standard.

**US500, clean throughout, 3 test folds:**

| Test fold | AUC |
|---|---:|
| f2 | 0.520 |
| f3 | 0.526 |
| f4 | 0.535 |

0 of 3 folds clear 0.55 — **NO SIGNAL FOUND**, cleanly and consistently.
These AUC values sit in essentially the same 0.52-0.53 band as every FX
fold across both prior ML tests — not a new pattern, the same one.

**Feature importance (descriptive only, both instruments):** GOLD leaned on
`d1_ema50_dist_atr`, `vol_expansion`, `pct_b`; US500 leaned on `pct_b`,
`atr`, `h4_ema50_dist_atr`. Broadly similar in character (volatility and
price-position features dominant) to the FX escalation test's own
importances — no qualitatively different pattern emerged for either new
instrument.

### Step 4 — combined verdict and the pre-committed next step

**Combined verdict: NO SIGNAL FOUND**, for both instruments, on clean data.
This extends the pattern from four FX majors to a metal and an equity
index — five independent lines of evidence (two hand-built strategies, two
FX ML tests, this cross-asset test) now point the same direction.

**Per the pre-committed decision recorded before this test ran: no further
instrument, feature set, or model is being scoped from here.** The
automated-edge-search line of investigation that has run across every
addendum since Phase 1's closeout is being paused. The next conversation is
about the project's direction — specifically whether to continue as a fully
autonomous EA search, or shift toward a decision-support tool that surfaces
analysis for a human to act on — not another technical test. That is a
scoping decision for the user to make explicitly, not an automatic
continuation of this line.

---

# New phase: decision-support dashboard

**This is a distinct new phase, not a continuation of the edge-search
investigation above.** Everything from Phase 1 through the instrument-class
pivot was about finding an automated, tradeable edge — none was found,
across five independent tests. This phase builds the tool that follows from
that result: a local dashboard that surfaces honest, structured market
context for a *human* to make discretionary decisions with, plus the
infrastructure to eventually evaluate whether *those* decisions carry an
edge, the same rigorous way the automated strategies were evaluated.

**What it is:** a descriptive market-context panel (trend/regime
classification, volatility, session, spread, distance to nearby levels —
all mechanical readouts of current/past price action), a verified
position-sizing calculator, and a discretionary trade journal with a
rationale field and honest realized-R summary stats.

**What it is not, hard constraint:** nothing in this tool presents a
prediction, confidence score, or probability derived from any of the tested
models or entry-logic gates. Every one of them was shown to carry no real
signal (AUC ~0.52-0.53 across the board, both hand-built strategies
NO-GO). Displaying anything derived from them as if informative would be
actively misleading regardless of caveats — so nothing from `signals`,
`trades`, or any ML artifact is queried by this dashboard at all. Verified
by explicit review of every screen before calling this done.

## 2026-07-11 — Decision-support dashboard: build

**Confirmed with the user before building:** lightweight web dashboard
(extends the existing FastAPI bridge, no heavy framework) over an MT5
on-chart panel; all six already-tested instruments (EURUSD, GBPUSD, USDJPY,
AUDUSD, GOLD, US500); snapshot refresh on every H1 bar close, matching every
prior investigation's own granularity.

**Built:**
- **`market_context` / `journal_trades` tables** — added to
  `database/schema.sql` and migrated live against the running Postgres
  instance.
- **`ContextSnapshotEA.mq5`** — new, read-only, no trading. A single
  multi-symbol EA (loops over all 6 instruments explicitly by symbol
  parameter, not `_Symbol`) logging, once per instrument per H1 bar close:
  D1/H4 trend classification (`Trend.mqh`, unmodified), ATR + volatility
  regime (`Volatility.mqh`, unmodified), session (`SessionFilter.mqh`,
  unmodified), spread (`SpreadFilter.mqh`'s *read* only, `GetCurrentSpreadPoints()`
  — never its gating logic, since this panel shows spread, it doesn't block
  anything), and distance to the nearest confirmed H4 swing level in ATR
  units (`Structure.mqh`, unmodified). Verified via a single-symbol Tester
  smoke run (Tester only reliably syncs its own tested symbol, established
  empirically in Phase 1) — all fields computed sensibly across 144
  snapshots, no crashes. `BridgeLogger.mqh` gained one small generic
  addition (`PostJsonForId`, `LogSignalJson` now delegates to it) — no
  other reused module touched.
- **Bridge**: `POST /log-context`, `GET /context/{symbol}/latest`,
  `GET /context/{symbol}/history`; `POST /risk/calculate` (ports
  `RiskManager::CalculateLotSize` exactly — same formula, same floor-only
  rounding, not reimplemented from scratch); `POST /journal/trades`,
  `PATCH /journal/trades/{id}` (computes `r_multiple` server-side from the
  *original* stored stop-loss, never a since-moved one — not trusted to
  client input), `GET /journal/trades`, `GET /journal/summary`.
- **Dashboard** (`bridge/app/static/dashboard.html`, served at `/`): context
  cards per instrument with a staleness warning, the risk calculator, and
  the journal (entry form with a required-in-spirit rationale field, a
  close-out flow, and a summary strip). Polling refresh (90s) — no
  websockets, per the confirmed design.

**Verified end-to-end**, not just unit-by-unit: the EA's real JSON output
was POSTed against the actual bridge and round-tripped through
`GET /context/EURUSD/latest` correctly. The risk calculator was spot-checked
against **4 known-correct rows from the Phase 1 closeout's own
verification data** (EURUSD, USDJPY, AUDUSD, GBPUSD) — every one matched
exactly (e.g. EURUSD: lot 0.17, risk 0.996% both times). The journal's open
→ close → summary flow was exercised live (a test trade produced the exact
expected R-multiple of 1.00 for a close at 1× the SL distance), then the
test data was deleted from the real tables before finishing.

**One operational note for the user, not resolved here:** a stale bridge
process (running since earlier in the project, before these routes existed)
is still bound to port 8000. The dashboard and new endpoints won't be live
until that process is restarted — deliberately not force-killed by an
unverified PID lookup rather than one tracked from being started this
session; restarting it is a one-line action for the user
(`uvicorn app.main:app --host 127.0.0.1 --port 8000`, after stopping
whatever currently holds that port).
