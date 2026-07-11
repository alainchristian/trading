//+------------------------------------------------------------------+
//| InstrumentCheckEA.mq5                                             |
//| Read-only symbol/history-depth check -- reports on _Symbol (the    |
//| Tester's own tested symbol) only, since checking OTHER symbols'    |
//| history from within a Tester run for a different symbol is         |
//| unreliable (established empirically in Phase 1). Run once per      |
//| candidate symbol as the Tester's own Symbol=. No trading.          |
//+------------------------------------------------------------------+
#property strict

int OnInit()
{
   datetime first_date = (datetime)SeriesInfoInteger(_Symbol, PERIOD_D1, SERIES_FIRSTDATE);
   long bars_h1 = SeriesInfoInteger(_Symbol, PERIOD_H1, SERIES_BARS_COUNT);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   PrintFormat("CHECK|%s|FIRST_D1=%s|H1_BARS=%d|POINT=%.8f|TICK_VALUE=%.4f|DIGITS=%d",
               _Symbol, TimeToString(first_date, TIME_DATE), (int)bars_h1, point, tick_value, digits);

   return(INIT_SUCCEEDED);
}

void OnTick() {}
