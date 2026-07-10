//+------------------------------------------------------------------+
//| Volatility.mqh                                                    |
//| ATR calculation and a simple volatility-regime classifier.        |
//+------------------------------------------------------------------+
#property strict

enum ENUM_VOL_REGIME
{
   VOL_LOW,
   VOL_NORMAL,
   VOL_HIGH
};

class CVolatility
{
private:
   string m_symbol;
   int    m_atr_handle;
   int    m_regime_lookback;
   double m_regime_high_ratio;
   double m_regime_low_ratio;

public:
   CVolatility() : m_atr_handle(INVALID_HANDLE) {}

   bool Init(string symbol, ENUM_TIMEFRAMES tf, int atr_period, int regime_lookback,
             double regime_high_ratio = 1.3, double regime_low_ratio = 0.7)
   {
      m_symbol             = symbol;
      m_regime_lookback     = regime_lookback;
      m_regime_high_ratio   = regime_high_ratio;
      m_regime_low_ratio    = regime_low_ratio;
      m_atr_handle          = iATR(m_symbol, tf, atr_period);
      return (m_atr_handle != INVALID_HANDLE);
   }

   void Deinit()
   {
      if(m_atr_handle != INVALID_HANDLE)
      {
         IndicatorRelease(m_atr_handle);
         m_atr_handle = INVALID_HANDLE;
      }
   }

   // ATR value `shift` bars back. Entry/exit logic must use shift>=1 (the last
   // closed bar) -- shift=0 is the still-forming bar and will repaint.
   double GetATR(int shift)
   {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(m_atr_handle, 0, shift, 1, buf) != 1)
         return -1.0;
      return buf[0];
   }

   // Current ATR (at `shift`) vs. its own trailing average over
   // m_regime_lookback bars (including itself).
   ENUM_VOL_REGIME GetRegime(int shift)
   {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(m_atr_handle, 0, shift, m_regime_lookback, buf) != m_regime_lookback)
         return VOL_NORMAL;

      double current = buf[0];
      double sum = 0.0;
      for(int i = 0; i < m_regime_lookback; i++)
         sum += buf[i];
      double avg = sum / m_regime_lookback;

      if(avg <= 0)
         return VOL_NORMAL;

      double ratio = current / avg;
      if(ratio >= m_regime_high_ratio) return VOL_HIGH;
      if(ratio <= m_regime_low_ratio)  return VOL_LOW;
      return VOL_NORMAL;
   }

   string RegimeToString(ENUM_VOL_REGIME regime)
   {
      switch(regime)
      {
         case VOL_LOW:    return "low";
         case VOL_HIGH:   return "high";
         default:         return "normal";
      }
   }
};
//+------------------------------------------------------------------+
