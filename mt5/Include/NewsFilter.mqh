//+------------------------------------------------------------------+
//| NewsFilter.mqh                                                     |
//| Togglable (InpUseNewsFilter) high-impact-news blackout, using       |
//| MQL5's Calendar API. Terminal build 5.0.0.5975 is modern enough to  |
//| support calendar data in Strategy Tester, so this runs as a real    |
//| filter (not a live-only stub) -- but data AVAILABILITY (is the      |
//| local calendar cache actually populated on this box) is a separate  |
//| question from API availability, hence the OnInit smoke test below.  |
//+------------------------------------------------------------------+
#property strict

class CNewsFilter
{
private:
   bool   m_enabled;
   string m_base_currency;
   string m_quote_currency;
   int    m_buffer_minutes_before;
   int    m_buffer_minutes_after;

public:
   bool Init(string symbol, bool enabled, int buffer_minutes_before, int buffer_minutes_after)
   {
      m_enabled               = enabled;
      m_buffer_minutes_before = buffer_minutes_before;
      m_buffer_minutes_after  = buffer_minutes_after;

      m_base_currency  = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
      m_quote_currency = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);

      if(m_enabled)
         SmokeTest();

      return true;
   }

   // Queries a known historical high-impact event (a real past NFP date) and
   // logs the result count. CalendarValueHistory can return successfully
   // with zero/incomplete events if the tester's local calendar cache was
   // never synced from MetaQuotes' servers on this box -- "no error" is not
   // proof the filter is actually doing anything, so this makes that
   // failure mode visible rather than silent.
   void SmokeTest()
   {
      datetime known_nfp = D'2024.01.05 00:00:00'; // first Friday of Jan 2024 -- a real NFP release date
      MqlCalendarValue values[];
      int count = CalendarValueHistory(values, known_nfp - 86400, known_nfp + 86400, NULL, "USD");
      PrintFormat("NewsFilter smoke test: %d USD calendar events found around %s (0 suggests an unpopulated/stale local calendar cache -- verify before trusting InpUseNewsFilter=true)",
                  count, TimeToString(known_nfp, TIME_DATE));
   }

   bool IsAllowed(datetime t, string &reject_reason)
   {
      if(!m_enabled)
         return true;

      datetime from = t - m_buffer_minutes_before * 60;
      datetime to   = t + m_buffer_minutes_after * 60;

      if(HasHighImpactEvent(from, to, m_base_currency) || HasHighImpactEvent(from, to, m_quote_currency))
      {
         reject_reason = "news_event_nearby";
         return false;
      }
      return true;
   }

private:
   bool HasHighImpactEvent(datetime from, datetime to, string currency)
   {
      if(StringLen(currency) == 0)
         return false;

      MqlCalendarValue values[];
      int count = CalendarValueHistory(values, from, to, NULL, currency);
      if(count <= 0)
         return false;

      for(int i = 0; i < count; i++)
      {
         MqlCalendarEvent event;
         if(!CalendarEventById(values[i].event_id, event))
            continue;
         if(event.importance == CALENDAR_IMPORTANCE_HIGH)
            return true;
      }
      return false;
   }
};
//+------------------------------------------------------------------+
