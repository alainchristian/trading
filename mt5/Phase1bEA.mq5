//+------------------------------------------------------------------+
//| Phase1bEA.mq5                                                      |
//| Phase 1b: mean-reversion hypothesis. Reuses Phase 1's verified      |
//| infrastructure as-is (bridge, RiskManager, SessionFilter,           |
//| SpreadFilter, NewsFilter, BridgeLogger, Trend/Structure/Momentum/   |
//| Volatility modules) and replaces only the entry/exit logic with a   |
//| different market idea: overextended price in range-bound            |
//| conditions tends to revert toward its recent mean -- close to the   |
//| opposite bet of Phase 1's trend-following premise. See               |
//| docs/phase-log.md ("Phase 1b") for the full spec and the four       |
//| decisions confirmed with the user before this was built (H4 regime  |
//| timeframe, 20-period/2.0 SD H1 bands, 48-bar holding cap, the       |
//| strategy_variant schema approach).                                  |
//+------------------------------------------------------------------+
#property copyright "Trading Platform - Phase 1b"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include "Include\Trend.mqh"
#include "Include\Structure.mqh"
#include "Include\Momentum.mqh"
#include "Include\Volatility.mqh"
#include "Include\MeanReversionEntry.mqh"
#include "Include\MeanReversionExit.mqh"
#include "Include\RiskManager.mqh"
#include "Include\SessionFilter.mqh"
#include "Include\SpreadFilter.mqh"
#include "Include\NewsFilter.mqh"
#include "Include\BridgeLogger.mqh"

enum ENUM_MR_SL_MODE
{
   MR_SL_ATR,          // default: entry -/+ ATR*multiplier (reuses RiskManager::ComputeATRSL as-is)
   MR_SL_BAND_EXTREME  // alternative: beyond the touched band extreme + a small buffer
};

//--- Identity ---------------------------------------------------------------
input long   InpMagicNumber              = 20260102; // distinct from Phase 1's 20260101

//--- Risk / sizing / SL (RiskManager reused as-is) ---------------------------
input double InpRiskPercent              = 1.0;
input ENUM_MR_SL_MODE InpMRSLMode        = MR_SL_ATR;    // A/B via input, same pattern as Phase 1's trailing test
input double InpATRMultiplier            = 1.75;         // used when InpMRSLMode = MR_SL_ATR
input double InpBandSLBufferATRMult      = 0.5;           // used when InpMRSLMode = MR_SL_BAND_EXTREME
input double InpDailyLossLimitPercent    = 3.0;
input double InpWeeklyLossLimitPercent   = 6.0;
input double InpMaxDrawdownPercent       = 10.0;
input int    InpMaxOpenTrades            = 1;

//--- Mean-reversion entry (user-confirmed decisions) --------------------------
input int    InpSmaPeriod                = 20;    // confirmed: 20-period SMA
input double InpSmaSDMultiplier          = 2.0;    // confirmed: +/- 2.0 SD bands, H1
input double InpRSIThreshold             = 40.0;   // reused Phase 1 default, see MeanReversionEntry.mqh comment on why the shape (not just the number) differs
input double InpPinWickRatio             = 2.0;
input double InpPinUpperWickMaxRatio     = 0.25;
input double InpPinBodyMaxRatio          = 0.33;
input double InpPinCloseZone             = 0.6;
input int    InpSwingLookback            = 2;
input int    InpLevelSearchBars          = 100;
input int    InpLevelCrossingLookbackBars = 48;
input int    InpLevelMaxCrossings        = 2;
input double InpLevelToleranceATRMult    = 0.5;
input bool   InpBypassMeanReversion      = false; // benchmark: skip the 5-check gate, keep everything else identical

//--- Regime filter (H4, confirmed) --------------------------------------------
input int    InpEmaFastPeriod            = 50;
input int    InpEmaSlowPeriod            = 200;
input int    InpAdxPeriod                = 14;
input double InpAdxTrendThreshold        = 25.0;
input double InpAdxSidewaysThreshold     = 18.0;  // reused unmodified from Phase 1 -- see user-confirmed decision

input int    InpRsiPeriod                = 14;
input int    InpMacdFast                 = 12;
input int    InpMacdSlow                 = 26;
input int    InpMacdSignal               = 9;

input int    InpAtrPeriodH1              = 14;
input int    InpVolRegimeLookback        = 20;

//--- Exit management -----------------------------------------------------------
input int    InpHoldingCapBars           = 48;    // confirmed holding-period cap
input double InpBreakevenTriggerR        = 0.5;   // move SL to breakeven after this much favorable R

//--- Session filter (broker SERVER time) --------------------------------------
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

//--- Spread filter -------------------------------------------------------------
input long   InpMaxSpreadPoints          = 30;

//--- News filter ----------------------------------------------------------------
input bool   InpUseNewsFilter            = true;
input int    InpNewsBufferMinutesBefore  = 30;
input int    InpNewsBufferMinutesAfter   = 30;

//--- Bridge ----------------------------------------------------------------------
input string InpBridgeBaseUrl            = "http://127.0.0.1:8000";
input int    InpBridgeTimeoutMs          = 3000;
input string InpLocalLogFile             = "Phase1bEA\\bridge_fallback.log";
input int    InpOnTimerSeconds           = 30;

//--- Module instances --------------------------------------------------------------
CTrend              g_h4_regime;   // Trend.mqh, Init'd on H4 -- see user-confirmed decision
CStructure          g_structure;
CMomentum           g_momentum;
CVolatility         g_volatility;
CMeanReversionEntry g_mr_entry;
CMeanReversionExit  g_mr_exit;
CRiskManager        g_risk;
CSessionFilter      g_session;
CSpreadFilter       g_spread;
CNewsFilter         g_news;
CBridgeLogger       g_logger;
CTrade              g_trade;

const string STRATEGY_VARIANT = "phase1b_mean_reversion";

datetime g_last_h1_bar_time = 0;

int OnInit()
{
   g_structure.Init(_Symbol);

   bool ok = true;
   ok = g_h4_regime.Init(_Symbol, InpEmaFastPeriod, InpEmaSlowPeriod, InpAdxPeriod,
                          InpAdxTrendThreshold, InpAdxSidewaysThreshold, PERIOD_H4) && ok;
   ok = g_volatility.Init(_Symbol, PERIOD_H1, InpAtrPeriodH1, InpVolRegimeLookback) && ok;
   ok = g_momentum.Init(_Symbol, InpRsiPeriod, InpMacdFast, InpMacdSlow, InpMacdSignal, InpAdxPeriod) && ok;
   ok = g_mr_entry.Init(_Symbol, InpSmaPeriod, InpSmaSDMultiplier, InpRSIThreshold,
                         InpSwingLookback, InpLevelSearchBars, InpLevelCrossingLookbackBars,
                         InpLevelMaxCrossings, InpLevelToleranceATRMult,
                         InpPinWickRatio, InpPinUpperWickMaxRatio, InpPinBodyMaxRatio, InpPinCloseZone) && ok;

   ok = g_risk.Init(_Symbol, InpMagicNumber, InpRiskPercent, SL_MODE_ATR, InpATRMultiplier,
                     InpSwingLookback, 0.0, InpDailyLossLimitPercent,
                     InpWeeklyLossLimitPercent, InpMaxDrawdownPercent, InpMaxOpenTrades) && ok;

   ok = g_mr_exit.Init(_Symbol, InpMagicNumber, InpSmaPeriod, InpHoldingCapBars, InpBreakevenTriggerR) && ok;

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
      Print("Phase1bEA: one or more modules failed to initialize (see prior log lines).");
      return(INIT_FAILED);
   }

   // Reuses RiskManager's GlobalVariable reconciliation as-is -- P1_* prefix
   // is shared/generic, not Phase-1-specific.
   g_risk.ReconcileGlobals();

   g_last_h1_bar_time = iTime(_Symbol, PERIOD_H1, 0);

   EventSetTimer(InpOnTimerSeconds);

   Print("Phase1bEA initialized on ", _Symbol, ", magic=", InpMagicNumber);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   GlobalVariablesFlush();

   g_h4_regime.Deinit();
   g_volatility.Deinit();
   g_momentum.Deinit();
   g_mr_entry.Deinit();
   g_mr_exit.Deinit();
   g_logger.Deinit();

   Print("Phase1bEA stopped, reason=", reason);
}

void OnTick()
{
   g_risk.CheckRollover(g_logger);

   g_mr_exit.ManageOpenPositions(g_risk, g_logger);
   g_mr_exit.DetectAndFinalizeClosedPositions(g_risk, g_logger);

   g_risk.UpdateEquityPeak();

   datetime current_h1_bar = iTime(_Symbol, PERIOD_H1, 0);
   if(current_h1_bar != g_last_h1_bar_time)
   {
      g_last_h1_bar_time = current_h1_bar;
      EvaluateAndMaybeEnter();
   }
}

void OnTimer()
{
   GlobalVariablesFlush();
}

// ATR-based SL: reuses RiskManager::ComputeATRSL directly, unmodified.
// Band-extreme SL: beyond whichever band was touched, plus a small ATR-based
// buffer so the stop doesn't sit exactly on the same line the entry logic
// just touched (immediate noise would stop it out instantly otherwise).
bool ComputeMRSL(bool is_buy, MRSignal &sig, double &sl_out)
{
   if(InpMRSLMode == MR_SL_ATR)
   {
      if(sig.atr_value <= 0) return false;
      sl_out = g_risk.ComputeATRSL(is_buy, sig.proposed_entry, sig.atr_value);
      return (sl_out > 0);
   }

   double buffer = (sig.atr_value > 0) ? sig.atr_value * InpBandSLBufferATRMult : 0.0;
   sl_out = is_buy ? (sig.band_lower - buffer) : (sig.band_upper + buffer);
   return (sl_out > 0);
}

void EvaluateAndMaybeEnter()
{
   MRSignal sig = g_mr_entry.Evaluate(g_h4_regime, g_structure, g_momentum, g_volatility);
   sig.session = g_session.GetSessionLabel(sig.signal_time);

   bool is_buy = (sig.direction == "buy");

   double sl = 0.0;
   bool sl_ok = ComputeMRSL(is_buy, sig, sl);
   if(sl_ok)
      sig.proposed_sl = sl;

   sig.risk_percent = InpRiskPercent;

   // InpBypassMeanReversion is this hypothesis's benchmark, matching Phase
   // 1's InpBypassConfluence pattern exactly: checks 1-5 still evaluated and
   // logged, only the gate itself is skipped. Same signal timing, same
   // session/spread/news/risk gates, same exit management.
   double lot = 0.0;
   string reject_reason = "";
   bool checks_pass = InpBypassMeanReversion ? true : sig.all_checks_passed;
   bool ok = checks_pass;

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
   sig.rejection_reason = ok ? "" : (checks_pass ? reject_reason : sig.rejection_reason);

   long signal_id = LogMRSignal(sig);

   if(!ok)
      return;

   OpenPosition(sig, lot, sl, signal_id);
}

// Builds the /log-signal JSON directly (not via BridgeLogger::LogSignal,
// which is tied to Phase 1's own Signal struct/field names) and posts it
// through the new generic LogSignalJson, reusing all of BridgeLogger's
// request/fallback-log machinery unchanged. Maps onto the SAME signals
// table columns Phase 1 uses -- no schema change beyond strategy_variant
// was needed, per the closeout inventory. d1_trend/h4_setup_valid are
// generic string/bool columns repurposed here (H4 regime label / band-touch
// flag) rather than left NULL, since they have no CHECK constraint tying
// them to Phase 1's specific meaning.
long LogMRSignal(MRSignal &sig)
{
   string json = "{";
   json += "\"strategy_variant\":" + g_logger.Json(STRATEGY_VARIANT) + ",";
   json += "\"symbol\":" + g_logger.Json(sig.symbol) + ",";
   json += "\"signal_time\":" + g_logger.Json(g_logger.IsoTime(sig.signal_time)) + ",";
   json += "\"direction\":" + g_logger.Json(sig.direction) + ",";
   json += "\"d1_trend\":" + g_logger.Json(sig.h4_regime) + ",";
   json += "\"h4_setup_valid\":" + g_logger.Bool(sig.check2_band_touch_pass) + ",";
   json += "\"h1_entry_trigger\":" + g_logger.JsonOrNull(sig.h1_entry_trigger) + ",";
   json += "\"atr_value\":" + g_logger.Num(sig.atr_value) + ",";
   json += "\"proposed_entry\":" + g_logger.Num(sig.proposed_entry) + ",";
   json += "\"proposed_sl\":" + g_logger.Num(sig.proposed_sl) + ",";
   json += "\"proposed_tp1\":" + g_logger.Num(sig.proposed_tp) + ",";
   json += "\"proposed_tp2\":" + g_logger.Num(0.0) + ",";
   json += "\"risk_percent\":" + g_logger.Num(sig.risk_percent) + ",";
   json += "\"lot_size\":" + g_logger.Num(sig.lot_size) + ",";
   json += "\"spread_at_signal\":" + g_logger.Num(sig.spread_at_signal) + ",";
   json += "\"session\":" + g_logger.JsonOrNull(sig.session) + ",";
   json += "\"taken\":" + g_logger.Bool(sig.taken) + ",";
   json += "\"rejection_reason\":" + g_logger.JsonOrNull(sig.rejection_reason) + ",";
   json += "\"features\":" + (StringLen(sig.features_json) > 0 ? sig.features_json : "null");
   json += "}";

   return g_logger.LogSignalJson(json);
}

void OpenPosition(MRSignal &sig, double lot, double sl, long signal_id)
{
   bool is_buy = (sig.direction == "buy");
   double price = is_buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl_norm = NormalizeDouble(sl, digits);

   string comment = "P1b|" + IntegerToString(signal_id);

   // No broker-side TP: the target is the band's moving mean, monitored and
   // closed manually by MeanReversionExit every tick.
   bool sent = is_buy
      ? g_trade.Buy(lot, _Symbol, price, sl_norm, 0.0, comment)
      : g_trade.Sell(lot, _Symbol, price, sl_norm, 0.0, comment);

   if(!sent)
   {
      PrintFormat("Phase1bEA: order send failed for signal %d, retcode=%d", signal_id, g_trade.ResultRetcode());
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
   g_logger.LogTradeOpen(STRATEGY_VARIANT, signal_id, position_ticket, _Symbol, sig.direction, open_time,
                          open_price, sl_norm, sig.proposed_tp, 0.0, lot);
}
//+------------------------------------------------------------------+
