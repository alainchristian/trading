//+------------------------------------------------------------------+
//| MeanReversionEntry.mqh                                            |
//| Phase 1b: five-check mean-reversion entry checklist. Each check    |
//| independently evaluated and logged, never short-circuited -- same  |
//| discipline as Phase 1's six-check EntryLogic.mqh, so this hypothesis|
//| can be diagnosed the same way if it needs to be.                   |
//|                                                                     |
//| Reuses, unmodified: Trend.mqh's ADX sideways threshold/classifier   |
//| (now timeframe-parameterized so it can run on H4 instead of D1),    |
//| Structure.mqh's swing detection, Momentum.mqh's RSI accessor, and   |
//| EntryLogic.mqh's candlestick-pattern detector (made public for      |
//| this reuse). New in this file: the band definition, the momentum-   |
//| extreme framing (opposite shape from Phase 1's pullback-recovery    |
//| check -- mean reversion wants the extreme itself, not a recovery    |
//| already underway), and the structural-level-integrity check.        |
//+------------------------------------------------------------------+
#property strict

#include "Trend.mqh"
#include "Structure.mqh"
#include "Momentum.mqh"
#include "Volatility.mqh"
#include "EntryLogic.mqh" // reused: CEntryLogic::DetectCandlestickTrigger only

struct MRSignal
{
   string   symbol;
   datetime signal_time;
   string   direction;          // "buy" / "sell" -- candidate direction (touched/nearer band)
   string   h4_regime;          // CTrend::ToString() on H4: "sideways", "strong_up", etc.
   bool     band_touch_valid;
   string   h1_entry_trigger;   // candlestick pattern name, or "" if none found
   double   atr_value;
   double   proposed_entry;     // last H1 close
   double   proposed_sl;        // filled in by caller (RiskManager reuse)
   double   proposed_tp;        // the SMA center at signal time -- a moving target,
                                 // re-read live by MeanReversionExit each bar, not a
                                 // static broker-side order
   double   sma_center;
   double   band_upper;
   double   band_lower;
   double   spread_at_signal;
   string   session;
   double   risk_percent;
   double   lot_size;
   bool     taken;

   bool     check1_regime_pass;
   bool     check2_band_touch_pass;
   bool     check3_momentum_extreme_pass;
   bool     check4_reversal_candle_pass;
   bool     check5_structure_not_broken_pass;

   bool     all_checks_passed;
   string   rejection_reason;
   string   features_json;
};

class CMeanReversionEntry
{
private:
   string m_symbol;
   int    m_sma_period;
   double m_sma_sd_mult;
   double m_rsi_threshold;
   int    m_swing_lookback;
   int    m_level_search_bars;
   int    m_level_crossing_lookback_bars;
   int    m_level_max_crossings;
   double m_level_tolerance_atr_mult;

   int    m_sma_handle;
   int    m_stddev_handle;

   CEntryLogic m_candle_helper; // Init'd only enough to reuse DetectCandlestickTrigger

public:
   CMeanReversionEntry() : m_sma_handle(INVALID_HANDLE), m_stddev_handle(INVALID_HANDLE) {}

   bool Init(string symbol, int sma_period, double sma_sd_mult, double rsi_threshold,
             int swing_lookback, int level_search_bars, int level_crossing_lookback_bars,
             int level_max_crossings, double level_tolerance_atr_mult,
             double pin_wick_ratio, double pin_upper_wick_max_ratio,
             double pin_body_max_ratio, double pin_close_zone)
   {
      m_symbol                        = symbol;
      m_sma_period                    = sma_period;
      m_sma_sd_mult                   = sma_sd_mult;
      m_rsi_threshold                 = rsi_threshold;
      m_swing_lookback                = swing_lookback;
      m_level_search_bars             = level_search_bars;
      m_level_crossing_lookback_bars  = level_crossing_lookback_bars;
      m_level_max_crossings           = level_max_crossings;
      m_level_tolerance_atr_mult      = level_tolerance_atr_mult;

      m_sma_handle    = iMA(m_symbol, PERIOD_H1, sma_period, 0, MODE_SMA, PRICE_CLOSE);
      m_stddev_handle = iStdDev(m_symbol, PERIOD_H1, sma_period, 0, MODE_SMA, PRICE_CLOSE);

      // Other CEntryLogic fields are irrelevant here -- this instance exists
      // solely to call the shared DetectCandlestickTrigger.
      m_candle_helper.Init(m_symbol, false, m_swing_lookback, 0.5, 1.5,
                            rsi_threshold, pin_wick_ratio, pin_upper_wick_max_ratio,
                            pin_body_max_ratio, pin_close_zone, false);

      return (m_sma_handle != INVALID_HANDLE && m_stddev_handle != INVALID_HANDLE);
   }

   void Deinit()
   {
      if(m_sma_handle != INVALID_HANDLE)    { IndicatorRelease(m_sma_handle);    m_sma_handle = INVALID_HANDLE; }
      if(m_stddev_handle != INVALID_HANDLE) { IndicatorRelease(m_stddev_handle); m_stddev_handle = INVALID_HANDLE; }
   }

   // Evaluates all five checks for the just-closed H1 bar (shift=1).
   // `h4_regime` must be a CTrend instance Init'd on PERIOD_H4.
   MRSignal Evaluate(CTrend &h4_regime, CStructure &structure, CMomentum &momentum, CVolatility &volatility)
   {
      MRSignal sig;
      ZeroSignal(sig);

      sig.symbol      = m_symbol;
      sig.signal_time = iTime(m_symbol, PERIOD_H1, 1);

      double atr = volatility.GetATR(1);
      sig.atr_value = atr;

      // Step 1: regime filter -- H4 ADX must classify as SIDEWAYS. Reuses
      // Trend.mqh's existing threshold/classification unmodified, just on H4.
      ENUM_TREND h4_trend = h4_regime.Classify();
      sig.h4_regime = h4_regime.ToString(h4_trend);
      sig.check1_regime_pass = (h4_trend == TREND_SIDEWAYS);

      // Step 2: band touch. 20-period SMA +/- 2.0 SD on H1 (user-confirmed
      // default). Candidate direction is whichever band was touched; if
      // neither (bar closed inside the bands), pick the nearer band purely
      // so checks 3-5 still have a determinate direction to evaluate against
      // and log -- matching Phase 1's "always evaluate every check" design.
      double sma[], sd[];
      ArraySetAsSeries(sma, true);
      ArraySetAsSeries(sd, true);
      bool have_bands = (CopyBuffer(m_sma_handle, 0, 1, 1, sma) == 1) && (CopyBuffer(m_stddev_handle, 0, 1, 1, sd) == 1);

      double last_close = iClose(m_symbol, PERIOD_H1, 1);
      double center = have_bands ? sma[0] : last_close;
      double upper  = have_bands ? center + m_sma_sd_mult * sd[0] : last_close;
      double lower  = have_bands ? center - m_sma_sd_mult * sd[0] : last_close;

      sig.sma_center = center;
      sig.band_upper = upper;
      sig.band_lower = lower;

      bool touch_lower = have_bands && (last_close <= lower);
      bool touch_upper = have_bands && (last_close >= upper);
      sig.check2_band_touch_pass = touch_lower || touch_upper;

      bool is_buy = touch_lower ? true : (touch_upper ? false : (MathAbs(last_close - lower) <= MathAbs(upper - last_close)));
      sig.direction = is_buy ? "buy" : "sell";
      sig.band_touch_valid = sig.check2_band_touch_pass;

      // Step 3: momentum extreme. Deliberately NOT Phase 1's RSIConfirms
      // (which requires recovery already underway from a rolling low/high --
      // the right shape for a trend pullback). Mean reversion wants the
      // extreme reading itself, at the moment of the band touch, so this is
      // a plain threshold check -- reusing the SAME threshold value
      // (m_rsi_threshold) Phase 1 uses, per the user's confirmed choice, but
      // a genuinely different (simpler) condition shape, stated here as the
      // reason for the change.
      double rsi = momentum.GetRSI_H1(1);
      sig.check3_momentum_extreme_pass = (rsi >= 0) && (is_buy ? (rsi <= m_rsi_threshold) : (rsi >= (100.0 - m_rsi_threshold)));

      // Step 4: reversal candlestick trigger -- reuses Phase 1's exact,
      // already-tested engulfing/pin-bar detector.
      string pattern = "";
      sig.check4_reversal_candle_pass = m_candle_helper.DetectCandlestickTrigger(is_buy, 1, pattern);
      sig.h1_entry_trigger = pattern;

      // Step 5: structural-level integrity -- REJECTS the setup (unlike
      // Phase 1's step 3, which required proximity to a level, this requires
      // absence of a level with a bad track record). Finds the nearest
      // confirmed swing low (long candidate) / swing high (short candidate)
      // within tolerance of the current close, then counts how many times
      // price has crossed through that exact level in the recent lookback --
      // a level breached repeatedly before is a weak candidate for "the
      // range holds this time". No nearby level found at all defaults to
      // PASS (nothing to reject on), not fail.
      double tolerance = (atr > 0) ? atr * m_level_tolerance_atr_mult : 0.0;
      bool level_bad = LevelRecentlyBrokenRepeatedly(is_buy, structure, last_close, tolerance);
      sig.check5_structure_not_broken_pass = !level_bad;

      sig.all_checks_passed = sig.check1_regime_pass && sig.check2_band_touch_pass
                               && sig.check3_momentum_extreme_pass && sig.check4_reversal_candle_pass
                               && sig.check5_structure_not_broken_pass;

      if(!sig.check1_regime_pass)              sig.rejection_reason = "h4_not_ranging";
      else if(!sig.check2_band_touch_pass)     sig.rejection_reason = "no_band_touch";
      else if(!sig.check3_momentum_extreme_pass) sig.rejection_reason = "momentum_not_extreme";
      else if(!sig.check4_reversal_candle_pass)  sig.rejection_reason = "no_reversal_candle";
      else if(!sig.check5_structure_not_broken_pass) sig.rejection_reason = "level_unreliable";
      else                                       sig.rejection_reason = "";

      sig.proposed_entry = last_close;
      sig.proposed_tp     = center; // SMA center -- re-evaluated live by the exit manager, not fixed here

      sig.features_json = BuildFeaturesJson(sig, momentum, volatility, rsi);

      return sig;
   }

private:
   void ZeroSignal(MRSignal &sig)
   {
      sig.band_touch_valid = false;
      sig.h1_entry_trigger  = "";
      sig.atr_value         = 0.0;
      sig.proposed_entry    = 0.0;
      sig.proposed_sl       = 0.0;
      sig.proposed_tp       = 0.0;
      sig.sma_center        = 0.0;
      sig.band_upper        = 0.0;
      sig.band_lower        = 0.0;
      sig.spread_at_signal  = (double)SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
      sig.check1_regime_pass = false;
      sig.check2_band_touch_pass = false;
      sig.check3_momentum_extreme_pass = false;
      sig.check4_reversal_candle_pass = false;
      sig.check5_structure_not_broken_pass = false;
      sig.all_checks_passed = false;
      sig.rejection_reason  = "";
      sig.features_json     = "";
   }

   // Finds the nearest confirmed swing low (is_buy) / swing high (!is_buy)
   // within `tolerance` of `price`, then counts H1 closes crossing that exact
   // level within the recent lookback window. Returns true (level judged
   // unreliable) if crossings >= m_level_max_crossings.
   bool LevelRecentlyBrokenRepeatedly(bool is_buy, CStructure &structure, double price, double tolerance)
   {
      SwingPoint sp;
      bool found = is_buy
         ? structure.FindLastSwingLow(PERIOD_H1, m_swing_lookback, m_swing_lookback + 1, m_level_search_bars, sp)
         : structure.FindLastSwingHigh(PERIOD_H1, m_swing_lookback, m_swing_lookback + 1, m_level_search_bars, sp);

      if(!found)
         return false; // no known level nearby to have a bad track record -- default PASS

      if(MathAbs(sp.price - price) > tolerance)
         return false; // nearest confirmed swing isn't actually close to this touch -- not the level in play

      int crossings = 0;
      bool prev_above = (iClose(m_symbol, PERIOD_H1, m_level_crossing_lookback_bars + 1) > sp.price);
      for(int shift = m_level_crossing_lookback_bars; shift >= 1; shift--)
      {
         bool above = (iClose(m_symbol, PERIOD_H1, shift) > sp.price);
         if(above != prev_above)
            crossings++;
         prev_above = above;
      }

      return crossings >= m_level_max_crossings;
   }

   string BoolStr(bool b) { return b ? "true" : "false"; }

   string BuildFeaturesJson(MRSignal &sig, CMomentum &momentum, CVolatility &volatility, double rsi)
   {
      int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);

      string json = "{";
      json += "\"check1_regime\":" + BoolStr(sig.check1_regime_pass) + ",";
      json += "\"check2_band_touch\":" + BoolStr(sig.check2_band_touch_pass) + ",";
      json += "\"check3_momentum_extreme\":" + BoolStr(sig.check3_momentum_extreme_pass) + ",";
      json += "\"check4_reversal_candle\":" + BoolStr(sig.check4_reversal_candle_pass) + ",";
      json += "\"check5_structure_not_broken\":" + BoolStr(sig.check5_structure_not_broken_pass) + ",";
      json += "\"rsi_h1\":" + DoubleToString(rsi, 2) + ",";
      json += "\"h4_regime\":\"" + sig.h4_regime + "\",";
      json += "\"sma_center\":" + DoubleToString(sig.sma_center, digits) + ",";
      json += "\"band_upper\":" + DoubleToString(sig.band_upper, digits) + ",";
      json += "\"band_lower\":" + DoubleToString(sig.band_lower, digits) + ",";
      json += "\"vol_regime\":\"" + volatility.RegimeToString(volatility.GetRegime(1)) + "\"";
      json += "}";
      return json;
   }
};
//+------------------------------------------------------------------+
