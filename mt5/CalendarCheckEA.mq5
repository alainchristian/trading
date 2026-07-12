//+------------------------------------------------------------------+
//| CalendarCheckEA.mq5                                               |
//| Read-only, no trading. Free check (Step 0.2 of the macro/rate-    |
//| differential test) of what this broker's LIVE MT5 Economic       |
//| Calendar actually returns, before evaluating any paid calendar    |
//| source. Must run on a live/demo chart via /config startup (NOT    |
//| the Strategy Tester -- CalendarValueHistory is already confirmed  |
//| (Phase 1, NewsFilter smoke test) to return -1/unreliable there).  |
//| For each of USD/EUR/GBP/JPY/AUD, reports: event count and event-  |
//| name coverage in a recent window (is the local cache populated   |
//| at all, and does it include CPI/NFP/GDP/rate-decision events),    |
//| actual/forecast/previous field population rate in that window,   |
//| and separately, counts in a deep-historical window (years ago)   |
//| and a forward-looking window, to establish whether any local     |
//| depth exists beyond "recent + upcoming".                          |
//+------------------------------------------------------------------+
#property strict

string g_currencies[] = {"USD", "EUR", "GBP", "JPY", "AUD"};

void CheckWindow(string currency, string label, datetime from, datetime to,
                  bool check_fields, bool check_keywords)
{
   MqlCalendarValue values[];
   int count = CalendarValueHistory(values, from, to, NULL, currency);

   if(count <= 0)
   {
      PrintFormat("CAL|%s|%s|count=%d|(no events returned)", currency, label, count);
      return;
   }

   int actual_ok = 0, forecast_ok = 0, prev_ok = 0;
   bool seen_cpi = false, seen_nfp = false, seen_gdp = false, seen_rate = false;
   datetime earliest = to, latest = from;

   for(int i = 0; i < count; i++)
   {
      if(values[i].time < earliest) earliest = values[i].time;
      if(values[i].time > latest)   latest   = values[i].time;

      if(check_fields)
      {
         // Raw long fields, not the GetXxxValue() convenience methods (this
         // terminal build's actual signature is a no-arg `double GetActualValue()`,
         // not the bool-with-outparam form some MQL5 docs show -- confirmed via
         // the compiler's own "wrong parameters count" + built-in signature dump).
         // LONG_MIN marks "not yet published", per MqlCalendarValue's documented
         // convention.
         if(values[i].actual_value   != LONG_MIN) actual_ok++;
         if(values[i].forecast_value != LONG_MIN) forecast_ok++;
         if(values[i].prev_value     != LONG_MIN) prev_ok++;
      }

      if(check_keywords)
      {
         MqlCalendarEvent ev;
         if(CalendarEventById(values[i].event_id, ev))
         {
            string n = ev.name;
            StringToUpper(n);
            if(StringFind(n, "CPI") >= 0 || StringFind(n, "CONSUMER PRICE") >= 0) seen_cpi = true;
            if(StringFind(n, "NONFARM") >= 0 || StringFind(n, "NON-FARM") >= 0 ||
               StringFind(n, "EMPLOYMENT CHANGE") >= 0 || StringFind(n, "UNEMPLOYMENT") >= 0) seen_nfp = true;
            if(StringFind(n, "GDP") >= 0 || StringFind(n, "GROSS DOMESTIC") >= 0) seen_gdp = true;
            if(StringFind(n, "RATE DECISION") >= 0 || StringFind(n, "INTEREST RATE") >= 0) seen_rate = true;
         }
      }
   }

   PrintFormat("CAL|%s|%s|count=%d|earliest=%s|latest=%s",
               currency, label, count, TimeToString(earliest, TIME_DATE), TimeToString(latest, TIME_DATE));

   if(check_fields)
      PrintFormat("CAL|%s|%s|actual_populated=%d/%d|forecast_populated=%d/%d|previous_populated=%d/%d",
                  currency, label, actual_ok, count, forecast_ok, count, prev_ok, count);

   if(check_keywords)
      PrintFormat("CAL|%s|%s|has_CPI=%s|has_NFP_or_employment=%s|has_GDP=%s|has_rate_decision=%s",
                  currency, label, seen_cpi ? "true" : "false", seen_nfp ? "true" : "false",
                  seen_gdp ? "true" : "false", seen_rate ? "true" : "false");
}

int OnInit()
{
   datetime now = TimeCurrent();

   for(int c = 0; c < ArraySize(g_currencies); c++)
   {
      string cur = g_currencies[c];

      // Recent window: last 90 days -- the window most likely to be locally
      // cached/synced if the calendar works live at all. Check field
      // population and named-event coverage here.
      CheckWindow(cur, "recent_90d", now - 90 * 86400, now, true, true);

      // Forward-looking window: next 60 days -- scheduled events, known in
      // advance (safe for Step 3's "days-to-next-decision" feature either way).
      CheckWindow(cur, "future_60d", now, now + 60 * 86400, false, true);

      // Deep historical window: a fixed decade-old quarter, to test whether
      // the local cache retains real historical depth or only recent/future.
      CheckWindow(cur, "deep_hist_2015Q1", D'2015.01.01 00:00:00', D'2015.04.01 00:00:00', true, true);
   }

   Print("CAL|DONE");
   return(INIT_SUCCEEDED);
}

void OnTick() {}
