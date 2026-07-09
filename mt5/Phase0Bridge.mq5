//+------------------------------------------------------------------+
//| Phase0Bridge.mq5                                                  |
//| Phase 0: proves EA -> Python bridge -> Postgres -> EA works.       |
//| Does nothing else. No indicators, no trading, no symbol data.      |
//+------------------------------------------------------------------+
#property copyright "Trading Platform - Phase 0"
#property version   "1.00"
#property strict

#define BRIDGE_URL     "http://127.0.0.1:8000/ping-db"
#define TIMER_SECONDS  30
#define LOG_FILE       "Phase0Bridge\\heartbeat.log"

int OnInit()
{
   EventSetTimer(TIMER_SECONDS);
   Print("Phase0Bridge started. Heartbeat every ", TIMER_SECONDS, "s to ", BRIDGE_URL);
   WriteLog("EA initialized");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   WriteLog("EA stopped, reason=" + IntegerToString(reason));
}

void OnTick()
{
   // Intentionally empty for Phase 0 - no per-tick logic.
}

void OnTimer()
{
   string headers = "";
   char   post[];
   char   result[];
   string result_headers;

   ResetLastError();
   int status = WebRequest("GET", BRIDGE_URL, headers, 5000, post, result, result_headers);

   if(status == -1)
   {
      int err = GetLastError();
      string msg = StringFormat("HEARTBEAT FAILED: WebRequest error %d (is the URL allow-listed and is the bridge running?)", err);
      Print(msg);
      WriteLog(msg);
      return;
   }

   if(status != 200)
   {
      string body = CharArrayToString(result);
      string msg = StringFormat("HEARTBEAT FAILED: HTTP %d, body=%s", status, body);
      Print(msg);
      WriteLog(msg);
      return;
   }

   string body = CharArrayToString(result);
   string msg = StringFormat("HEARTBEAT OK: HTTP %d, body=%s", status, body);
   Print(msg);
   WriteLog(msg);
}

void WriteLog(string message)
{
   int fh = FileOpen(LOG_FILE, FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
   if(fh == INVALID_HANDLE)
   {
      Print("Phase0Bridge: could not open log file, error ", GetLastError());
      return;
   }
   FileSeek(fh, 0, SEEK_END);
   FileWrite(fh, TimeToString(TimeLocal(), TIME_DATE|TIME_SECONDS) + "  " + message);
   FileClose(fh);
}
//+------------------------------------------------------------------+
