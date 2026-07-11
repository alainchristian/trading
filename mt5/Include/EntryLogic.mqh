//+------------------------------------------------------------------+
//| EntryLogic.mqh                                                     |
//| The six-step confluence checklist. Every check runs and is logged  |
//| independently on every closed H1 bar -- never short-circuited --   |
//| so Phase 3's ML training gets full negative examples, not just a   |
//| single collapsed pass/fail. Direction for checks 2-6 is taken from |
//| the raw D1 EMA relationship even if check 1 (full trend            |
//| classification) itself fails, so a bar with no clear D1 trend      |
//| still gets all six checks evaluated against a candidate direction. |
//+------------------------------------------------------------------+
#property strict

#include "Trend.mqh"
#include "Structure.mqh"
#include "Momentum.mqh"
#include "Volatility.mqh"

// STRATEGY NOTE (see docs/phase-log.md, Phase 1 addendum Step 2): STRICT_SAME_BAR
// requires momentum/candlestick/volume to all fire on the exact same H1 bar
// close. ROLLING_WINDOW instead allows each of those three to fire
// independently on any bar within a short trailing window, on the hypothesis
// that a real setup develops over a few bars rather than landing all at
// once. D1 trend, H4 setup, and the zone/structure check remain evaluated at
// the current bar in both modes -- only the three faster/trigger-type checks
// are affected. This is a TIMING change, isolated from any threshold change,
// so its effect on trade frequency can be attributed cleanly.
enum ENUM_CONFLUENCE_MODE
{
   CONFLUENCE_STRICT_SAME_BAR,
   CONFLUENCE_ROLLING_WINDOW
};

struct Signal
{
   string   symbol;
   datetime signal_time;
   string   direction;         // "buy" / "sell"
   string   d1_trend;          // coarse: bullish/bearish/sideways
   bool     h4_setup_valid;
   string   h1_entry_trigger;  // pattern name, or "" if none found
   double   atr_value;
   double   proposed_entry;    // filled in below only if all 6 pass
   double   proposed_sl;       // left for RiskManager to fill in
   double   proposed_tp1;      // left for RiskManager to fill in
   double   proposed_tp2;      // left for RiskManager to fill in
   double   spread_at_signal;
   string   session;           // filled in by SessionFilter, always (for logging)
   double   risk_percent;      // filled in by RiskManager, always (for logging)
   double   lot_size;          // filled in by RiskManager, 0 if never sized
   bool     taken;             // true only if every gate (6 checks + session/spread/risk) passes

   bool     check1_d1_trend_pass;
   bool     check2_h4_confluence_pass;
   bool     check3_structure_pass;
   bool     check4_momentum_pass;
   bool     check5_candlestick_pass;
   bool     check6_volume_pass;

   bool     all_checks_passed;
   string   rejection_reason;  // "" if all_checks_passed
   string   features_json;     // full feature snapshot for signals.features
};

class CEntryLogic
{
private:
   string m_symbol;
   bool   m_allow_weak_trend;
   int    m_swing_lookback;
   double m_zone_tolerance_atr_mult;
   double m_impulse_atr_mult;
   double m_rsi_threshold;
   double m_pin_wick_ratio;
   double m_pin_upper_wick_max_ratio;
   double m_pin_body_max_ratio;
   double m_pin_close_zone;
   bool   m_require_volume_increase;
   ENUM_CONFLUENCE_MODE m_confluence_mode;
   int    m_rolling_window_bars;

   int    m_ema50_h4_handle;

public:
   CEntryLogic() : m_ema50_h4_handle(INVALID_HANDLE) {}

   bool Init(string symbol, bool allow_weak_trend, int swing_lookback,
             double zone_tolerance_atr_mult, double impulse_atr_mult,
             double rsi_threshold, double pin_wick_ratio,
             double pin_upper_wick_max_ratio, double pin_body_max_ratio,
             double pin_close_zone, bool require_volume_increase,
             ENUM_CONFLUENCE_MODE confluence_mode = CONFLUENCE_STRICT_SAME_BAR,
             int rolling_window_bars = 3)
   {
      m_symbol                   = symbol;
      m_allow_weak_trend         = allow_weak_trend;
      m_swing_lookback           = swing_lookback;
      m_zone_tolerance_atr_mult  = zone_tolerance_atr_mult;
      m_impulse_atr_mult         = impulse_atr_mult;
      m_rsi_threshold            = rsi_threshold;
      m_pin_wick_ratio           = pin_wick_ratio;
      m_pin_upper_wick_max_ratio = pin_upper_wick_max_ratio;
      m_pin_body_max_ratio       = pin_body_max_ratio;
      m_pin_close_zone           = pin_close_zone;
      m_require_volume_increase  = require_volume_increase;
      m_confluence_mode          = confluence_mode;
      m_rolling_window_bars      = MathMax(1, rolling_window_bars);

      m_ema50_h4_handle = iMA(m_symbol, PERIOD_H4, 50, 0, MODE_EMA, PRICE_CLOSE);

      return (m_ema50_h4_handle != INVALID_HANDLE);
   }

   void Deinit()
   {
      if(m_ema50_h4_handle != INVALID_HANDLE) { IndicatorRelease(m_ema50_h4_handle); m_ema50_h4_handle = INVALID_HANDLE; }
   }

   // Evaluates all six confluence checks for the just-closed H1 bar (shift=1).
   // Caller (Phase1EA.mq5) must only invoke this once per new H1 bar close.
   Signal Evaluate(CTrend &trend, CStructure &structure, CMomentum &momentum, CVolatility &volatility)
   {
      Signal sig;
      ZeroSignal(sig);

      sig.symbol      = m_symbol;
      sig.signal_time = iTime(m_symbol, PERIOD_H1, 1);

      double atr = volatility.GetATR(1);
      sig.atr_value = atr;

      bool ema_valid = false;
      bool is_buy = trend.GetD1EmaBullish(ema_valid);
      sig.direction = is_buy ? "buy" : "sell";

      // Step 1: D1 trend must be directional (STRONG_*, or WEAK_* if allowed).
      ENUM_TREND d1 = trend.Classify();
      sig.d1_trend = trend.ToCoarseString(d1);
      sig.check1_d1_trend_pass = ema_valid
         && ((d1 == TREND_STRONG_UP || d1 == TREND_STRONG_DOWN)
             || (m_allow_weak_trend && (d1 == TREND_WEAK_UP || d1 == TREND_WEAK_DOWN)));

      // Step 2: H4 confirms same direction with a pullback/continuation setup
      // (not a fresh breakout without a pullback).
      bool h4_valid = ema_valid && H4SetupValid(is_buy);
      sig.h4_setup_valid = h4_valid;
      sig.check2_h4_confluence_pass = h4_valid;

      // Step 3: price at/near a key H4 S/R level or supply/demand zone.
      double zone_low = 0.0, zone_high = 0.0;
      bool zone_found = structure.FindLastImpulseZone(PERIOD_H4, 1, 60, atr, m_impulse_atr_mult, is_buy, zone_low, zone_high);
      double last_close = iClose(m_symbol, PERIOD_H1, 1);
      double tolerance = (atr > 0) ? atr * m_zone_tolerance_atr_mult : 0.0;
      sig.check3_structure_pass = zone_found && structure.IsPriceInZone(last_close, zone_low, zone_high, tolerance);

      // Steps 4-6: momentum, candlestick trigger, tick-volume increase.
      // STRICT_SAME_BAR requires all three on shift=1 (the same bar as each
      // other). ROLLING_WINDOW allows each to fire independently on any bar
      // within the trailing window -- see the ENUM_CONFLUENCE_MODE note
      // above. Steps 1-3 are unaffected by the mode in both cases.
      string pattern = "";
      if(m_confluence_mode == CONFLUENCE_STRICT_SAME_BAR)
      {
         sig.check4_momentum_pass = momentum.RSIConfirms(is_buy, 1, m_rsi_threshold);
         sig.check5_candlestick_pass = DetectCandlestickTrigger(is_buy, 1, pattern);
         sig.check6_volume_pass = !m_require_volume_increase || TickVolumeIncreased(1);
      }
      else
      {
         sig.check4_momentum_pass = MomentumWindowPass(is_buy, momentum);
         sig.check5_candlestick_pass = CandlestickWindowPass(is_buy, pattern);
         sig.check6_volume_pass = !m_require_volume_increase || VolumeWindowPass();
      }
      sig.h1_entry_trigger = pattern;

      sig.all_checks_passed = sig.check1_d1_trend_pass && sig.check2_h4_confluence_pass
                               && sig.check3_structure_pass && sig.check4_momentum_pass
                               && sig.check5_candlestick_pass && sig.check6_volume_pass;

      if(!sig.check1_d1_trend_pass)           sig.rejection_reason = "d1_trend_not_directional";
      else if(!sig.check2_h4_confluence_pass) sig.rejection_reason = "h4_setup_invalid";
      else if(!sig.check3_structure_pass)     sig.rejection_reason = "not_at_key_level";
      else if(!sig.check4_momentum_pass)      sig.rejection_reason = "momentum_not_confirmed";
      else if(!sig.check5_candlestick_pass)   sig.rejection_reason = "no_candlestick_trigger";
      else if(!sig.check6_volume_pass)        sig.rejection_reason = "no_volume_confirmation";
      else                                     sig.rejection_reason = "";

      // Always set, not just when all 6 pass -- maximizes negative-example
      // richness for later ML training at near-zero extra cost.
      sig.proposed_entry = last_close;

      sig.features_json = BuildFeaturesJson(sig, momentum, volatility, zone_low, zone_high);

      return sig;
   }

private:
   void ZeroSignal(Signal &sig)
   {
      sig.h4_setup_valid       = false;
      sig.h1_entry_trigger     = "";
      sig.atr_value            = 0.0;
      sig.proposed_entry       = 0.0;
      sig.proposed_sl          = 0.0;
      sig.proposed_tp1         = 0.0;
      sig.proposed_tp2         = 0.0;
      sig.spread_at_signal     = (double)SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
      sig.check1_d1_trend_pass = false;
      sig.check2_h4_confluence_pass = false;
      sig.check3_structure_pass = false;
      sig.check4_momentum_pass = false;
      sig.check5_candlestick_pass = false;
      sig.check6_volume_pass = false;
      sig.all_checks_passed = false;
      sig.rejection_reason = "";
      sig.features_json = "";
   }

   // Note: "confirms same direction" is checked against price vs. the
   // SLOWER H4 EMA (50), not the EMA20/50 cross -- the fast cross flips
   // during a genuine pullback almost by definition (that's what a pullback
   // is), so requiring it to still agree with `is_buy` was systematically
   // excluding the exact pullback setups this check exists to confirm
   // (see docs/phase-log.md walk-forward diagnostic: this was the dominant
   // rejection reason once the D1 trend gate was loosened). Checking price
   // against the slower average instead confirms the broader H4 trend is
   // still intact while tolerating the faster average dipping through it.
   bool H4SetupValid(bool is_buy)
   {
      double slow[];
      ArraySetAsSeries(slow, true);

      if(CopyBuffer(m_ema50_h4_handle, 0, 1, 1, slow) != 1) return false;

      double last_close_h4 = iClose(m_symbol, PERIOD_H4, 1);
      bool price_confirms = is_buy ? (last_close_h4 > slow[0]) : (last_close_h4 < slow[0]);
      if(!price_confirms)
         return false;

      // Pullback check: the last closed H4 bar must NOT be a new N-bar extreme
      // in the trend direction -- that would be a fresh breakout, not a
      // pullback/continuation setup.
      const int lookback = 10;
      double extreme = is_buy ? iHigh(m_symbol, PERIOD_H4, 2) : iLow(m_symbol, PERIOD_H4, 2);
      for(int i = 3; i <= lookback + 1; i++)
      {
         double v = is_buy ? iHigh(m_symbol, PERIOD_H4, i) : iLow(m_symbol, PERIOD_H4, i);
         extreme = is_buy ? MathMax(extreme, v) : MathMin(extreme, v);
      }

      double last = is_buy ? iHigh(m_symbol, PERIOD_H4, 1) : iLow(m_symbol, PERIOD_H4, 1);
      bool is_fresh_breakout = is_buy ? (last > extreme) : (last < extreme);

      return !is_fresh_breakout;
   }

public:
   // Exactly two candlestick triggers for v1 (engulfing, pin bar), per the
   // doc's "pick 2-3, not an exhaustive library" guidance. A third
   // (inside-bar breakout) is deliberately deferred until walk-forward
   // testing shows the first two aren't enough.
   //
   // Public (not private, like the rest of this section) so Phase 1b's
   // mean-reversion entry logic can reuse this exact, already-tested pattern
   // detection for its own reversal-confirmation check, via a small
   // CEntryLogic instance created solely for this method -- rather than
   // duplicating the pattern logic in a new module.
   bool DetectCandlestickTrigger(bool is_buy, int shift, string &pattern_out)
   {
      double o1 = iOpen(m_symbol, PERIOD_H1, shift);
      double c1 = iClose(m_symbol, PERIOD_H1, shift);
      double h1 = iHigh(m_symbol, PERIOD_H1, shift);
      double l1 = iLow(m_symbol, PERIOD_H1, shift);
      double o2 = iOpen(m_symbol, PERIOD_H1, shift + 1);
      double c2 = iClose(m_symbol, PERIOD_H1, shift + 1);

      // Engulfing: trigger candle's body fully engulfs the prior candle's
      // body, and the two candles are opposite-colored.
      if(is_buy)
      {
         bool prior_bearish   = c2 < o2;
         bool trigger_bullish = c1 > o1;
         bool engulfs         = (o1 < c2) && (c1 > o2);
         if(prior_bearish && trigger_bullish && engulfs)
         {
            pattern_out = "bullish_engulfing";
            return true;
         }
      }
      else
      {
         bool prior_bullish   = c2 > o2;
         bool trigger_bearish = c1 < o1;
         bool engulfs         = (o1 > c2) && (c1 < o2);
         if(prior_bullish && trigger_bearish && engulfs)
         {
            pattern_out = "bearish_engulfing";
            return true;
         }
      }

      // Pin bar / rejection candle: long wick against the trigger direction,
      // small body, close near the opposite extreme of the range.
      double body  = MathAbs(c1 - o1);
      double range = h1 - l1;
      if(range <= 0)
         return false;

      double lower_wick = MathMin(o1, c1) - l1;
      double upper_wick = h1 - MathMax(o1, c1);
      double close_pos  = (c1 - l1) / range; // 0 = at low, 1 = at high

      if(is_buy)
      {
         bool is_pin = (lower_wick >= m_pin_wick_ratio * body)
                       && (upper_wick <= m_pin_upper_wick_max_ratio * range)
                       && (body <= m_pin_body_max_ratio * range)
                       && (close_pos >= m_pin_close_zone);
         if(is_pin)
         {
            pattern_out = "bullish_pin_bar";
            return true;
         }
      }
      else
      {
         bool is_pin = (upper_wick >= m_pin_wick_ratio * body)
                       && (lower_wick <= m_pin_upper_wick_max_ratio * range)
                       && (body <= m_pin_body_max_ratio * range)
                       && (close_pos <= (1.0 - m_pin_close_zone));
         if(is_pin)
         {
            pattern_out = "bearish_pin_bar";
            return true;
         }
      }

      return false;
   }

private:
   bool TickVolumeIncreased(int shift)
   {
      long v_curr = iVolume(m_symbol, PERIOD_H1, shift);
      long v_prev = iVolume(m_symbol, PERIOD_H1, shift + 1);
      return v_curr > v_prev;
   }

   // ROLLING_WINDOW helpers: each checks whether its underlying condition
   // fires on ANY bar within [1 .. m_rolling_window_bars], independently of
   // the other two checks and independently of which bar each one fires on.
   bool MomentumWindowPass(bool is_buy, CMomentum &momentum)
   {
      for(int s = 1; s <= m_rolling_window_bars; s++)
         if(momentum.RSIConfirms(is_buy, s, m_rsi_threshold))
            return true;
      return false;
   }

   bool CandlestickWindowPass(bool is_buy, string &pattern_out)
   {
      for(int s = 1; s <= m_rolling_window_bars; s++)
      {
         string p = "";
         if(DetectCandlestickTrigger(is_buy, s, p))
         {
            pattern_out = p;
            return true;
         }
      }
      pattern_out = "";
      return false;
   }

   bool VolumeWindowPass()
   {
      for(int s = 1; s <= m_rolling_window_bars; s++)
         if(TickVolumeIncreased(s))
            return true;
      return false;
   }

   string BoolStr(bool b) { return b ? "true" : "false"; }

   string BuildFeaturesJson(Signal &sig, CMomentum &momentum, CVolatility &volatility,
                             double zone_low, double zone_high)
   {
      int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);

      string json = "{";
      json += "\"check1_d1_trend\":" + BoolStr(sig.check1_d1_trend_pass) + ",";
      json += "\"check2_h4_confluence\":" + BoolStr(sig.check2_h4_confluence_pass) + ",";
      json += "\"check3_structure\":" + BoolStr(sig.check3_structure_pass) + ",";
      json += "\"check4_momentum\":" + BoolStr(sig.check4_momentum_pass) + ",";
      json += "\"check5_candlestick\":" + BoolStr(sig.check5_candlestick_pass) + ",";
      json += "\"check6_volume\":" + BoolStr(sig.check6_volume_pass) + ",";
      json += "\"rsi_h1\":" + DoubleToString(momentum.GetRSI_H1(1), 2) + ",";
      json += "\"rsi_h4\":" + DoubleToString(momentum.GetRSI_H4(1), 2) + ",";
      json += "\"adx_h1\":" + DoubleToString(momentum.GetADX_H1(1), 2) + ",";
      json += "\"vol_regime\":\"" + volatility.RegimeToString(volatility.GetRegime(1)) + "\",";
      json += "\"zone_low\":" + DoubleToString(zone_low, digits) + ",";
      json += "\"zone_high\":" + DoubleToString(zone_high, digits);
      json += "}";
      return json;
   }
};
//+------------------------------------------------------------------+
