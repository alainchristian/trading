//+------------------------------------------------------------------+
//| MLFeatureDumpEA.mq5                                                |
//| Read-only price/indicator export for the ML escalation test. No    |
//| entries, no exits, no risk management -- not a backtest of any     |
//| strategy, no touch to any shared/live-strategy module (Trend.mqh,  |
//| Momentum.mqh, Volatility.mqh are neither included nor modified --  |
//| this calls MT5's own indicator functions directly). Logs real H1   |
//| OHLCV plus ATR(H1)/RSI(H1)/RSI(H4)/ADX(H1)/spread per closed H1     |
//| bar. All *other* features (moving averages, %B, lags, rolling vol, |
//| cross-instrument returns, calendar) are computed fresh in Python    |
//| from this export -- only the three baseline indicator values need  |
//| to match the first signal-detection test's exact computation for   |
//| comparability.                                                     |
//+------------------------------------------------------------------+
#property strict

input int    InpAtrPeriod = 14;
input int    InpRsiPeriod = 14;
input int    InpAdxPeriod = 14;
input string InpLogFile   = "MLFeatureDump\\dump.log";

int g_atr_handle  = INVALID_HANDLE;
int g_rsi_h1_handle = INVALID_HANDLE;
int g_rsi_h4_handle = INVALID_HANDLE;
int g_adx_handle  = INVALID_HANDLE;

int      g_file_handle = INVALID_HANDLE;
datetime g_last_h1_bar = 0;

int OnInit()
{
   g_atr_handle    = iATR(_Symbol, PERIOD_H1, InpAtrPeriod);
   g_rsi_h1_handle = iRSI(_Symbol, PERIOD_H1, InpRsiPeriod, PRICE_CLOSE);
   g_rsi_h4_handle = iRSI(_Symbol, PERIOD_H4, InpRsiPeriod, PRICE_CLOSE);
   g_adx_handle    = iADX(_Symbol, PERIOD_H1, InpAdxPeriod);

   if(g_atr_handle == INVALID_HANDLE || g_rsi_h1_handle == INVALID_HANDLE
      || g_rsi_h4_handle == INVALID_HANDLE || g_adx_handle == INVALID_HANDLE)
   {
      Print("MLFeatureDumpEA: indicator init failed.");
      return(INIT_FAILED);
   }

   g_file_handle = FileOpen(InpLogFile, FILE_WRITE | FILE_READ | FILE_TXT);
   if(g_file_handle == INVALID_HANDLE)
   {
      Print("MLFeatureDumpEA: could not open log file, error ", GetLastError());
      return(INIT_FAILED);
   }
   FileSeek(g_file_handle, 0, SEEK_END);

   g_last_h1_bar = iTime(_Symbol, PERIOD_H1, 0);

   Print("MLFeatureDumpEA initialized on ", _Symbol);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_file_handle != INVALID_HANDLE) { FileClose(g_file_handle); g_file_handle = INVALID_HANDLE; }
   if(g_atr_handle != INVALID_HANDLE)    IndicatorRelease(g_atr_handle);
   if(g_rsi_h1_handle != INVALID_HANDLE) IndicatorRelease(g_rsi_h1_handle);
   if(g_rsi_h4_handle != INVALID_HANDLE) IndicatorRelease(g_rsi_h4_handle);
   if(g_adx_handle != INVALID_HANDLE)    IndicatorRelease(g_adx_handle);
}

double CopySingle(int handle, int buffer_index, int shift)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(handle == INVALID_HANDLE || CopyBuffer(handle, buffer_index, shift, 1, buf) != 1)
      return -1.0;
   return buf[0];
}

void OnTick()
{
   datetime cur_h1 = iTime(_Symbol, PERIOD_H1, 0);
   if(cur_h1 == g_last_h1_bar)
      return;
   g_last_h1_bar = cur_h1;

   int shift = 1; // last closed H1 bar
   datetime t = iTime(_Symbol, PERIOD_H1, shift);
   double o = iOpen(_Symbol, PERIOD_H1, shift);
   double h = iHigh(_Symbol, PERIOD_H1, shift);
   double l = iLow(_Symbol, PERIOD_H1, shift);
   double c = iClose(_Symbol, PERIOD_H1, shift);
   long   v = iVolume(_Symbol, PERIOD_H1, shift);

   double atr    = CopySingle(g_atr_handle, 0, shift);
   double rsi_h1 = CopySingle(g_rsi_h1_handle, 0, shift);
   double rsi_h4 = CopySingle(g_rsi_h4_handle, 0, shift);
   double adx_h1 = CopySingle(g_adx_handle, 0, shift);
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   string line = StringFormat("%s|%s|%.8f|%.8f|%.8f|%.8f|%d|%.8f|%.4f|%.4f|%.4f|%.2f",
                               _Symbol, TimeToString(t, TIME_DATE | TIME_MINUTES),
                               o, h, l, c, (int)v, atr, rsi_h1, rsi_h4, adx_h1, spread);
   FileWrite(g_file_handle, line);
}
//+------------------------------------------------------------------+
