//+------------------------------------------------------------------+
//| SessionFilter.mqh                                                  |
//| London / NY / overlap / Asia / off-hours session classification.   |
//|                                                                      |
//| IMPORTANT: hour windows below are evaluated against TimeCurrent(),  |
//| which is BROKER SERVER TIME, not UTC. The server/UTC offset varies  |
//| by broker and shifts with DST (most brokers run GMT+2/GMT+3         |
//| depending on season) -- do not assume server time == UTC. Calibrate |
//| the *_start_hour/*_end_hour inputs against this specific broker's   |
//| actual server clock before trusting the defaults.                   |
//+------------------------------------------------------------------+
#property strict

class CSessionFilter
{
private:
   int  m_london_start_hour;
   int  m_london_end_hour;
   int  m_ny_start_hour;
   int  m_ny_end_hour;
   int  m_asia_start_hour;
   int  m_asia_end_hour;
   bool m_allow_london;
   bool m_allow_ny;
   bool m_allow_overlap;
   bool m_allow_asia;
   bool m_allow_off_hours;

public:
   void Init(int london_start_hour, int london_end_hour, int ny_start_hour, int ny_end_hour,
             int asia_start_hour, int asia_end_hour, bool allow_london, bool allow_ny,
             bool allow_overlap, bool allow_asia, bool allow_off_hours)
   {
      m_london_start_hour = london_start_hour;
      m_london_end_hour   = london_end_hour;
      m_ny_start_hour      = ny_start_hour;
      m_ny_end_hour        = ny_end_hour;
      m_asia_start_hour    = asia_start_hour;
      m_asia_end_hour      = asia_end_hour;
      m_allow_london    = allow_london;
      m_allow_ny        = allow_ny;
      m_allow_overlap   = allow_overlap;
      m_allow_asia      = allow_asia;
      m_allow_off_hours = allow_off_hours;
   }

   // Always computed for logging (signals.session), independent of whether
   // it's used as a gate.
   string GetSessionLabel(datetime t)
   {
      MqlDateTime dt;
      TimeToStruct(t, dt);
      int hour = dt.hour;

      bool in_london = InRange(hour, m_london_start_hour, m_london_end_hour);
      bool in_ny     = InRange(hour, m_ny_start_hour, m_ny_end_hour);
      bool in_asia   = InRange(hour, m_asia_start_hour, m_asia_end_hour);

      if(in_london && in_ny) return "overlap";
      if(in_london)          return "london";
      if(in_ny)               return "ny";
      if(in_asia)             return "asia";
      return "off_hours";
   }

   bool IsAllowed(datetime t, string &reject_reason)
   {
      string session = GetSessionLabel(t);
      bool allowed;

      if(session == "overlap")      allowed = m_allow_overlap;
      else if(session == "london")  allowed = m_allow_london;
      else if(session == "ny")      allowed = m_allow_ny;
      else if(session == "asia")    allowed = m_allow_asia;
      else                           allowed = m_allow_off_hours;

      if(!allowed)
         reject_reason = "outside_session";

      return allowed;
   }

private:
   bool InRange(int hour, int start_hour, int end_hour)
   {
      if(start_hour <= end_hour)
         return (hour >= start_hour) && (hour < end_hour);
      return (hour >= start_hour) || (hour < end_hour); // wraps past midnight
   }
};
//+------------------------------------------------------------------+
