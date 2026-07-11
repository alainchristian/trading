//+------------------------------------------------------------------+
//| MarketCharacterDumpEA.mq5                                          |
//| Read-only market-character logger for the w3/w4/w5 comparison       |
//| check. No entries, no exits, no risk management -- not a backtest   |
//| of any strategy. Reuses Trend.mqh (D1 instance matching Phase 1's   |
//| own usage, H4 instance matching Phase 1b's) and Volatility.mqh      |
//| (H1 ATR, matching both) completely unmodified. Logs real daily OHLC |
//| once per day and D1/H4 regime classification + H1 ATR + spread      |
//| once per H1 bar, to a plain file -- no bridge/Postgres involvement. |
//+------------------------------------------------------------------+
#property strict

#include "Include\Trend.mqh"
#include "Include\Volatility.mqh"

input int    InpEmaFastPeriod        = 50;
input int    InpEmaSlowPeriod        = 200;
input int    InpAdxPeriod            = 14;
input double InpAdxTrendThreshold    = 25.0;
input double InpAdxSidewaysThreshold = 18.0;
input int    InpAtrPeriodH1          = 14;
input string InpLogFile              = "MarketCharacter\\dump.log";

CTrend      g_d1_trend;
CTrend      g_h4_trend;
CVolatility g_vol_h1;

int      g_file_handle = INVALID_HANDLE;
datetime g_last_h1_bar = 0;
datetime g_last_d1_bar = 0;

int OnInit()
{
   bool ok = true;
   ok = g_d1_trend.Init(_Symbol, InpEmaFastPeriod, InpEmaSlowPeriod, InpAdxPeriod,
                         InpAdxTrendThreshold, InpAdxSidewaysThreshold, PERIOD_D1) && ok;
   ok = g_h4_trend.Init(_Symbol, InpEmaFastPeriod, InpEmaSlowPeriod, InpAdxPeriod,
                         InpAdxTrendThreshold, InpAdxSidewaysThreshold, PERIOD_H4) && ok;
   ok = g_vol_h1.Init(_Symbol, PERIOD_H1, InpAtrPeriodH1, 20) && ok;
   if(!ok)
   {
      Print("MarketCharacterDumpEA: module init failed.");
      return(INIT_FAILED);
   }

   g_file_handle = FileOpen(InpLogFile, FILE_WRITE | FILE_READ | FILE_TXT);
   if(g_file_handle == INVALID_HANDLE)
   {
      Print("MarketCharacterDumpEA: could not open log file, error ", GetLastError());
      return(INIT_FAILED);
   }
   FileSeek(g_file_handle, 0, SEEK_END);

   g_last_h1_bar = iTime(_Symbol, PERIOD_H1, 0);
   g_last_d1_bar = iTime(_Symbol, PERIOD_D1, 0);

   Print("MarketCharacterDumpEA initialized on ", _Symbol);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_file_handle != INVALID_HANDLE) { FileClose(g_file_handle); g_file_handle = INVALID_HANDLE; }
   g_d1_trend.Deinit();
   g_h4_trend.Deinit();
   g_vol_h1.Deinit();
}

void OnTick()
{
   datetime cur_h1 = iTime(_Symbol, PERIOD_H1, 0);
   if(cur_h1 != g_last_h1_bar)
   {
      g_last_h1_bar = cur_h1;
      LogH1Bar();
   }

   datetime cur_d1 = iTime(_Symbol, PERIOD_D1, 0);
   if(cur_d1 != g_last_d1_bar)
   {
      g_last_d1_bar = cur_d1;
      LogDailyBar();
   }
}

void LogH1Bar()
{
   ENUM_TREND d1 = g_d1_trend.Classify();
   ENUM_TREND h4 = g_h4_trend.Classify();
   double atr = g_vol_h1.GetATR(1);
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   datetime t = iTime(_Symbol, PERIOD_H1, 1);

   string line = StringFormat("H1|%s|%s|%s|%s|%.8f|%.2f",
                               _Symbol, TimeToString(t, TIME_DATE | TIME_MINUTES),
                               g_d1_trend.ToString(d1), g_h4_trend.ToString(h4), atr, spread);
   FileWrite(g_file_handle, line);
}

void LogDailyBar()
{
   double o = iOpen(_Symbol, PERIOD_D1, 1);
   double h = iHigh(_Symbol, PERIOD_D1, 1);
   double l = iLow(_Symbol, PERIOD_D1, 1);
   double c = iClose(_Symbol, PERIOD_D1, 1);
   datetime t = iTime(_Symbol, PERIOD_D1, 1);

   string line = StringFormat("DAILY|%s|%s|%.8f|%.8f|%.8f|%.8f",
                               _Symbol, TimeToString(t, TIME_DATE), o, h, l, c);
   FileWrite(g_file_handle, line);
}
//+------------------------------------------------------------------+
