//+------------------------------------------------------------------+
//| BridgeLogger.mqh                                                   |
//| Wraps WebRequest calls to the FastAPI bridge (/log-signal,         |
//| /log-trade, PATCH /log-trade/{ticket}, GET /trades/{ticket},       |
//| /log-risk-state). Logging must NEVER block or fail a trade         |
//| decision: on any failure (unreachable, non-200, WebRequest error)  |
//| it falls back to a local file log and returns -- callers proceed   |
//| either way, per the doc's explicit requirement. Uses plain         |
//| (non-FILE_COMMON) FileOpen so the fallback log stays inside this   |
//| terminal instance's own MQL5\Files, isolated from the unrelated    |
//| C:\forex-system terminal on this box.                              |
//+------------------------------------------------------------------+
#property strict

#include "EntryLogic.mqh" // Signal struct

class CBridgeLogger
{
private:
   string m_base_url;
   string m_log_file;
   int    m_timeout_ms;
   int    m_log_handle;

   // Opened once (Init) and kept open for the EA's lifetime (Deinit closes
   // it) instead of FileOpen/FileClose per line. Re-opening the same file on
   // every single write was fine at small sizes, but over a multi-decade
   // backtest the fallback log grows past 100MB and the per-write
   // open/seek/close cost stopped being negligible -- a full-history
   // Strategy Tester run was clocked at ~11x slower than linear scaling from
   // a 1-year run would predict (see docs/phase-log.md, Phase 1 addendum
   // Step 3). Holding one handle open and only seeking to end per write
   // removes the repeated-open cost entirely.
   void WriteLocalLog(string message)
   {
      if(m_log_handle == INVALID_HANDLE)
      {
         m_log_handle = FileOpen(m_log_file, FILE_WRITE | FILE_READ | FILE_TXT);
         if(m_log_handle == INVALID_HANDLE)
         {
            Print("BridgeLogger: could not open local fallback log, error ", GetLastError());
            return;
         }
      }
      FileSeek(m_log_handle, 0, SEEK_END);
      FileWrite(m_log_handle, TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS) + "  " + message);
   }

   // Returns the HTTP status, or -1 on a WebRequest-level failure (not
   // allow-listed, bridge unreachable, etc). Always safe to call.
   int SendRequest(string method, string url, string json_body, string &response_body)
   {
      string headers = "Content-Type: application/json\r\n";
      char post[];
      if(StringLen(json_body) > 0)
      {
         int len = StringToCharArray(json_body, post, 0, -1, CP_UTF8) - 1;
         ArrayResize(post, len);
      }
      char result[];
      string result_headers;

      ResetLastError();
      int status = WebRequest(method, url, headers, m_timeout_ms, post, result, result_headers);

      if(status == -1)
      {
         int err = GetLastError();
         WriteLocalLog(StringFormat("%s %s FAILED: WebRequest error %d, body=%s", method, url, err, json_body));
         return -1;
      }

      response_body = CharArrayToString(result);
      if(status < 200 || status >= 300)
         WriteLocalLog(StringFormat("%s %s FAILED: HTTP %d, request=%s, response=%s", method, url, status, json_body, response_body));

      return status;
   }

public:
   CBridgeLogger() : m_log_handle(INVALID_HANDLE) {}

   bool Init(string base_url, string log_file, int timeout_ms = 3000)
   {
      m_base_url   = base_url;
      m_log_file   = log_file;
      m_timeout_ms = timeout_ms;
      return true;
   }

   void Deinit()
   {
      if(m_log_handle != INVALID_HANDLE)
      {
         FileClose(m_log_handle);
         m_log_handle = INVALID_HANDLE;
      }
   }

   // --- POST /log-signal --- returns the new Postgres row id, or -1 if the
   // bridge was unreachable (local fallback log was written instead; the
   // caller must not block the trade decision on this).
   long LogSignal(Signal &sig)
   {
      string json = "{";
      json += "\"symbol\":" + Json(sig.symbol) + ",";
      json += "\"signal_time\":" + Json(IsoTime(sig.signal_time)) + ",";
      json += "\"direction\":" + Json(sig.direction) + ",";
      json += "\"d1_trend\":" + Json(sig.d1_trend) + ",";
      json += "\"h4_setup_valid\":" + Bool(sig.h4_setup_valid) + ",";
      json += "\"h1_entry_trigger\":" + JsonOrNull(sig.h1_entry_trigger) + ",";
      json += "\"atr_value\":" + Num(sig.atr_value) + ",";
      json += "\"proposed_entry\":" + Num(sig.proposed_entry) + ",";
      json += "\"proposed_sl\":" + Num(sig.proposed_sl) + ",";
      json += "\"proposed_tp1\":" + Num(sig.proposed_tp1) + ",";
      json += "\"proposed_tp2\":" + Num(sig.proposed_tp2) + ",";
      json += "\"risk_percent\":" + Num(sig.risk_percent) + ",";
      json += "\"lot_size\":" + Num(sig.lot_size) + ",";
      json += "\"spread_at_signal\":" + Num(sig.spread_at_signal) + ",";
      json += "\"session\":" + JsonOrNull(sig.session) + ",";
      json += "\"taken\":" + Bool(sig.taken) + ",";
      json += "\"rejection_reason\":" + JsonOrNull(sig.rejection_reason) + ",";
      json += "\"features\":" + (StringLen(sig.features_json) > 0 ? sig.features_json : "null");
      json += "}";

      string response;
      int status = SendRequest("POST", m_base_url + "/log-signal", json, response);
      if(status != 200)
         return -1;

      double id_double;
      if(!ExtractJsonNumber(response, "id", id_double))
         return -1;
      return (long)id_double;
   }

   // --- POST /log-signal, generic JSON variant --- for strategies that don't
   // share Phase 1's Signal struct/field names (e.g. Phase 1b's mean-
   // reversion checks) but still want the same request/fallback-log
   // machinery. Caller builds the full JSON body itself using the Json/Num/
   // Bool/JsonOrNull/IsoTime helpers below (all public for this reason).
   long LogSignalJson(string json)
   {
      return PostJsonForId("/log-signal", json);
   }

   // --- Generic POST-JSON-get-id, for any bridge endpoint that returns
   // {"id": N} --- e.g. /log-context from ContextSnapshotEA.mq5. Same
   // request/fallback-log machinery as every other logger method here.
   long PostJsonForId(string endpoint, string json)
   {
      string response;
      int status = SendRequest("POST", m_base_url + endpoint, json, response);
      if(status != 200)
         return -1;

      double id_double;
      if(!ExtractJsonNumber(response, "id", id_double))
         return -1;
      return (long)id_double;
   }

   // --- POST /log-trade (open) ---
   void LogTradeOpen(string strategy_variant, long signal_id, ulong ticket, string symbol, string direction,
                      datetime open_time, double open_price, double initial_sl,
                      double initial_tp1, double initial_tp2, double lot_size)
   {
      string json = "{";
      json += "\"strategy_variant\":" + Json(strategy_variant) + ",";
      json += "\"signal_id\":" + (signal_id > 0 ? IntegerToString(signal_id) : "null") + ",";
      json += "\"ticket\":" + IntegerToString((long)ticket) + ",";
      json += "\"symbol\":" + Json(symbol) + ",";
      json += "\"direction\":" + Json(direction) + ",";
      json += "\"open_time\":" + Json(IsoTime(open_time)) + ",";
      json += "\"open_price\":" + Num(open_price) + ",";
      json += "\"initial_sl\":" + Num(initial_sl) + ",";
      json += "\"initial_tp1\":" + Num(initial_tp1) + ",";
      json += "\"initial_tp2\":" + Num(initial_tp2) + ",";
      json += "\"lot_size\":" + Num(lot_size);
      json += "}";

      string response;
      SendRequest("POST", m_base_url + "/log-trade", json, response);
   }

   // --- PATCH /log-trade/{ticket} ---
   // `fields_json` is a pre-built JSON object of just the fields to update
   // (callers vary: a partial-close MFE/MAE update vs. a full-close update
   // with exit_reason/profit/r_multiple) -- build it with the Num/Json
   // helpers below. NOTE: verify empirically (Stage 4) that WebRequest
   // accepts "PATCH" as a method string on this build; if not, this needs to
   // switch to a full-resource POST/PUT convention.
   void PatchTrade(ulong ticket, string fields_json)
   {
      string response;
      SendRequest("PATCH", m_base_url + "/log-trade/" + IntegerToString((long)ticket), fields_json, response);
   }

   // --- GET /trades/{ticket} --- last-resort reconciliation only, used when
   // a position's GlobalVariable state was lost (see RiskManager.mqh).
   bool GetTradeInitialSL(ulong ticket, double &initial_sl_out)
   {
      string response;
      int status = SendRequest("GET", m_base_url + "/trades/" + IntegerToString((long)ticket), "", response);
      if(status != 200)
         return false;

      return ExtractJsonNumber(response, "initial_sl", initial_sl_out);
   }

   // --- POST /log-event --- generic audit-trail record (e.g. partial
   // closes, which don't get their own trades/signals columns).
   void LogEvent(string source, string event_type, string payload_json)
   {
      string json = "{";
      json += "\"source\":" + Json(source) + ",";
      json += "\"event_type\":" + Json(event_type) + ",";
      json += "\"payload\":" + (StringLen(payload_json) > 0 ? payload_json : "null");
      json += "}";

      string response;
      SendRequest("POST", m_base_url + "/log-event", json, response);
   }

   // --- POST /log-risk-state ---
   void LogRiskState(string trading_date, string scope, double starting_balance,
                      double realized_pnl, bool loss_limit_hit, bool trading_halted)
   {
      string json = "{";
      json += "\"trading_date\":" + Json(trading_date) + ",";
      json += "\"scope\":" + Json(scope) + ",";
      json += "\"starting_balance\":" + Num(starting_balance) + ",";
      json += "\"realized_pnl\":" + Num(realized_pnl) + ",";
      json += "\"loss_limit_hit\":" + Bool(loss_limit_hit) + ",";
      json += "\"trading_halted\":" + Bool(trading_halted);
      json += "}";

      string response;
      SendRequest("POST", m_base_url + "/log-risk-state", json, response);
   }

   // --- JSON helpers (public: RiskManager/ExitManager build PATCH bodies with these) ---
   string Json(string s)       { return "\"" + EscapeJson(s) + "\""; }
   string JsonOrNull(string s) { return StringLen(s) > 0 ? Json(s) : "null"; }
   string Num(double d)        { return DoubleToString(d, 8); }
   string Bool(bool b)         { return b ? "true" : "false"; }

   string IsoTime(datetime t)
   {
      MqlDateTime dt;
      TimeToStruct(t, dt);
      return StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ", dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);
   }

private:
   string EscapeJson(string s)
   {
      string result = s;
      StringReplace(result, "\\", "\\\\");
      StringReplace(result, "\"", "\\\"");
      return result;
   }

   // Minimal numeric-field extraction for our own bridge's known JSON shape
   // (not a general JSON parser -- MQL5 has none built in, and a full one is
   // unwarranted for this narrow, controlled use).
   bool ExtractJsonNumber(string json, string key, double &value_out)
   {
      string search = "\"" + key + "\":";
      int pos = StringFind(json, search);
      if(pos < 0)
         return false;

      int start = pos + StringLen(search);
      int len   = StringLen(json);
      int end   = start;
      while(end < len)
      {
         ushort ch = StringGetCharacter(json, end);
         if(ch == ',' || ch == '}')
            break;
         end++;
      }

      string num_str = StringSubstr(json, start, end - start);
      StringTrimLeft(num_str);
      StringTrimRight(num_str);
      if(num_str == "null" || StringLen(num_str) == 0)
         return false;

      value_out = StringToDouble(num_str);
      return true;
   }
};
//+------------------------------------------------------------------+
