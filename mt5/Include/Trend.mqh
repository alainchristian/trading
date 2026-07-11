//+------------------------------------------------------------------+
//| Trend.mqh                                                          |
//| D1 strategic direction: EMA 50/200 relationship for direction,      |
//| ADX for trend strength (conventional two-threshold usage: below     |
//| the sideways floor = genuinely ranging regardless of EMA noise;     |
//| above it, direction comes from EMA, STRONG vs WEAK from the         |
//| higher trend threshold). This enum maps directly onto the market-   |
//| regime classification the AI will later refine (Phase 3) -- keep    |
//| the definition stable rather than renaming it.                      |
//|                                                                       |
//| Earlier version additionally required a D1 swing-structure check    |
//| (2 confirmed higher-highs/higher-lows, or the inverse) to AGREE      |
//| with the EMA direction before returning anything but SIDEWAYS.       |
//| Empirically (see docs/phase-log.md walk-forward diagnostic) that     |
//| compounded AND-gate classified 60-67% of all H1 bars as SIDEWAYS,    |
//| producing near-zero trade frequency even over full-year windows --  |
//| removed in favor of the simpler, conventional ADX-only sideways      |
//| floor below. Structure/swing detection remains available via        |
//| CStructure for S/R zones (EntryLogic step 3) and structure-based     |
//| trailing (ExitManager) -- only its use as a Trend-classification     |
//| gate was removed.                                                    |
//+------------------------------------------------------------------+
#property strict

enum ENUM_TREND
{
   TREND_STRONG_UP,
   TREND_WEAK_UP,
   TREND_STRONG_DOWN,
   TREND_WEAK_DOWN,
   TREND_SIDEWAYS
};

class CTrend
{
private:
   string m_symbol;
   int    m_ema_fast_handle;
   int    m_ema_slow_handle;
   int    m_adx_handle;
   double m_adx_trend_threshold;
   double m_adx_sideways_threshold;

public:
   CTrend() : m_ema_fast_handle(INVALID_HANDLE), m_ema_slow_handle(INVALID_HANDLE), m_adx_handle(INVALID_HANDLE) {}

   // `timeframe` defaults to D1 -- Phase 1's own usage is untouched. Added so
   // Phase 1b's mean-reversion regime filter can reuse this exact
   // classification (same EMA/ADX logic, same sideways threshold) on H4
   // instead, per the user's confirmed choice, without redefining the
   // threshold or duplicating the class.
   bool Init(string symbol, int ema_fast_period, int ema_slow_period, int adx_period,
             double adx_trend_threshold, double adx_sideways_threshold,
             ENUM_TIMEFRAMES timeframe = PERIOD_D1)
   {
      m_symbol                 = symbol;
      m_adx_trend_threshold    = adx_trend_threshold;
      m_adx_sideways_threshold = adx_sideways_threshold;

      m_ema_fast_handle = iMA(m_symbol, timeframe, ema_fast_period, 0, MODE_EMA, PRICE_CLOSE);
      m_ema_slow_handle = iMA(m_symbol, timeframe, ema_slow_period, 0, MODE_EMA, PRICE_CLOSE);
      m_adx_handle      = iADX(m_symbol, timeframe, adx_period);

      return (m_ema_fast_handle != INVALID_HANDLE && m_ema_slow_handle != INVALID_HANDLE
              && m_adx_handle != INVALID_HANDLE);
   }

   void Deinit()
   {
      if(m_ema_fast_handle != INVALID_HANDLE) { IndicatorRelease(m_ema_fast_handle); m_ema_fast_handle = INVALID_HANDLE; }
      if(m_ema_slow_handle != INVALID_HANDLE) { IndicatorRelease(m_ema_slow_handle); m_ema_slow_handle = INVALID_HANDLE; }
      if(m_adx_handle != INVALID_HANDLE)      { IndicatorRelease(m_adx_handle);      m_adx_handle = INVALID_HANDLE; }
   }

   // Raw D1 EMA fast/slow relationship, independent of ADX/structure -- used
   // by EntryLogic to pick a candidate direction to evaluate checks 2-6
   // against even when Classify() below would call the trend non-directional
   // (checks 2-6 must still be independently evaluated and logged per bar).
   bool GetD1EmaBullish(bool &valid)
   {
      double ema_fast[], ema_slow[];
      ArraySetAsSeries(ema_fast, true);
      ArraySetAsSeries(ema_slow, true);

      if(CopyBuffer(m_ema_fast_handle, 0, 1, 1, ema_fast) != 1) { valid = false; return false; }
      if(CopyBuffer(m_ema_slow_handle, 0, 1, 1, ema_slow) != 1) { valid = false; return false; }

      valid = true;
      return ema_fast[0] > ema_slow[0];
   }

   // Classifies D1 trend as of the most recently CLOSED daily bar (shift=1).
   // ADX below m_adx_sideways_threshold = genuinely ranging (SIDEWAYS)
   // regardless of which way the EMAs happen to be ordered (that ordering is
   // noise in a range). Otherwise direction comes from the EMA relationship,
   // and STRONG vs WEAK from the higher m_adx_trend_threshold.
   ENUM_TREND Classify()
   {
      double ema_fast[], ema_slow[], adx[];
      ArraySetAsSeries(ema_fast, true);
      ArraySetAsSeries(ema_slow, true);
      ArraySetAsSeries(adx, true);

      if(CopyBuffer(m_ema_fast_handle, 0, 1, 1, ema_fast) != 1) return TREND_SIDEWAYS;
      if(CopyBuffer(m_ema_slow_handle, 0, 1, 1, ema_slow) != 1) return TREND_SIDEWAYS;
      if(CopyBuffer(m_adx_handle, 0, 1, 1, adx) != 1)           return TREND_SIDEWAYS;

      if(adx[0] <= m_adx_sideways_threshold)
         return TREND_SIDEWAYS;

      bool ema_bullish = ema_fast[0] > ema_slow[0];
      bool trending    = adx[0] > m_adx_trend_threshold;

      if(ema_bullish)
         return trending ? TREND_STRONG_UP : TREND_WEAK_UP;

      return trending ? TREND_STRONG_DOWN : TREND_WEAK_DOWN;
   }

   string ToString(ENUM_TREND t)
   {
      switch(t)
      {
         case TREND_STRONG_UP:   return "strong_up";
         case TREND_WEAK_UP:     return "weak_up";
         case TREND_STRONG_DOWN: return "strong_down";
         case TREND_WEAK_DOWN:   return "weak_down";
         default:                return "sideways";
      }
   }

   // Coarse label matching signals.d1_trend's ('bullish'/'bearish'/'sideways').
   string ToCoarseString(ENUM_TREND t)
   {
      switch(t)
      {
         case TREND_STRONG_UP:
         case TREND_WEAK_UP:     return "bullish";
         case TREND_STRONG_DOWN:
         case TREND_WEAK_DOWN:   return "bearish";
         default:                return "sideways";
      }
   }
};
//+------------------------------------------------------------------+
