//+------------------------------------------------------------------+
//| RiskManager.mqh                                                    |
//| Position sizing, SL/TP calculation, daily/weekly loss limits, max  |
//| drawdown, max exposure -- and the GlobalVariable-based position-   |
//| state persistence (R-multiple/MFE/MAE) that survives EA restarts.  |
//|                                                                     |
//| Loss-limit/drawdown gating is computed ENTIRELY from MT5's own     |
//| account/history data (never from a bridge round-trip), matching    |
//| the phase's goal of zero live dependency on the Python bridge for  |
//| trading decisions. risk_state is logged to Postgres via            |
//| CBridgeLogger as a fire-and-forget record, not a source of truth.  |
//+------------------------------------------------------------------+
#property strict

#include "Structure.mqh"
#include "BridgeLogger.mqh"

enum ENUM_SL_MODE
{
   SL_MODE_ATR,
   SL_MODE_SWING
};

class CRiskManager
{
private:
   string m_symbol;
   long   m_magic;

   double m_risk_percent;
   ENUM_SL_MODE m_sl_mode;
   double m_atr_multiplier;
   int    m_swing_lookback;
   double m_swing_buffer_price;

   double m_daily_loss_limit_percent;
   double m_weekly_loss_limit_percent;
   double m_max_drawdown_percent;
   int    m_max_open_trades;

   int      m_last_day_key;
   datetime m_day_start_time;
   double   m_day_start_balance;
   bool     m_daily_loss_limit_hit;

   datetime m_week_start_time;
   double   m_week_start_balance;
   bool     m_weekly_loss_limit_hit;

   double m_equity_peak;

public:
   bool Init(string symbol, long magic, double risk_percent, ENUM_SL_MODE sl_mode,
             double atr_multiplier, int swing_lookback, double swing_buffer_price,
             double daily_loss_limit_percent, double weekly_loss_limit_percent,
             double max_drawdown_percent, int max_open_trades)
   {
      m_symbol             = symbol;
      m_magic              = magic;
      m_risk_percent       = risk_percent;
      m_sl_mode            = sl_mode;
      m_atr_multiplier     = atr_multiplier;
      m_swing_lookback     = swing_lookback;
      m_swing_buffer_price = swing_buffer_price;

      m_daily_loss_limit_percent  = daily_loss_limit_percent;
      m_weekly_loss_limit_percent = weekly_loss_limit_percent;
      m_max_drawdown_percent      = max_drawdown_percent;
      m_max_open_trades           = max_open_trades;

      m_last_day_key = 0;
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      m_day_start_balance    = balance;
      m_week_start_balance   = balance;
      m_day_start_time       = TimeCurrent();
      m_week_start_time      = TimeCurrent();
      m_daily_loss_limit_hit  = false;
      m_weekly_loss_limit_hit = false;
      m_equity_peak = AccountInfoDouble(ACCOUNT_EQUITY);

      return true;
   }

   //--- SL / TP calculation -------------------------------------------------

   double ComputeATRSL(bool is_buy, double entry, double atr)
   {
      if(atr <= 0) return -1.0;
      return is_buy ? (entry - atr * m_atr_multiplier) : (entry + atr * m_atr_multiplier);
   }

   bool ComputeSwingSL(bool is_buy, CStructure &structure, double &sl_out)
   {
      SwingPoint sp;
      bool found = is_buy
         ? structure.FindLastSwingLow(PERIOD_H1, m_swing_lookback, 1, 100, sp)
         : structure.FindLastSwingHigh(PERIOD_H1, m_swing_lookback, 1, 100, sp);
      if(!found)
         return false;

      sl_out = is_buy ? (sp.price - m_swing_buffer_price) : (sp.price + m_swing_buffer_price);
      return true;
   }

   // Computes SL per the configured mode. SL must always be computed BEFORE
   // lot sizing -- sizing depends on the SL distance, never the reverse.
   bool ComputeSL(bool is_buy, double entry, double atr, CStructure &structure, double &sl_out)
   {
      if(m_sl_mode == SL_MODE_SWING)
      {
         if(ComputeSwingSL(is_buy, structure, sl_out))
            return true;
         // Fall back to ATR if no confirmed swing is available yet (e.g. early
         // in a backtest) rather than producing no signal at all.
      }

      double atr_sl = ComputeATRSL(is_buy, entry, atr);
      if(atr_sl <= 0)
         return false;

      sl_out = atr_sl;
      return true;
   }

   void ComputeTPs(bool is_buy, double entry, double sl, double &tp1_out, double &tp2_out)
   {
      double r = MathAbs(entry - sl);
      tp1_out = is_buy ? entry + r : entry - r;
      tp2_out = is_buy ? entry + 2.0 * r : entry - 2.0 * r;
   }

   //--- Position sizing -------------------------------------------------------

   // lot_size = (balance * risk_percent) / (sl_distance_in_price * loss_per_price_unit_per_lot)
   // Rounds DOWN to the broker's lot step (never up -- rounding up silently
   // increases risk beyond the configured percent). Rejects (does not bump to
   // minimum) if the rounded size falls below the broker's minimum lot.
   bool CalculateLotSize(double sl_distance_price, double &lot_out, string &reject_reason)
   {
      if(sl_distance_price <= 0)
      {
         reject_reason = "invalid_sl_distance";
         return false;
      }

      double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
      double risk_money  = balance * (m_risk_percent / 100.0);

      double tick_value = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      double tick_size  = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tick_value <= 0 || tick_size <= 0)
      {
         reject_reason = "invalid_symbol_tick_info";
         return false;
      }

      double loss_per_lot = (sl_distance_price / tick_size) * tick_value;
      if(loss_per_lot <= 0)
      {
         reject_reason = "invalid_loss_per_lot";
         return false;
      }

      double raw_lots = risk_money / loss_per_lot;

      double lot_step = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      double lot_min   = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double lot_max   = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      if(lot_step <= 0)
      {
         reject_reason = "invalid_lot_step";
         return false;
      }

      double rounded = MathFloor(raw_lots / lot_step) * lot_step;
      rounded = NormalizeDouble(rounded, CountDecimals(lot_step));

      if(rounded < lot_min)
      {
         reject_reason = "lot_size_below_minimum";
         return false;
      }

      if(rounded > lot_max)
         rounded = lot_max; // clipping down only ever reduces realized risk below the configured percent

      lot_out = rounded;
      return true;
   }

   //--- Daily/weekly rollover + loss limits / drawdown / exposure -----------

   // Call every tick (cheap: one MqlDateTime conversion + int compare in the
   // common case). Detects a new trading day (and, on Mondays, a new week),
   // resets the relevant starting balance, and logs the reset to Postgres.
   //
   // Fix (Phase 1 closeout, risk_state audit-trail bug): this is the only
   // call site for LogRiskState, and it used to unconditionally log
   // realized_pnl=0.0/loss_limit_hit=false/trading_halted=false regardless
   // of what actually happened -- correct for the fresh day being opened,
   // but it meant risk_state could never show a real halt, ever, since
   // nothing runs again before the day ends. Fixed by logging the OUTGOING
   // day's final tally here too, right before resetting for the new one,
   // using the exact same realized-P&L calc and latched hit-flags
   // CheckDailyLossLimit/CheckWeeklyLossLimit already use -- not a parallel
   // computation, so risk_state can't drift from what actually gated
   // entries that day. loss_limit_hit/trading_halted are the daily OR
   // weekly flag (either one blocks entries; the schema has no separate
   // weekly row), and realized_pnl is that DAY's own realized P&L (not the
   // week's cumulative figure, even when it was the weekly limit that
   // tripped -- the schema has one row per day, not a separate weekly
   // figure). Known accepted gap: the very last day of a run never gets its
   // closing row written, since there's no subsequent rollover to trigger
   // it -- out of scope for this fix.
   void CheckRollover(CBridgeLogger &logger)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int today_key = dt.year * 1000 + dt.day_of_year;

      if(today_key == m_last_day_key)
         return;

      if(m_last_day_key != 0)
      {
         MqlDateTime prev_dt;
         TimeToStruct(m_day_start_time, prev_dt);
         string prev_date = StringFormat("%04d-%02d-%02d", prev_dt.year, prev_dt.mon, prev_dt.day);
         double prev_realized = SumClosedProfitSince(m_day_start_time);
         bool prev_hit = m_daily_loss_limit_hit || m_weekly_loss_limit_hit;
         logger.LogRiskState(prev_date, "account", m_day_start_balance, prev_realized, prev_hit, prev_hit);
      }

      bool is_new_week = (dt.day_of_week == 1) || (m_last_day_key == 0);
      m_last_day_key = today_key;

      m_day_start_time    = TimeCurrent();
      m_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      m_daily_loss_limit_hit = false;

      if(is_new_week)
      {
         m_week_start_time    = TimeCurrent();
         m_week_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
         m_weekly_loss_limit_hit = false;
      }

      string trading_date = StringFormat("%04d-%02d-%02d", dt.year, dt.mon, dt.day);
      logger.LogRiskState(trading_date, "account", m_day_start_balance, 0.0, false, false);
   }

   void UpdateEquityPeak()
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity > m_equity_peak)
         m_equity_peak = equity;
   }

   bool CheckDailyLossLimit(string &reject_reason)
   {
      if(m_day_start_balance <= 0) return true;

      double realized = SumClosedProfitSince(m_day_start_time);
      double loss_limit_money = m_day_start_balance * (m_daily_loss_limit_percent / 100.0);

      if(realized <= -loss_limit_money)
      {
         m_daily_loss_limit_hit = true;
         reject_reason = "daily_loss_limit";
         return false;
      }
      return true;
   }

   bool CheckWeeklyLossLimit(string &reject_reason)
   {
      if(m_week_start_balance <= 0) return true;

      double realized = SumClosedProfitSince(m_week_start_time);
      double loss_limit_money = m_week_start_balance * (m_weekly_loss_limit_percent / 100.0);

      if(realized <= -loss_limit_money)
      {
         m_weekly_loss_limit_hit = true;
         reject_reason = "weekly_loss_limit";
         return false;
      }
      return true;
   }

   bool CheckMaxDrawdown(string &reject_reason)
   {
      if(m_equity_peak <= 0) return true;

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double drawdown_percent = (m_equity_peak - equity) / m_equity_peak * 100.0;

      if(drawdown_percent >= m_max_drawdown_percent)
      {
         reject_reason = "max_drawdown_halt";
         return false;
      }
      return true;
   }

   bool CheckMaxExposure(string &reject_reason)
   {
      int count = 0;
      for(int i = 0; i < PositionsTotal(); i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(!PositionSelectByTicket(ticket)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;
         count++;
      }

      if(count >= m_max_open_trades)
      {
         reject_reason = "max_open_trades";
         return false;
      }
      return true;
   }

   // Composite gate, checked in this fixed order (after the 6 confluence
   // checks + Session/Spread have already passed). rejection_reason is the
   // first failing gate.
   bool PassesRiskGates(string &reject_reason)
   {
      if(!CheckDailyLossLimit(reject_reason))  return false;
      if(!CheckWeeklyLossLimit(reject_reason)) return false;
      if(!CheckMaxDrawdown(reject_reason))     return false;
      if(!CheckMaxExposure(reject_reason))     return false;
      return true;
   }

   double DayStartBalance()  { return m_day_start_balance; }
   double WeekStartBalance() { return m_week_start_balance; }

   //--- GlobalVariable-based position-state persistence ----------------------
   // Three-tier design: in-memory reads aren't cached separately here since
   // GlobalVariableGet is an in-terminal table lookup (cheap, no disk I/O per
   // call) -- no separate in-memory struct array is needed for correctness,
   // only for avoiding redundant writes (see UpdateMFEMAE below).

   void SeedPositionState(ulong ticket, long signal_id, double initial_sl, double lot_size)
   {
      string t = IntegerToString((long)ticket);
      GlobalVariableSet("P1_InitSL_" + t, initial_sl);
      GlobalVariableSet("P1_SigID_" + t, (double)signal_id);
      GlobalVariableSet("P1_Lot_" + t, lot_size);
      GlobalVariableSet("P1_MFE_" + t, 0.0);
      GlobalVariableSet("P1_MAE_" + t, 0.0);
      GlobalVariableSet("P1_TP1_" + t, 0.0);
      GlobalVariableSet("P1_TP2_" + t, 0.0);
      GlobalVariableSet("P1_BE_" + t, 0.0);
   }

   // Original opened lot size (immutable), needed so partial-close fractions
   // (30%/30%/40%) are computed against the ORIGINAL size, not the shrinking
   // remaining volume. Falls back to the live position's current volume if
   // the GlobalVariable was lost (best-effort only -- see GetInitialSL for
   // the more important initial_sl fallback via the bridge).
   double GetOriginalLotSize(ulong ticket)
   {
      string name = "P1_Lot_" + IntegerToString((long)ticket);
      if(GlobalVariableCheck(name))
         return GlobalVariableGet(name);
      return PositionSelectByTicket(ticket) ? PositionGetDouble(POSITION_VOLUME) : 0.0;
   }

   // Last-resort reconciliation: if the GlobalVariable is missing (expired,
   // deleted, or a position opened by a prior EA version), fall back to the
   // bridge's GET /trades/{ticket}. Returns -1.0 if truly unrecoverable.
   double GetInitialSL(ulong ticket, CBridgeLogger &logger)
   {
      string name = "P1_InitSL_" + IntegerToString((long)ticket);
      if(GlobalVariableCheck(name))
         return GlobalVariableGet(name);

      double sl_from_bridge;
      if(logger.GetTradeInitialSL(ticket, sl_from_bridge))
      {
         GlobalVariableSet(name, sl_from_bridge);
         return sl_from_bridge;
      }
      return -1.0;
   }

   long GetSignalId(ulong ticket)
   {
      string name = "P1_SigID_" + IntegerToString((long)ticket);
      if(!GlobalVariableCheck(name)) return -1;
      return (long)GlobalVariableGet(name);
   }

   double GetMFE(ulong ticket)
   {
      string name = "P1_MFE_" + IntegerToString((long)ticket);
      return GlobalVariableCheck(name) ? GlobalVariableGet(name) : 0.0;
   }

   double GetMAE(ulong ticket)
   {
      string name = "P1_MAE_" + IntegerToString((long)ticket);
      return GlobalVariableCheck(name) ? GlobalVariableGet(name) : 0.0;
   }

   // Only writes when the max actually increases -- gates the per-tick
   // GlobalVariableSet cost across a multi-year, every-tick backtest.
   void UpdateMFE(ulong ticket, double candidate)
   {
      if(candidate > GetMFE(ticket))
         GlobalVariableSet("P1_MFE_" + IntegerToString((long)ticket), candidate);
   }

   void UpdateMAE(ulong ticket, double candidate)
   {
      if(candidate > GetMAE(ticket))
         GlobalVariableSet("P1_MAE_" + IntegerToString((long)ticket), candidate);
   }

   bool GetTP1Done(ulong ticket)
   {
      string name = "P1_TP1_" + IntegerToString((long)ticket);
      return GlobalVariableCheck(name) && GlobalVariableGet(name) > 0.5;
   }

   void SetTP1Done(ulong ticket)
   {
      GlobalVariableSet("P1_TP1_" + IntegerToString((long)ticket), 1.0);
   }

   bool GetTP2Done(ulong ticket)
   {
      string name = "P1_TP2_" + IntegerToString((long)ticket);
      return GlobalVariableCheck(name) && GlobalVariableGet(name) > 0.5;
   }

   void SetTP2Done(ulong ticket)
   {
      GlobalVariableSet("P1_TP2_" + IntegerToString((long)ticket), 1.0);
   }

   bool GetBreakevenDone(ulong ticket)
   {
      string name = "P1_BE_" + IntegerToString((long)ticket);
      return GlobalVariableCheck(name) && GlobalVariableGet(name) > 0.5;
   }

   void SetBreakevenDone(ulong ticket)
   {
      GlobalVariableSet("P1_BE_" + IntegerToString((long)ticket), 1.0);
   }

   void ClearPositionState(ulong ticket)
   {
      string t = IntegerToString((long)ticket);
      GlobalVariableDel("P1_InitSL_" + t);
      GlobalVariableDel("P1_SigID_" + t);
      GlobalVariableDel("P1_Lot_" + t);
      GlobalVariableDel("P1_MFE_" + t);
      GlobalVariableDel("P1_MAE_" + t);
      GlobalVariableDel("P1_TP1_" + t);
      GlobalVariableDel("P1_TP2_" + t);
      GlobalVariableDel("P1_BE_" + t);
   }

   // Call once from OnInit. Deletes any P1_* globals whose ticket has no live
   // open position -- cleans up after restarts AND fixes Strategy Tester
   // ticket numbers resetting to 1 across separate test runs (otherwise a
   // fresh run's ticket 1 would read stale state left by a previous run).
   void ReconcileGlobals()
   {
      int total = GlobalVariablesTotal();
      string stale_tickets[];
      ArrayResize(stale_tickets, 0);

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
            int n = ArraySize(stale_tickets);
            ArrayResize(stale_tickets, n + 1);
            stale_tickets[n] = ticket_str;
         }
      }

      for(int i = 0; i < ArraySize(stale_tickets); i++)
      {
         string t = stale_tickets[i];
         GlobalVariableDel("P1_InitSL_" + t);
         GlobalVariableDel("P1_SigID_" + t);
         GlobalVariableDel("P1_Lot_" + t);
         GlobalVariableDel("P1_MFE_" + t);
         GlobalVariableDel("P1_MAE_" + t);
         GlobalVariableDel("P1_TP1_" + t);
         GlobalVariableDel("P1_TP2_" + t);
         GlobalVariableDel("P1_BE_" + t);
      }
   }

private:
   double SumClosedProfitSince(datetime since)
   {
      if(!HistorySelect(since, TimeCurrent()))
         return 0.0;

      double total = 0.0;
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
      {
         ulong deal_ticket = HistoryDealGetTicket(i);
         if(deal_ticket == 0) continue;
         if(HistoryDealGetInteger(deal_ticket, DEAL_MAGIC) != m_magic) continue;
         if(HistoryDealGetString(deal_ticket, DEAL_SYMBOL) != m_symbol) continue;

         long entry_type = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
         if(entry_type != DEAL_ENTRY_OUT && entry_type != DEAL_ENTRY_OUT_BY) continue;

         total += HistoryDealGetDouble(deal_ticket, DEAL_PROFIT)
                + HistoryDealGetDouble(deal_ticket, DEAL_SWAP)
                + HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
      }
      return total;
   }

   int CountDecimals(double step)
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
