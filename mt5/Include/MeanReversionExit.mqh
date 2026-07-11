//+------------------------------------------------------------------+
//| MeanReversionExit.mqh                                              |
//| Phase 1b's own exit structure -- NOT inherited from Phase 1's       |
//| ExitManager.mqh (per the closeout's explicit flag: those parameters |
//| were only ever validated against the now-rejected trend-following   |
//| logic, and mean reversion's exit shape is fundamentally different:  |
//| a bounded target (the band's moving mean), not a "let winners run"  |
//| trailing structure).                                                |
//|                                                                     |
//| TP is the SMA center, re-read live every tick (a moving target, not |
//| a static broker-side order). SL is set by the caller at open time   |
//| (ATR-based default, or band-extreme -- see Phase1bEA's InpMRSLMode) |
//| and IS a real broker-side stop. No large trend-following trailing   |
//| by default -- only a simple breakeven-after-partial-progress rule,  |
//| reusing RiskManager's existing (generic, ticket-based) breakeven    |
//| flag. A holding-period cap force-closes at market with a distinct   |
//| exit_reason ('timeout') if reversion hasn't happened in time.       |
//|                                                                     |
//| Reuses RiskManager.mqh's GlobalVariable position-state layer as-is  |
//| (SeedPositionState, GetInitialSL, MFE/MAE, breakeven flag,          |
//| ReconcileGlobals) -- RiskManager.mqh itself is untouched. Manages   |
//| one small SUPPLEMENTARY GlobalVariable of its own (an exit-reason   |
//| tag) rather than adding Phase-1b-specific state to RiskManager.     |
//+------------------------------------------------------------------+
#property strict

#include <Trade\Trade.mqh>
#include "RiskManager.mqh"
#include "BridgeLogger.mqh"

class CMeanReversionExit
{
private:
   string m_symbol;
   long   m_magic;
   int    m_sma_handle;
   int    m_holding_cap_bars;
   double m_breakeven_trigger_r;
   CTrade m_trade;

   // Manual closes (TP-target reached, holding-period timeout) both show up
   // as DEAL_REASON_CLIENT in trade history -- indistinguishable from each
   // other after the fact without this tag, set immediately before the close
   // attempt and read back when the trade is finalized.
   void SetExitTag(ulong ticket, string tag)
   {
      GlobalVariableSet("P1B_XR_" + IntegerToString((long)ticket), (tag == "timeout") ? 2.0 : 1.0);
   }

   string GetExitTag(ulong ticket)
   {
      string name = "P1B_XR_" + IntegerToString((long)ticket);
      if(!GlobalVariableCheck(name)) return "";
      double v = GlobalVariableGet(name);
      if(v == 2.0) return "timeout";
      if(v == 1.0) return "tp_mean";
      return "";
   }

   void ClearExitTag(ulong ticket)
   {
      GlobalVariableDel("P1B_XR_" + IntegerToString((long)ticket));
   }

public:
   CMeanReversionExit() : m_sma_handle(INVALID_HANDLE) {}

   bool Init(string symbol, long magic, int sma_period, int holding_cap_bars, double breakeven_trigger_r)
   {
      m_symbol              = symbol;
      m_magic               = magic;
      m_holding_cap_bars    = holding_cap_bars;
      m_breakeven_trigger_r = breakeven_trigger_r;
      m_sma_handle          = iMA(m_symbol, PERIOD_H1, sma_period, 0, MODE_SMA, PRICE_CLOSE);

      m_trade.SetExpertMagicNumber(m_magic);
      m_trade.SetTypeFillingBySymbol(m_symbol);
      return (m_sma_handle != INVALID_HANDLE);
   }

   void Deinit()
   {
      if(m_sma_handle != INVALID_HANDLE) { IndicatorRelease(m_sma_handle); m_sma_handle = INVALID_HANDLE; }
   }

   // Called every tick for all of this EA's open positions.
   void ManageOpenPositions(CRiskManager &risk, CBridgeLogger &logger)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(!PositionSelectByTicket(ticket)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;

         ManageOne(ticket, risk, logger);
      }
   }

   // Same P1_InitSL_-scan pattern Phase 1's ExitManager uses -- reused
   // directly since RiskManager's GlobalVariable layer is shared/generic,
   // not Phase-1-specific.
   void DetectAndFinalizeClosedPositions(CRiskManager &risk, CBridgeLogger &logger)
   {
      int total = GlobalVariablesTotal();
      string closed_tickets[];
      ArrayResize(closed_tickets, 0);

      const string prefix = "P1_InitSL_";
      for(int i = total - 1; i >= 0; i--)
      {
         string name = GlobalVariableName(i);
         if(StringFind(name, prefix) != 0)
            continue;

         string ticket_str = StringSubstr(name, StringLen(prefix));
         ulong ticket = (ulong)StringToInteger(ticket_str);

         if(!PositionSelectByTicket(ticket))
         {
            int n = ArraySize(closed_tickets);
            ArrayResize(closed_tickets, n + 1);
            closed_tickets[n] = ticket_str;
         }
      }

      for(int i = 0; i < ArraySize(closed_tickets); i++)
         FinalizeClosedTrade((ulong)StringToInteger(closed_tickets[i]), risk, logger);
   }

   void FinalizeClosedTrade(ulong ticket, CRiskManager &risk, CBridgeLogger &logger)
   {
      double initial_sl = risk.GetInitialSL(ticket, logger);
      double mfe = risk.GetMFE(ticket);
      double mae = risk.GetMAE(ticket);
      string manual_tag = GetExitTag(ticket);

      if(!HistorySelectByPosition(ticket))
      {
         risk.ClearPositionState(ticket);
         ClearExitTag(ticket);
         return;
      }

      double close_price  = 0.0;
      datetime close_time = 0;
      double total_profit = 0.0;
      double open_price   = 0.0;
      bool   is_buy       = true;
      ENUM_DEAL_REASON close_reason = DEAL_REASON_CLIENT;

      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
      {
         ulong deal_ticket = HistoryDealGetTicket(i);
         if(deal_ticket == 0) continue;

         long entry_type = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
         total_profit += HistoryDealGetDouble(deal_ticket, DEAL_PROFIT)
                        + HistoryDealGetDouble(deal_ticket, DEAL_SWAP)
                        + HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);

         if(entry_type == DEAL_ENTRY_IN)
         {
            open_price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
            is_buy = (HistoryDealGetInteger(deal_ticket, DEAL_TYPE) == DEAL_TYPE_BUY);
         }
         else if(entry_type == DEAL_ENTRY_OUT || entry_type == DEAL_ENTRY_OUT_BY)
         {
            close_price  = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
            close_time   = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
            close_reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket, DEAL_REASON);
         }
      }

      double r_multiple = 0.0;
      if(initial_sl > 0 && open_price > 0)
      {
         double r_distance = MathAbs(open_price - initial_sl);
         if(r_distance > 0)
         {
            double realized_move = is_buy ? (close_price - open_price) : (open_price - close_price);
            r_multiple = realized_move / r_distance;
         }
      }

      // Broker-side SL is the only real order-level exit here (no broker TP
      // is ever set -- the target is a moving line, monitored and closed
      // manually). Manual closes are tagged at the moment we request them
      // (tp_mean / timeout); anything else manual and untagged is a
      // plain manual_close.
      string exit_reason;
      if(close_reason == DEAL_REASON_SL)
         exit_reason = "sl_hit";
      else if(manual_tag != "")
         exit_reason = manual_tag;
      else
         exit_reason = "manual_close";

      string fields = "{";
      fields += "\"close_time\":" + logger.Json(logger.IsoTime(close_time)) + ",";
      fields += "\"close_price\":" + logger.Num(close_price) + ",";
      fields += "\"r_multiple\":" + logger.Num(r_multiple) + ",";
      fields += "\"mfe\":" + logger.Num(mfe) + ",";
      fields += "\"mae\":" + logger.Num(mae) + ",";
      fields += "\"exit_reason\":" + logger.Json(exit_reason) + ",";
      fields += "\"profit\":" + logger.Num(total_profit);
      fields += "}";

      logger.PatchTrade(ticket, fields);
      risk.ClearPositionState(ticket);
      ClearExitTag(ticket);
   }

private:
   void ManageOne(ulong ticket, CRiskManager &risk, CBridgeLogger &logger)
   {
      double initial_sl = risk.GetInitialSL(ticket, logger);
      if(initial_sl <= 0)
         return;

      bool is_buy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double current_price = is_buy ? bid : ask;

      double r_distance = MathAbs(open_price - initial_sl);
      if(r_distance <= 0)
         return;

      double favorable = is_buy ? (current_price - open_price) : (open_price - current_price);
      double adverse    = is_buy ? (open_price - current_price) : (current_price - open_price);
      if(favorable > 0) risk.UpdateMFE(ticket, favorable);
      if(adverse > 0)   risk.UpdateMAE(ticket, adverse);

      double r_multiple_now = favorable / r_distance;

      // Breakeven after partial progress -- the only "let it breathe a bit"
      // concession this exit structure makes; no larger trailing beyond this
      // by default (see file header).
      if(!risk.GetBreakevenDone(ticket) && r_multiple_now >= m_breakeven_trigger_r)
      {
         if(TryModifySL(ticket, is_buy, open_price))
            risk.SetBreakevenDone(ticket);
      }

      // Holding-period cap -- checked before the TP-target check so a trade
      // that happens to hit both conditions on the same tick is recorded as
      // a timeout, not a coincidental late TP (the cap firing at all means
      // reversion took longer than the regime filter's premise assumed).
      int bars_elapsed = iBarShift(m_symbol, PERIOD_H1, (datetime)PositionGetInteger(POSITION_TIME), false);
      if(bars_elapsed >= m_holding_cap_bars)
      {
         SetExitTag(ticket, "timeout");
         if(!m_trade.PositionClose(ticket))
            ClearExitTag(ticket); // close failed -- don't leave a stale tag for next tick's retry
         return;
      }

      // TP: the band's mean itself, re-read live every tick (not a static
      // broker order) -- reached when price trades at or through it in the
      // favorable direction.
      double sma[];
      ArraySetAsSeries(sma, true);
      if(CopyBuffer(m_sma_handle, 0, 1, 1, sma) != 1)
         return;
      double target = sma[0];

      bool tp_reached = is_buy ? (bid >= target) : (ask <= target);
      if(tp_reached)
      {
         SetExitTag(ticket, "tp_mean");
         if(!m_trade.PositionClose(ticket))
            ClearExitTag(ticket);
      }
   }

   // Only ever tightens (monotonic improvement) and respects the broker's
   // minimum stop distance, same safety pattern as Phase 1's ExitManager --
   // a PositionModify violating stops-level is rejected by the trade server,
   // so check first rather than failing after.
   bool TryModifySL(ulong ticket, bool is_buy, double new_sl)
   {
      if(!PositionSelectByTicket(ticket))
         return false;

      double current_sl = PositionGetDouble(POSITION_SL);
      double current_tp = PositionGetDouble(POSITION_TP);

      bool improvement = is_buy ? (new_sl > current_sl) : (new_sl < current_sl);
      if(current_sl > 0 && !improvement)
         return false;

      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      long stops_level_points = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double min_distance = stops_level_points * point;

      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double ref_price = is_buy ? bid : ask;
      double distance = is_buy ? (ref_price - new_sl) : (new_sl - ref_price);
      if(distance < min_distance)
         return false;

      int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      return m_trade.PositionModify(ticket, NormalizeDouble(new_sl, digits), current_tp);
   }
};
//+------------------------------------------------------------------+
