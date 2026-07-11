//+------------------------------------------------------------------+
//| Phase1EA.mq5                                                       |
//| Phase 1: rule-based EA (multi-timeframe trend, entry confluence,   |
//| ATR stops, position sizing, partial TPs, trailing stop, hard risk  |
//| limits). Trades correctly in Strategy Tester with zero live        |
//| dependency on the Python bridge -- the bridge is used only for     |
//| logging (every signal, taken or rejected), never for a trading     |
//| decision. See docs/phase1-instructions.md for the full spec.       |
//+------------------------------------------------------------------+
#property copyright "Trading Platform - Phase 1"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include "Include\Trend.mqh"
#include "Include\Structure.mqh"
#include "Include\Momentum.mqh"
#include "Include\Volatility.mqh"
#include "Include\EntryLogic.mqh"
#include "Include\RiskManager.mqh"
#include "Include\ExitManager.mqh"
#include "Include\SessionFilter.mqh"
#include "Include\SpreadFilter.mqh"
#include "Include\NewsFilter.mqh"
#include "Include\BridgeLogger.mqh"

//--- Identity ---------------------------------------------------------------
input long   InpMagicNumber              = 20260101;

//--- Risk / sizing / SL ------------------------------------------------------
input double InpRiskPercent              = 1.0;    // % of balance risked per trade (0.5-2.0 recommended)
input ENUM_SL_MODE InpSLMode             = SL_MODE_ATR;
input double InpATRMultiplier            = 1.75;   // ATR multiplier for ATR-mode SL
input int    InpSwingLookback            = 2;       // bars each side for a confirmed swing point
input int    InpSwingBufferPoints        = 50;      // buffer beyond the swing point for swing-mode SL
input double InpDailyLossLimitPercent    = 3.0;
input double InpWeeklyLossLimitPercent   = 6.0;
input double InpMaxDrawdownPercent       = 10.0;
input int    InpMaxOpenTrades            = 1;

//--- Entry confluence ---------------------------------------------------------
input bool   InpAllowWeakTrend           = false;   // include TREND_WEAK_* as directional, not just STRONG_*
input double InpZoneToleranceATRMult     = 0.5;      // how close to a zone counts as "at" it, in ATR
input double InpImpulseATRMult           = 1.5;      // min body size (x ATR) to count as an impulse candle
input double InpRSIThreshold             = 40.0;     // RSI must be below this (buy) / above 100-this (sell), and recovering
input double InpPinWickRatio             = 2.0;      // pin-bar wick must be >= this x body
input double InpPinUpperWickMaxRatio     = 0.25;     // opposite wick must be <= this x range
input double InpPinBodyMaxRatio          = 0.33;     // body must be <= this x range
input double InpPinCloseZone             = 0.6;       // close must be in this fraction of the range (near the favorable extreme)
input bool   InpRequireVolumeIncrease    = true;
input ENUM_CONFLUENCE_MODE InpConfluenceMode = CONFLUENCE_STRICT_SAME_BAR; // see docs/phase-log.md Step 2 (Phase 1 addendum)
input int    InpRollingWindowBars        = 3;         // only used when InpConfluenceMode = ROLLING_WINDOW
input bool   InpBypassConfluence         = false;     // Step 4 no-confluence-filter benchmark -- see docs/phase-log.md

input int    InpEmaFastPeriod            = 50;
input int    InpEmaSlowPeriod            = 200;
input int    InpAdxPeriod                = 14;
input double InpAdxTrendThreshold        = 25.0;    // above this = STRONG trend
input double InpAdxSidewaysThreshold     = 18.0;    // at or below this = genuinely SIDEWAYS/ranging

input int    InpRsiPeriod                = 14;
input int    InpMacdFast                 = 12;
input int    InpMacdSlow                 = 26;
input int    InpMacdSignal               = 9;

input int    InpAtrPeriodH1              = 14;
input int    InpVolRegimeLookback        = 20;

//--- Exit management -----------------------------------------------------------
input double InpTP1Fraction              = 0.30;
input double InpTP2Fraction              = 0.30;     // leaves 1.0 - TP1 - TP2 (default 40%) to trail
input ENUM_TRAIL_MODE InpTrailMode       = TRAIL_MODE_ATR;
input double InpAtrTrailMultiplier       = 1.5;
input int    InpStructureTrailLookback   = 2;
input int    InpStructureTrailBufferPoints = 30;

//--- Session filter (broker SERVER time -- see SessionFilter.mqh) --------------
input int    InpLondonStartHour          = 8;
input int    InpLondonEndHour            = 17;
input int    InpNyStartHour              = 13;
input int    InpNyEndHour                = 22;
input int    InpAsiaStartHour            = 0;
input int    InpAsiaEndHour              = 9;
input bool   InpAllowLondon              = true;
input bool   InpAllowNy                  = true;
input bool   InpAllowOverlap             = true;
input bool   InpAllowAsia                = false;
input bool   InpAllowOffHours            = false;

//--- Spread filter ---------------------------------------------------------------
input long   InpMaxSpreadPoints          = 30;

//--- News filter (togglable, see Section 0.3 of the phase doc) -------------------
input bool   InpUseNewsFilter            = true;
input int    InpNewsBufferMinutesBefore  = 30;
input int    InpNewsBufferMinutesAfter   = 30;

//--- Bridge ------------------------------------------------------------------------
input string InpBridgeBaseUrl            = "http://127.0.0.1:8000";
input int    InpBridgeTimeoutMs          = 3000;
input string InpLocalLogFile             = "Phase1EA\\bridge_fallback.log";
input int    InpOnTimerSeconds           = 30;

//--- Module instances ----------------------------------------------------------------
CTrend         g_trend;
CStructure     g_structure;
CMomentum      g_momentum;
CVolatility    g_volatility;
CEntryLogic    g_entry;
CRiskManager   g_risk;
CExitManager   g_exit;
CSessionFilter g_session;
CSpreadFilter  g_spread;
CNewsFilter    g_news;
CBridgeLogger  g_logger;
CTrade         g_trade;

datetime g_last_h1_bar_time = 0;

int OnInit()
{
   if(_Symbol != "EURUSD")
      Print("Phase1EA: WARNING -- attached to ", _Symbol, ", but Phase 1 was validated against EURUSD only.");

   g_structure.Init(_Symbol);

   bool ok = true;
   ok = g_trend.Init(_Symbol, InpEmaFastPeriod, InpEmaSlowPeriod, InpAdxPeriod, InpAdxTrendThreshold, InpAdxSidewaysThreshold) && ok;
   ok = g_volatility.Init(_Symbol, PERIOD_H1, InpAtrPeriodH1, InpVolRegimeLookback) && ok;
   ok = g_momentum.Init(_Symbol, InpRsiPeriod, InpMacdFast, InpMacdSlow, InpMacdSignal, InpAdxPeriod) && ok;
   ok = g_entry.Init(_Symbol, InpAllowWeakTrend, InpSwingLookback, InpZoneToleranceATRMult, InpImpulseATRMult,
                      InpRSIThreshold, InpPinWickRatio, InpPinUpperWickMaxRatio, InpPinBodyMaxRatio,
                      InpPinCloseZone, InpRequireVolumeIncrease, InpConfluenceMode, InpRollingWindowBars) && ok;

   double swing_buffer_price = InpSwingBufferPoints * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   ok = g_risk.Init(_Symbol, InpMagicNumber, InpRiskPercent, InpSLMode, InpATRMultiplier,
                     InpSwingLookback, swing_buffer_price, InpDailyLossLimitPercent,
                     InpWeeklyLossLimitPercent, InpMaxDrawdownPercent, InpMaxOpenTrades) && ok;

   double structure_trail_buffer_price = InpStructureTrailBufferPoints * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   ok = g_exit.Init(_Symbol, InpMagicNumber, InpTP1Fraction, InpTP2Fraction, InpTrailMode,
                     InpAtrTrailMultiplier, InpStructureTrailLookback, structure_trail_buffer_price) && ok;

   g_session.Init(InpLondonStartHour, InpLondonEndHour, InpNyStartHour, InpNyEndHour,
                   InpAsiaStartHour, InpAsiaEndHour, InpAllowLondon, InpAllowNy,
                   InpAllowOverlap, InpAllowAsia, InpAllowOffHours);

   g_spread.Init(_Symbol, InpMaxSpreadPoints);
   ok = g_news.Init(_Symbol, InpUseNewsFilter, InpNewsBufferMinutesBefore, InpNewsBufferMinutesAfter) && ok;
   ok = g_logger.Init(InpBridgeBaseUrl, InpLocalLogFile, InpBridgeTimeoutMs) && ok;

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   if(!ok)
   {
      Print("Phase1EA: one or more modules failed to initialize (see prior log lines).");
      return(INIT_FAILED);
   }

   // Reconciliation pass: clean up P1_* GlobalVariables left over from a
   // prior run/restart whose ticket no longer maps to a live position --
   // also fixes Strategy Tester ticket numbers resetting to 1 across
   // separate test runs (otherwise a fresh run's ticket 1 would read stale
   // state from a previous run).
   g_risk.ReconcileGlobals();

   // Mark the currently-forming H1 bar so it's never mistaken for "new" on
   // the very first tick.
   g_last_h1_bar_time = iTime(_Symbol, PERIOD_H1, 0);

   EventSetTimer(InpOnTimerSeconds);

   Print("Phase1EA initialized on ", _Symbol, ", magic=", InpMagicNumber);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   GlobalVariablesFlush();

   g_trend.Deinit();
   g_volatility.Deinit();
   g_momentum.Deinit();
   g_entry.Deinit();
   g_logger.Deinit();

   Print("Phase1EA stopped, reason=", reason);
}

void OnTick()
{
   // Daily/weekly rollover detection must live here (TimeCurrent()-driven),
   // not in OnTimer -- simulated time in Strategy Tester doesn't track
   // wall-clock seconds, so a wall-clock timer has no fixed relationship to
   // a simulated calendar-day boundary.
   g_risk.CheckRollover(g_logger);

   // Exit management every tick: MFE/MAE tracking, partial TP/breakeven,
   // trailing stop -- for all of this EA's currently open positions.
   g_exit.ManageOpenPositions(g_risk, g_structure, g_volatility, g_logger);

   // Separately detect any position that fully closed since the last tick
   // (ManageOpenPositions can't see it -- it no longer appears in
   // PositionsTotal()) and finalize its trades row.
   g_exit.DetectAndFinalizeClosedPositions(g_risk, g_logger);

   g_risk.UpdateEquityPeak();

   // Entry evaluation only on a new H1 bar close, never mid-bar.
   datetime current_h1_bar = iTime(_Symbol, PERIOD_H1, 0);
   if(current_h1_bar != g_last_h1_bar_time)
   {
      g_last_h1_bar_time = current_h1_bar;
      EvaluateAndMaybeEnter();
   }
}

void OnTimer()
{
   // Best-effort only -- nothing correctness-critical lives here, since
   // whether OnTimer even fires in non-visual Strategy Tester mode is
   // unconfirmed for this build (verify empirically before relying on it).
   GlobalVariablesFlush();
}

void EvaluateAndMaybeEnter()
{
   Signal sig = g_entry.Evaluate(g_trend, g_structure, g_momentum, g_volatility);
   sig.session = g_session.GetSessionLabel(sig.signal_time);

   bool is_buy = (sig.direction == "buy");

   // Compute proposed SL/TP for logging purposes regardless of outcome --
   // maximizes negative-example richness for later ML training at
   // near-zero extra cost.
   double sl = 0.0;
   bool sl_ok = (sig.atr_value > 0) && g_risk.ComputeSL(is_buy, sig.proposed_entry, sig.atr_value, g_structure, sl);
   if(sl_ok)
   {
      double tp1, tp2;
      g_risk.ComputeTPs(is_buy, sig.proposed_entry, sl, tp1, tp2);
      sig.proposed_sl  = sl;
      sig.proposed_tp1 = tp1;
      sig.proposed_tp2 = tp2;
   }

   sig.risk_percent = InpRiskPercent;

   // Gate chain, in fixed order, only attempted if all 6 confluence checks
   // passed (confluence failures already set rejection_reason and take
   // priority since they run first). InpBypassConfluence is the Phase 1
   // addendum Step 4 no-confluence-filter benchmark: same signal timing
   // (direction still comes from the raw D1 EMA relationship) and identical
   // session/spread/news/risk gates and exit management, but the six-check
   // gate itself is skipped -- checks 1-6 are still evaluated and logged
   // exactly as normal so the benchmark run remains comparable bar-for-bar.
   double lot = 0.0;
   string reject_reason = "";
   bool confluence_pass = InpBypassConfluence ? true : sig.all_checks_passed;
   bool ok = confluence_pass;

   if(ok) ok = g_session.IsAllowed(sig.signal_time, reject_reason);
   if(ok) ok = g_spread.IsAllowed(reject_reason);
   if(ok) ok = g_news.IsAllowed(sig.signal_time, reject_reason);
   if(ok) ok = g_risk.PassesRiskGates(reject_reason);

   if(ok && sl_ok)
      ok = g_risk.CalculateLotSize(MathAbs(sig.proposed_entry - sl), lot, reject_reason);
   else if(ok && !sl_ok)
   {
      ok = false;
      reject_reason = "invalid_sl_for_sizing";
   }

   sig.lot_size = lot;
   sig.taken    = ok;
   sig.rejection_reason = ok ? "" : (confluence_pass ? reject_reason : sig.rejection_reason);

   long signal_id = g_logger.LogSignal(sig);

   if(!ok)
      return;

   OpenPosition(sig, lot, sl, signal_id);
}

void OpenPosition(Signal &sig, double lot, double sl, long signal_id)
{
   bool is_buy = (sig.direction == "buy");
   double price = is_buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl_norm = NormalizeDouble(sl, digits);

   string comment = "P1|" + IntegerToString(signal_id);

   // No broker-side TP is set: partial TPs are managed manually by
   // ExitManager against the ORIGINAL R-distance, not a fixed order-level TP.
   bool sent = is_buy
      ? g_trade.Buy(lot, _Symbol, price, sl_norm, 0.0, comment)
      : g_trade.Sell(lot, _Symbol, price, sl_norm, 0.0, comment);

   if(!sent)
   {
      PrintFormat("Phase1EA: order send failed for signal %d, retcode=%d", signal_id, g_trade.ResultRetcode());
      return;
   }

   ulong deal_ticket = g_trade.ResultDeal();
   HistoryDealSelect(deal_ticket);
   ulong position_ticket = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
   if(position_ticket == 0)
      position_ticket = g_trade.ResultOrder();

   double open_price = g_trade.ResultPrice();
   datetime open_time = TimeCurrent();

   g_risk.SeedPositionState(position_ticket, signal_id, sl_norm, lot);
   g_logger.LogTradeOpen("phase1_confluence", signal_id, position_ticket, _Symbol, sig.direction, open_time,
                          open_price, sl_norm, sig.proposed_tp1, sig.proposed_tp2, lot);
}
//+------------------------------------------------------------------+
