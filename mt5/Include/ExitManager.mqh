//+------------------------------------------------------------------+
//| ExitManager.mqh                                                    |
//| Partial TP (30% @ 1R, 30% @ 2R), breakeven after TP1, and trailing  |
//| the remaining 40% (ATR or structure mode). Runs every tick for all  |
//| of this EA's open positions. R-multiples are always computed from   |
//| the ORIGINAL SL distance (persisted via RiskManager's                |
//| GlobalVariable layer), fixed even after the SL is moved to           |
//| breakeven or trailed -- otherwise "1R" drifts and r_multiple in      |
//| the trades table becomes meaningless for later analysis.             |
//+------------------------------------------------------------------+
#property strict

#include <Trade\Trade.mqh>
#include "RiskManager.mqh"
#include "Structure.mqh"
#include "Volatility.mqh"
#include "BridgeLogger.mqh"

enum ENUM_TRAIL_MODE
{
   TRAIL_MODE_ATR,
   TRAIL_MODE_STRUCTURE
};

class CExitManager
{
private:
   string m_symbol;
   long   m_magic;
   double m_tp1_fraction;
   double m_tp2_fraction;
   ENUM_TRAIL_MODE m_trail_mode;
   double m_atr_trail_multiplier;
   int    m_structure_trail_lookback;
   double m_structure_trail_buffer;
   CTrade m_trade;

public:
   bool Init(string symbol, long magic, double tp1_fraction, double tp2_fraction,
             ENUM_TRAIL_MODE trail_mode, double atr_trail_multiplier,
             int structure_trail_lookback, double structure_trail_buffer)
   {
      m_symbol                   = symbol;
      m_magic                    = magic;
      m_tp1_fraction             = tp1_fraction;
      m_tp2_fraction             = tp2_fraction;
      m_trail_mode               = trail_mode;
      m_atr_trail_multiplier     = atr_trail_multiplier;
      m_structure_trail_lookback = structure_trail_lookback;
      m_structure_trail_buffer   = structure_trail_buffer;

      m_trade.SetExpertMagicNumber(m_magic);
      m_trade.SetTypeFillingBySymbol(m_symbol);
      return true;
   }

   // Called every tick. Iterates this EA's open positions on m_symbol.
   void ManageOpenPositions(CRiskManager &risk, CStructure &structure,
                             CVolatility &volatility, CBridgeLogger &logger)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(!PositionSelectByTicket(ticket)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;

         ManageOne(ticket, risk, structure, volatility, logger);
      }
   }

   // Called every tick (cheap: GlobalVariablesTotal is bounded by the small
   // number of concurrently-tracked positions). ManageOpenPositions only
   // iterates currently-open positions, so it can never observe one that
   // just fully closed -- this scans the P1_-tracked tickets instead and
   // finalizes any whose position has disappeared from PositionsTotal().
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

   // Finalizes the trades row for a ticket whose position has fully closed.
   void FinalizeClosedTrade(ulong ticket, CRiskManager &risk, CBridgeLogger &logger)
   {
      double initial_sl = risk.GetInitialSL(ticket, logger);
      double mfe = risk.GetMFE(ticket);
      double mae = risk.GetMAE(ticket);
      bool tp1_done = risk.GetTP1Done(ticket);

      if(!HistorySelectByPosition(ticket))
      {
         risk.ClearPositionState(ticket);
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
            // Overwritten on each OUT deal; the last one processed (final
            // full close) is what remains after the loop.
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

      string exit_reason = ExitReasonFromDealReason(close_reason, tp1_done, open_price, close_price);

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
   }

private:
   void ManageOne(ulong ticket, CRiskManager &risk, CStructure &structure,
                   CVolatility &volatility, CBridgeLogger &logger)
   {
      double initial_sl = risk.GetInitialSL(ticket, logger);
      if(initial_sl <= 0)
         return; // unrecoverable initial SL -- position keeps its live MT5 SL/TP, just not R-managed this tick

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

      if(!risk.GetTP1Done(ticket) && r_multiple_now >= 1.0)
      {
         if(TryPartialClose(ticket, risk, m_tp1_fraction))
         {
            risk.SetTP1Done(ticket);
            logger.LogEvent("ea", "partial_close", PartialClosePayload(ticket, "tp1", r_multiple_now));
            TryMoveToBreakeven(ticket, is_buy, open_price, risk);
         }
      }
      else if(risk.GetTP1Done(ticket) && !risk.GetTP2Done(ticket) && r_multiple_now >= 2.0)
      {
         if(TryPartialClose(ticket, risk, m_tp2_fraction))
         {
            risk.SetTP2Done(ticket);
            logger.LogEvent("ea", "partial_close", PartialClosePayload(ticket, "tp2", r_multiple_now));
         }
      }

      if(risk.GetTP1Done(ticket))
         TryTrail(ticket, is_buy, structure, volatility);
   }

   void TryMoveToBreakeven(ulong ticket, bool is_buy, double open_price, CRiskManager &risk)
   {
      if(risk.GetBreakevenDone(ticket))
         return;
      if(TryModifySL(ticket, is_buy, open_price))
         risk.SetBreakevenDone(ticket);
   }

   void TryTrail(ulong ticket, bool is_buy, CStructure &structure, CVolatility &volatility)
   {
      double new_sl = 0.0;
      bool have_new_sl = false;

      if(m_trail_mode == TRAIL_MODE_ATR)
      {
         double atr = volatility.GetATR(0); // forming-bar ATR is fine here -- trailing isn't an entry decision subject to lookahead bias
         if(atr > 0)
         {
            double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
            double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
            double ref = is_buy ? bid : ask;
            new_sl = is_buy ? (ref - atr * m_atr_trail_multiplier) : (ref + atr * m_atr_trail_multiplier);
            have_new_sl = true;
         }
      }
      else
      {
         SwingPoint sp;
         bool found = is_buy
            ? structure.FindLastSwingLow(PERIOD_H1, m_structure_trail_lookback, 1, 100, sp)
            : structure.FindLastSwingHigh(PERIOD_H1, m_structure_trail_lookback, 1, 100, sp);
         if(found)
         {
            new_sl = is_buy ? (sp.price - m_structure_trail_buffer) : (sp.price + m_structure_trail_buffer);
            have_new_sl = true;
         }
      }

      if(have_new_sl)
         TryModifySL(ticket, is_buy, new_sl);
   }

   // Only ever tightens (monotonic improvement) and respects the broker's
   // minimum stop distance -- MT5 doesn't enforce either itself, and a
   // PositionModify violating stops-level is simply rejected by the trade
   // server, so check first rather than failing after.
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

   // Rounds the requested fraction of the ORIGINAL lot size down to the
   // broker's volume step. If that rounds to below the minimum tradable
   // volume (common on minimum-lot positions), skips the partial explicitly
   // rather than attempting a zero-volume close -- the position rides to the
   // next TP/exit instead.
   bool TryPartialClose(ulong ticket, CRiskManager &risk, double fraction)
   {
      if(!PositionSelectByTicket(ticket))
         return false;

      double original_lot   = risk.GetOriginalLotSize(ticket);
      double current_volume = PositionGetDouble(POSITION_VOLUME);

      double lot_step = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      double lot_min   = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      if(lot_step <= 0)
         return false;

      double raw_partial = original_lot * fraction;
      double partial = MathFloor(raw_partial / lot_step) * lot_step;
      partial = NormalizeDouble(partial, CountVolumeDecimals(lot_step));

      if(partial < lot_min)
         return false;

      if(partial > current_volume)
         partial = current_volume;

      return m_trade.PositionClosePartial(ticket, partial);
   }

   string PartialClosePayload(ulong ticket, string label, double r_multiple_now)
   {
      return StringFormat("{\"ticket\":%I64d,\"stage\":\"%s\",\"r_multiple_at_close\":%s}",
                           (long)ticket, label, DoubleToString(r_multiple_now, 4));
   }

   string ExitReasonFromDealReason(ENUM_DEAL_REASON reason, bool tp1_done, double open_price, double close_price)
   {
      if(reason == DEAL_REASON_SL)
      {
         if(!tp1_done)
            return "sl_hit";

         double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
         if(point <= 0) return "trailing_stop";

         double diff_points = MathAbs(close_price - open_price) / point;
         return (diff_points <= 3.0) ? "breakeven" : "trailing_stop";
      }
      if(reason == DEAL_REASON_TP)
         return "tp2";

      return "manual_close";
   }

   int CountVolumeDecimals(double step)
   {
      if(step <= 0) return 2;
      int decimals = 0;
      double s = step;
      while(MathAbs(s - MathRound(s)) > 0.0000001 && decimals < 8)
      {
         s *= 10;
         decimals++;
      }
      return decimals;
   }
};
//+------------------------------------------------------------------+
