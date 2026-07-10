//+------------------------------------------------------------------+
//| SpreadFilter.mqh                                                   |
//| Rejects entries when the current spread exceeds a configurable     |
//| max, in broker points.                                             |
//+------------------------------------------------------------------+
#property strict

class CSpreadFilter
{
private:
   string m_symbol;
   long   m_max_spread_points;

public:
   void Init(string symbol, long max_spread_points)
   {
      m_symbol            = symbol;
      m_max_spread_points = max_spread_points;
   }

   long GetCurrentSpreadPoints()
   {
      return SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
   }

   bool IsAllowed(string &reject_reason)
   {
      if(GetCurrentSpreadPoints() > m_max_spread_points)
      {
         reject_reason = "spread_too_wide";
         return false;
      }
      return true;
   }
};
//+------------------------------------------------------------------+
