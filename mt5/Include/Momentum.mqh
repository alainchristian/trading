//+------------------------------------------------------------------+
//| Momentum.mqh                                                      |
//| RSI / MACD / ADX confluence helpers on H1 (and RSI on H4), all     |
//| thresholds configurable -- not hardcoded to one instrument.        |
//+------------------------------------------------------------------+
#property strict

class CMomentum
{
private:
   string m_symbol;
   int    m_rsi_h1_handle;
   int    m_rsi_h4_handle;
   int    m_macd_h1_handle;
   int    m_adx_h1_handle;

public:
   CMomentum() : m_rsi_h1_handle(INVALID_HANDLE), m_rsi_h4_handle(INVALID_HANDLE),
                 m_macd_h1_handle(INVALID_HANDLE), m_adx_h1_handle(INVALID_HANDLE) {}

   bool Init(string symbol, int rsi_period, int macd_fast, int macd_slow, int macd_signal, int adx_period)
   {
      m_symbol = symbol;

      m_rsi_h1_handle  = iRSI(m_symbol, PERIOD_H1, rsi_period, PRICE_CLOSE);
      m_rsi_h4_handle  = iRSI(m_symbol, PERIOD_H4, rsi_period, PRICE_CLOSE);
      m_macd_h1_handle = iMACD(m_symbol, PERIOD_H1, macd_fast, macd_slow, macd_signal, PRICE_CLOSE);
      m_adx_h1_handle  = iADX(m_symbol, PERIOD_H1, adx_period);

      return (m_rsi_h1_handle != INVALID_HANDLE && m_rsi_h4_handle != INVALID_HANDLE
              && m_macd_h1_handle != INVALID_HANDLE && m_adx_h1_handle != INVALID_HANDLE);
   }

   void Deinit()
   {
      if(m_rsi_h1_handle != INVALID_HANDLE)  { IndicatorRelease(m_rsi_h1_handle);  m_rsi_h1_handle = INVALID_HANDLE; }
      if(m_rsi_h4_handle != INVALID_HANDLE)  { IndicatorRelease(m_rsi_h4_handle);  m_rsi_h4_handle = INVALID_HANDLE; }
      if(m_macd_h1_handle != INVALID_HANDLE) { IndicatorRelease(m_macd_h1_handle); m_macd_h1_handle = INVALID_HANDLE; }
      if(m_adx_h1_handle != INVALID_HANDLE)  { IndicatorRelease(m_adx_h1_handle);  m_adx_h1_handle = INVALID_HANDLE; }
   }

   double GetRSI_H1(int shift) { return CopySingle(m_rsi_h1_handle, 0, shift); }
   double GetRSI_H4(int shift) { return CopySingle(m_rsi_h4_handle, 0, shift); }
   double GetMACDMain(int shift)   { return CopySingle(m_macd_h1_handle, 0, shift); }
   double GetMACDSignal(int shift) { return CopySingle(m_macd_h1_handle, 1, shift); }
   double GetADX_H1(int shift)     { return CopySingle(m_adx_h1_handle, 0, shift); }

   // EntryLogic step 4: "H1 momentum confirms (RSI not extended against the
   // trade direction, e.g. RSI < threshold and recovering for a long)."
   // For a long: RSI must be below `rsi_threshold` (not overbought) AND
   // recovering -- current RSI above its own low over the last
   // `recovery_lookback` bars (excluding the current one). Short mirrors
   // around (100 - rsi_threshold), recovering down from its recent high.
   //
   // Originally compared only against the single immediately-prior bar
   // (curr > prev), which is close to a coinflip given bar-to-bar RSI noise
   // and empirically had a ~2% conditional pass rate -- the tightest of all
   // six confluence checks by a wide margin (see docs/phase-log.md
   // walk-forward diagnostic). Checking recovery against a short rolling
   // window's extreme instead captures the same "pullback and turn" idea
   // without being this sensitive to single-bar noise.
   bool RSIConfirms(bool is_buy, int shift, double rsi_threshold, int recovery_lookback = 5)
   {
      double curr = GetRSI_H1(shift);
      if(curr < 0)
         return false;

      if(is_buy)
      {
         if(curr >= rsi_threshold)
            return false;

         double lowest = 100.0;
         bool have_data = false;
         for(int i = 1; i <= recovery_lookback; i++)
         {
            double v = GetRSI_H1(shift + i);
            if(v < 0) continue;
            have_data = true;
            lowest = MathMin(lowest, v);
         }
         return have_data && (curr > lowest);
      }

      if(curr <= (100.0 - rsi_threshold))
         return false;

      double highest = 0.0;
      bool have_data = false;
      for(int i = 1; i <= recovery_lookback; i++)
      {
         double v = GetRSI_H1(shift + i);
         if(v < 0) continue;
         have_data = true;
         highest = MathMax(highest, v);
      }
      return have_data && (curr < highest);
   }

   // Optional supplementary confirmation (not part of the mandatory 6-step
   // checklist, but available for tuning): MACD main above/below signal line.
   bool MACDConfirms(bool is_buy, int shift)
   {
      double main   = GetMACDMain(shift);
      double signal = GetMACDSignal(shift);
      if(main == EMPTY_VALUE || signal == EMPTY_VALUE)
         return false;

      return is_buy ? (main > signal) : (main < signal);
   }

private:
   double CopySingle(int handle, int buffer_index, int shift)
   {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(handle == INVALID_HANDLE || CopyBuffer(handle, buffer_index, shift, 1, buf) != 1)
         return -1.0;
      return buf[0];
   }
};
//+------------------------------------------------------------------+
