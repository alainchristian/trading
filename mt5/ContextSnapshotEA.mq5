//+------------------------------------------------------------------+
//| ContextSnapshotEA.mq5                                              |
//| Decision-support phase: read-only, descriptive-only market context |
//| logger. No trading, no predictions, no scores -- computes and logs |
//| D1/H4 trend classification, ATR + volatility regime, session,      |
//| spread, and nearest-S/R-level distance for a fixed list of          |
//| instruments, once per instrument per H1 bar close. Reuses           |
//| Trend.mqh, Volatility.mqh, SessionFilter.mqh, SpreadFilter.mqh,     |
//| Structure.mqh completely unmodified (SpreadFilter for its spread    |
//| *read* only, never its gating logic -- this panel shows spread, it  |
//| doesn't block anything). Everything logged here is either           |
//| descriptive (what the market is currently doing) or mechanical      |
//| (a distance in ATR units) -- never a prediction, per the hard       |
//| constraint recorded in docs/phase-log.md for this phase.            |
//+------------------------------------------------------------------+
#property strict

#include "Include\Trend.mqh"
#include "Include\Volatility.mqh"
#include "Include\SessionFilter.mqh"
#include "Include\SpreadFilter.mqh"
#include "Include\Structure.mqh"
#include "Include\BridgeLogger.mqh"

input string InpSymbols                  = "EURUSD,GBPUSD,USDJPY,AUDUSD,GOLD,US500";
input int    InpEmaFastPeriod            = 50;
input int    InpEmaSlowPeriod            = 200;
input int    InpAdxPeriod                = 14;
input double InpAdxTrendThreshold        = 25.0;
input double InpAdxSidewaysThreshold     = 18.0;
input int    InpAtrPeriodH1              = 14;
input int    InpVolRegimeLookback        = 20;
input int    InpSwingLookback            = 2;
input int    InpLevelSearchBars          = 100;

input int    InpLondonStartHour          = 8;
input int    InpLondonEndHour            = 17;
input int    InpNyStartHour              = 13;
input int    InpNyEndHour                = 22;
input int    InpAsiaStartHour            = 0;
input int    InpAsiaEndHour              = 9;

input string InpBridgeBaseUrl            = "http://127.0.0.1:8000";
input int    InpBridgeTimeoutMs          = 3000;
input string InpLocalLogFile             = "ContextSnapshotEA\\bridge_fallback.log";
input int    InpOnTimerSeconds           = 30;

string         g_symbols[];
CTrend         g_d1_trend[];
CTrend         g_h4_trend[];
CVolatility    g_volatility[];
CStructure     g_structure[];
CSpreadFilter  g_spread[];
CSessionFilter g_session; // symbol-independent, one shared instance
CBridgeLogger  g_logger;
datetime       g_last_h1_bar[];
bool           g_symbol_ready[];

// Attempts to (re)initialize indicators for symbol index i. Live connections
// don't guarantee a freshly-SymbolSelect'd symbol's feed/history is ready in
// time for an indicator handle created in the very same call -- confirmed
// empirically (a live attach failed on AUDUSD specifically with "cannot load
// indicator" error 4805, a transient sync issue, not a real problem with the
// symbol). One symbol's failure must never take down the other five, and a
// transient failure should resolve itself on its own without a manual
// re-attach -- see the OnTimer retry below.
bool InitSymbol(int i)
{
   string s = g_symbols[i];
   if(!SymbolSelect(s, true))
      return false;

   bool ok = true;
   ok = g_d1_trend[i].Init(s, InpEmaFastPeriod, InpEmaSlowPeriod, InpAdxPeriod,
                            InpAdxTrendThreshold, InpAdxSidewaysThreshold, PERIOD_D1) && ok;
   ok = g_h4_trend[i].Init(s, InpEmaFastPeriod, InpEmaSlowPeriod, InpAdxPeriod,
                            InpAdxTrendThreshold, InpAdxSidewaysThreshold, PERIOD_H4) && ok;
   ok = g_volatility[i].Init(s, PERIOD_H1, InpAtrPeriodH1, InpVolRegimeLookback) && ok;
   g_structure[i].Init(s);
   g_spread[i].Init(s, 0); // 0: unused, only GetCurrentSpreadPoints() (the read) is called, never IsAllowed

   if(ok)
      g_last_h1_bar[i] = iTime(s, PERIOD_H1, 0);

   return ok;
}

int OnInit()
{
   int n = StringSplit(InpSymbols, ',', g_symbols);
   if(n <= 0)
   {
      Print("ContextSnapshotEA: no symbols configured.");
      return(INIT_FAILED);
   }

   ArrayResize(g_d1_trend, n);
   ArrayResize(g_h4_trend, n);
   ArrayResize(g_volatility, n);
   ArrayResize(g_structure, n);
   ArrayResize(g_spread, n);
   ArrayResize(g_last_h1_bar, n);
   ArrayResize(g_symbol_ready, n);

   int ready_count = 0;
   for(int i = 0; i < n; i++)
   {
      StringTrimLeft(g_symbols[i]);
      StringTrimRight(g_symbols[i]);

      g_symbol_ready[i] = InitSymbol(i);
      if(g_symbol_ready[i])
         ready_count++;
      else
         PrintFormat("ContextSnapshotEA: WARNING -- %s not ready yet (will retry on timer), skipping for now.", g_symbols[i]);
   }

   g_session.Init(InpLondonStartHour, InpLondonEndHour, InpNyStartHour, InpNyEndHour,
                   InpAsiaStartHour, InpAsiaEndHour, true, true, true, true, true);

   if(!g_logger.Init(InpBridgeBaseUrl, InpLocalLogFile, InpBridgeTimeoutMs))
   {
      Print("ContextSnapshotEA: bridge logger failed to initialize.");
      return(INIT_FAILED);
   }

   if(ready_count == 0)
   {
      Print("ContextSnapshotEA: no symbols ready at startup -- will keep retrying on timer rather than fail outright.");
   }

   EventSetTimer(InpOnTimerSeconds);
   PrintFormat("ContextSnapshotEA initialized, %d of %d symbols ready (others will retry on timer).", ready_count, n);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i = 0; i < ArraySize(g_symbols); i++)
   {
      g_d1_trend[i].Deinit();
      g_h4_trend[i].Deinit();
      g_volatility[i].Deinit();
   }
   g_logger.Deinit();
   Print("ContextSnapshotEA stopped, reason=", reason);
}

void OnTick()
{
   for(int i = 0; i < ArraySize(g_symbols); i++)
   {
      if(!g_symbol_ready[i])
         continue;

      string s = g_symbols[i];
      datetime cur_h1 = iTime(s, PERIOD_H1, 0);
      if(cur_h1 == 0 || cur_h1 == g_last_h1_bar[i])
         continue;
      g_last_h1_bar[i] = cur_h1;
      LogSnapshot(i);
   }
}

void OnTimer()
{
   GlobalVariablesFlush();

   // Retry any symbol that wasn't ready at OnInit (or has since dropped out)
   // -- a transient live-feed sync delay resolves itself without needing a
   // manual re-attach.
   for(int i = 0; i < ArraySize(g_symbols); i++)
   {
      if(g_symbol_ready[i])
         continue;
      if(InitSymbol(i))
      {
         g_symbol_ready[i] = true;
         PrintFormat("ContextSnapshotEA: %s became ready.", g_symbols[i]);
      }
   }
}

// Distance (in ATR units) from the current close to whichever of the
// nearest confirmed H4 swing high / swing low is closer -- a plain
// mechanical measurement, not an interpretation of what it means.
double NearestLevelDistanceAtr(int idx, string s, double atr)
{
   if(atr <= 0)
      return 0.0;

   double last_close = iClose(s, PERIOD_H1, 1);
   double best_dist = -1.0;

   SwingPoint sp_high, sp_low;
   if(g_structure[idx].FindLastSwingHigh(PERIOD_H4, InpSwingLookback, InpSwingLookback + 1, InpLevelSearchBars, sp_high))
   {
      double d = MathAbs(last_close - sp_high.price);
      if(best_dist < 0 || d < best_dist) best_dist = d;
   }
   if(g_structure[idx].FindLastSwingLow(PERIOD_H4, InpSwingLookback, InpSwingLookback + 1, InpLevelSearchBars, sp_low))
   {
      double d = MathAbs(last_close - sp_low.price);
      if(best_dist < 0 || d < best_dist) best_dist = d;
   }

   return (best_dist < 0) ? 0.0 : (best_dist / atr);
}

void LogSnapshot(int idx)
{
   string s = g_symbols[idx];
   datetime snapshot_time = iTime(s, PERIOD_H1, 1);

   ENUM_TREND d1 = g_d1_trend[idx].Classify();
   ENUM_TREND h4 = g_h4_trend[idx].Classify();
   double atr = g_volatility[idx].GetATR(1);
   ENUM_VOL_REGIME regime = g_volatility[idx].GetRegime(1);
   string session = g_session.GetSessionLabel(snapshot_time);
   long spread = g_spread[idx].GetCurrentSpreadPoints();
   double level_dist_atr = NearestLevelDistanceAtr(idx, s, atr);

   string json = "{";
   json += "\"symbol\":" + g_logger.Json(s) + ",";
   json += "\"snapshot_time\":" + g_logger.Json(g_logger.IsoTime(snapshot_time)) + ",";
   json += "\"d1_trend\":" + g_logger.Json(g_d1_trend[idx].ToString(d1)) + ",";
   json += "\"h4_trend\":" + g_logger.Json(g_h4_trend[idx].ToString(h4)) + ",";
   json += "\"atr_value\":" + g_logger.Num(atr) + ",";
   json += "\"volatility_regime\":" + g_logger.Json(g_volatility[idx].RegimeToString(regime)) + ",";
   json += "\"session\":" + g_logger.Json(session) + ",";
   json += "\"spread\":" + g_logger.Num((double)spread) + ",";
   json += "\"nearest_level_distance_atr\":" + g_logger.Num(level_dist_atr);
   json += "}";

   g_logger.PostJsonForId("/log-context", json);
}
//+------------------------------------------------------------------+
