//+------------------------------------------------------------------+
//| Structure.mqh                                                     |
//| Swing high/low detection (hand-rolled N-bar fractal, not the      |
//| built-in iFractals) plus basic S/R and supply/demand zone checks. |
//+------------------------------------------------------------------+
#property strict

struct SwingPoint
{
   datetime time;
   double   price;
   int      bar_shift;
};

class CStructure
{
private:
   string m_symbol;

public:
   void Init(string symbol) { m_symbol = symbol; }

   // Bar `shift` on `tf` is a confirmed swing high iff its High strictly exceeds
   // the High of `lookback` bars on both sides. A swing at `shift` can only be
   // confirmed once `lookback` newer bars have closed after it -- callers must
   // never query shift < lookback, since that swing isn't confirmed yet and
   // checking it would be lookahead bias.
   bool IsSwingHigh(ENUM_TIMEFRAMES tf, int shift, int lookback)
   {
      if(shift < lookback)
         return false;

      double high_center = iHigh(m_symbol, tf, shift);
      if(high_center <= 0)
         return false;

      for(int i = 1; i <= lookback; i++)
      {
         if(iHigh(m_symbol, tf, shift - i) >= high_center) return false;
         if(iHigh(m_symbol, tf, shift + i) >= high_center) return false;
      }
      return true;
   }

   bool IsSwingLow(ENUM_TIMEFRAMES tf, int shift, int lookback)
   {
      if(shift < lookback)
         return false;

      double low_center = iLow(m_symbol, tf, shift);
      if(low_center <= 0)
         return false;

      for(int i = 1; i <= lookback; i++)
      {
         if(iLow(m_symbol, tf, shift - i) <= low_center) return false;
         if(iLow(m_symbol, tf, shift + i) <= low_center) return false;
      }
      return true;
   }

   // Most recent confirmed swing high at or after `search_start_shift`, scanning
   // up to `max_bars_search` bars further back. `search_start_shift` should
   // already be >= lookback (typically 1 + lookback, the first shift that could
   // possibly be confirmed relative to the last closed bar).
   bool FindLastSwingHigh(ENUM_TIMEFRAMES tf, int lookback, int search_start_shift,
                           int max_bars_search, SwingPoint &out)
   {
      int first = MathMax(search_start_shift, lookback);
      for(int shift = first; shift < first + max_bars_search; shift++)
      {
         if(IsSwingHigh(tf, shift, lookback))
         {
            out.time      = iTime(m_symbol, tf, shift);
            out.price     = iHigh(m_symbol, tf, shift);
            out.bar_shift = shift;
            return true;
         }
      }
      return false;
   }

   bool FindLastSwingLow(ENUM_TIMEFRAMES tf, int lookback, int search_start_shift,
                          int max_bars_search, SwingPoint &out)
   {
      int first = MathMax(search_start_shift, lookback);
      for(int shift = first; shift < first + max_bars_search; shift++)
      {
         if(IsSwingLow(tf, shift, lookback))
         {
            out.time      = iTime(m_symbol, tf, shift);
            out.price     = iLow(m_symbol, tf, shift);
            out.bar_shift = shift;
            return true;
         }
      }
      return false;
   }

   // Simple market-structure check: collect the `swing_count` most recent
   // confirmed swing highs and lows (searching up to `max_bars_search` bars
   // back) and check whether both are rising (bullish structure) or both
   // falling (bearish structure), comparing the newest to the oldest collected.
   bool HasHigherHighsHigherLows(ENUM_TIMEFRAMES tf, int lookback, bool check_bullish,
                                  int swing_count = 2, int max_bars_search = 100)
   {
      SwingPoint highs[], lows[];
      ArrayResize(highs, 0);
      ArrayResize(lows, 0);

      int shift = lookback;
      int scanned = 0;
      while((ArraySize(highs) < swing_count || ArraySize(lows) < swing_count) && scanned < max_bars_search)
      {
         if(ArraySize(highs) < swing_count && IsSwingHigh(tf, shift, lookback))
         {
            int n = ArraySize(highs);
            ArrayResize(highs, n + 1);
            highs[n].time      = iTime(m_symbol, tf, shift);
            highs[n].price     = iHigh(m_symbol, tf, shift);
            highs[n].bar_shift = shift;
         }
         if(ArraySize(lows) < swing_count && IsSwingLow(tf, shift, lookback))
         {
            int n = ArraySize(lows);
            ArrayResize(lows, n + 1);
            lows[n].time      = iTime(m_symbol, tf, shift);
            lows[n].price     = iLow(m_symbol, tf, shift);
            lows[n].bar_shift = shift;
         }
         shift++;
         scanned++;
      }

      if(ArraySize(highs) < swing_count || ArraySize(lows) < swing_count)
         return false; // not enough confirmed structure yet in the search window

      int last_high = ArraySize(highs) - 1;
      int last_low  = ArraySize(lows) - 1;

      if(check_bullish)
         return (highs[0].price > highs[last_high].price) && (lows[0].price > lows[last_low].price);

      return (highs[0].price < highs[last_high].price) && (lows[0].price < lows[last_low].price);
   }

   // Basic supply/demand zone: the origin range (open-close body) of the last
   // strong impulse candle in `direction`, where "strong" means body size >=
   // impulse_atr_mult * atr_value. Deliberately simple v1 definition, per the
   // doc's guidance not to over-engineer this before it's shown to add value.
   bool FindLastImpulseZone(ENUM_TIMEFRAMES tf, int search_start_shift, int max_bars_search,
                             double atr_value, double impulse_atr_mult, bool bullish,
                             double &zone_low, double &zone_high)
   {
      if(atr_value <= 0)
         return false;

      for(int shift = search_start_shift; shift < search_start_shift + max_bars_search; shift++)
      {
         double o = iOpen(m_symbol, tf, shift);
         double c = iClose(m_symbol, tf, shift);
         double body = MathAbs(c - o);

         if(body < impulse_atr_mult * atr_value)
            continue;

         bool candle_bullish = c > o;
         if(candle_bullish != bullish)
            continue;

         zone_low  = MathMin(o, c);
         zone_high = MathMax(o, c);
         return true;
      }
      return false;
   }

   // Is `price` within `tolerance` of [zone_low, zone_high]?
   bool IsPriceInZone(double price, double zone_low, double zone_high, double tolerance)
   {
      return (price >= zone_low - tolerance) && (price <= zone_high + tolerance);
   }
};
//+------------------------------------------------------------------+
