//+------------------------------------------------------------------+
//| SymbolInfoDumpEA.mq5                                               |
//| Read-only diagnostic EA for Phase 1 closeout Step 1 (position      |
//| sizing spot-check) -- prints broker symbol specs needed to verify  |
//| RiskManager::CalculateLotSize by hand. No trading, no live changes;|
//| run once via Strategy Tester over a 1-day range, same mechanism as |
//| every other backtest in this project.                              |
//+------------------------------------------------------------------+
#property strict

int OnInit()
{
   // Only _Symbol is guaranteed synchronized in the Tester -- run once per
   // instrument (as the Tester's own Symbol=) rather than looping over all 4.
   string s = _Symbol;
   double tick_value = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
   double lot_step   = SymbolInfoDouble(s, SYMBOL_VOLUME_STEP);
   double lot_min    = SymbolInfoDouble(s, SYMBOL_VOLUME_MIN);
   double lot_max    = SymbolInfoDouble(s, SYMBOL_VOLUME_MAX);
   double contract   = SymbolInfoDouble(s, SYMBOL_TRADE_CONTRACT_SIZE);
   int digits        = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   PrintFormat("SYMDUMP|%s|tick_value=%.6f|tick_size=%.6f|lot_step=%.4f|lot_min=%.4f|lot_max=%.2f|contract=%.2f|digits=%d",
               s, tick_value, tick_size, lot_step, lot_min, lot_max, contract, digits);
   return(INIT_SUCCEEDED);
}

void OnTick() {}
