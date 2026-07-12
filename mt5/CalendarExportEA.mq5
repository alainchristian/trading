//+------------------------------------------------------------------+
//| CalendarExportEA.mq5                                              |
//| Read-only, no trading. Step 1 (H2 rescoped) of the macro/rate-    |
//| differential test: exports actual CPI/NFP/GDP/rate-decision event |
//| rows (currency, name, category, release time, actual/previous     |
//| value, importance) for USD/EUR/GBP/JPY/AUD from 2015-01-01 to now, |
//| to a pipe-delimited log file for import into macro_calendar_events.|
//| Must run live (not Strategy Tester -- CalendarValueHistory already |
//| confirmed unreliable there, Phase 1's NewsFilter smoke test).      |
//| No consensus/forecast column -- confirmed unavailable historically |
//| (Step 0.2 CalendarCheckEA run); H2 was scoped down accordingly.    |
//+------------------------------------------------------------------+
#property strict

string g_currencies[] = {"USD", "EUR", "GBP", "JPY", "AUD"};
int    g_file_handle = INVALID_HANDLE;

string CategoryOf(string name)
{
   string n = name;
   StringToUpper(n);
   if(StringFind(n, "CPI") >= 0 || StringFind(n, "CONSUMER PRICE") >= 0)
      return "cpi";
   if(StringFind(n, "NONFARM") >= 0 || StringFind(n, "NON-FARM") >= 0 ||
      StringFind(n, "EMPLOYMENT CHANGE") >= 0 || StringFind(n, "UNEMPLOYMENT") >= 0)
      return "employment";
   if(StringFind(n, "GDP") >= 0 || StringFind(n, "GROSS DOMESTIC") >= 0)
      return "gdp";
   if(StringFind(n, "RATE DECISION") >= 0 || StringFind(n, "INTEREST RATE") >= 0)
      return "rate_decision";
   return "";  // not one of the four categories in scope -- skipped
}

void ExportCurrency(string currency, datetime from, datetime to)
{
   MqlCalendarValue values[];
   int count = CalendarValueHistory(values, from, to, NULL, currency);
   int written = 0;

   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;

      string category = CategoryOf(ev.name);
      if(category == "")
         continue;  // only the 4 categories in the H2 scope

      double actual_val   = (values[i].actual_value   != LONG_MIN) ? (double)values[i].actual_value   / MathPow(10, ev.digits) : 0;
      double previous_val  = (values[i].prev_value     != LONG_MIN) ? (double)values[i].prev_value     / MathPow(10, ev.digits) : 0;
      bool   has_actual   = (values[i].actual_value   != LONG_MIN);
      bool   has_previous = (values[i].prev_value     != LONG_MIN);

      string importance;
      switch(ev.importance)
      {
         case CALENDAR_IMPORTANCE_HIGH:     importance = "high"; break;
         case CALENDAR_IMPORTANCE_MODERATE: importance = "moderate"; break;
         default:                           importance = "low"; break;
      }

      FileWrite(g_file_handle, currency, ev.name, category,
                TimeToString(values[i].time, TIME_DATE | TIME_MINUTES),
                has_actual   ? DoubleToString(actual_val, 6)   : "NULL",
                has_previous ? DoubleToString(previous_val, 6) : "NULL",
                importance);
      written++;
   }

   PrintFormat("EXPORT|%s|from=%s|to=%s|raw_count=%d|written=%d",
               currency, TimeToString(from, TIME_DATE), TimeToString(to, TIME_DATE), count, written);
}

int OnInit()
{
   string filename = "CalendarExportEA\\calendar_export.log";
   g_file_handle = FileOpen(filename, FILE_WRITE | FILE_CSV | FILE_ANSI, "|");
   if(g_file_handle == INVALID_HANDLE)
   {
      PrintFormat("EXPORT|ERROR|cannot open output file, code=%d", GetLastError());
      return(INIT_FAILED);
   }

   datetime from = D'2015.01.01 00:00:00';
   datetime to   = TimeCurrent();

   for(int c = 0; c < ArraySize(g_currencies); c++)
      ExportCurrency(g_currencies[c], from, to);

   FileClose(g_file_handle);
   Print("EXPORT|DONE");
   return(INIT_SUCCEEDED);
}

void OnTick() {}
