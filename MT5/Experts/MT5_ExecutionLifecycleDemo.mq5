//+------------------------------------------------------------------+
//|                                   MT5_ExecutionLifecycleDemo.mq5 |
//|              Copyright 2026, Hamid Haddadian                      |
//|              https://github.com/Smc-AlgoTrading                  |
//+------------------------------------------------------------------+
//  PURPOSE
//  -------
//  A single-file case study of the MetaTrader 5 execution layer: the
//  part of an EA that decides whether an order can be sent at all, and
//  what actually happened after it was sent.
//
//  It contains NO trading strategy and makes NO profitability claim.
//  The entry trigger is a mechanical new-bar test, present only so the
//  execution path can be exercised.
//
//  WHAT IT DEMONSTRATES
//  --------------------
//  1. Per-symbol contract resolution (digits, tick size/value, volume
//     step, stops level, freeze level, execution mode, filling flags).
//  2. Filling-mode resolution that refuses to invent a mode the broker
//     does not advertise on Market Execution symbols.
//  3. Volume normalisation against SYMBOL_VOLUME_MIN/MAX/STEP plus a
//     pre-trade margin check with OrderCalcMargin().
//  4. Stop-loss / take-profit clamping against stops level and freeze
//     level, on the correct side of the market for the requested side.
//  5. One-request-in-flight guard, so a slow broker cannot receive the
//     same intent twice.
//  6. An OnTradeTransaction state machine that confirms the request with
//     the *deal* rather than with the return code, detects partial
//     fills, and measures the terminal-observed send-to-deal latency.
//  7. Append-only CSV audit log in MQL5/Files.
//
//  LATENCY NOTE
//  ------------
//  The only latency figure this file reports is measured, not claimed:
//  it is the delta between the trade call and the moment the terminal
//  delivers TRADE_TRANSACTION_DEAL_ADD. It excludes network and server
//  matching time by construction and is labelled as such in the CSV.
//
//  SAFETY
//  ------
//  InpDryRun defaults to true: every check runs, no order is sent. The
//  file never reads DLLs, never uses WebRequest, and never touches
//  another EA's positions (everything is scoped by symbol + magic).
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hamid Haddadian"
#property link      "https://github.com/Smc-AlgoTrading"
#property version   "1.00"
#property description "MetaTrader 5 execution lifecycle case study: contract rules, filling mode, margin, stops, deal confirmation. No strategy logic."
#property description "Ships with InpDryRun=true. Enable entries deliberately on a demo account."

#include <Trade\Trade.mqh>

//--- inputs ---------------------------------------------------------
input group           "Execution"
input bool            InpDryRun            = true;    // Dry run: run every check, send nothing
input long            InpMagic             = 770011;   // Magic number (scopes all orders to this EA)
input int             InpSlippagePoints    = 20;       // Deviation in points
input double          InpLots              = 0.10;     // Requested volume (normalised to symbol step)
input double          InpMarginBufferPct   = 30.0;     // Require this % of free margin to stay unused
input group           "Protection"
input double          InpStopLossPoints    = 300;      // Stop loss distance, in points
input double          InpTakeProfitPoints  = 600;      // Take profit distance, in points
input double          InpMaxSpreadPoints   = 40;       // Reject entries above this spread
input group           "Demo trigger"
input bool            InpDemoEntries       = false;    // Mechanical new-bar entry trigger (test only)
input group           "Logging"
input string          InpLogFileName       = "execution_lifecycle_audit.csv";

//+------------------------------------------------------------------+
//| Resolved contract rules for one symbol                           |
//+------------------------------------------------------------------+
struct SymbolContract
{
   string symbol;
   int    digits;
   double point;
   double tick_size;
   double tick_value;
   double vol_min;
   double vol_max;
   double vol_step;
   int    stops_level_pts;
   int    freeze_level_pts;
   long   exec_mode;        // SYMBOL_TRADE_EXECUTION_*
   long   filling_flags;    // SYMBOL_FILLING_MODE bitmask
};

//+------------------------------------------------------------------+
//| Contract resolution + the checks that must pass before sending   |
//+------------------------------------------------------------------+
class CExecutionSpec
{
private:
   string         m_reason;
   SymbolContract m_c;

public:
   CExecutionSpec(void) { m_reason = ""; ZeroMemory(m_c); }
   string   Reason(void) const { return(m_reason); }
   SymbolContract Contract(void) const { return(m_c); }
   string   Symbol(void) const { return(m_c.symbol); }

   //--- read every contract rule once, from the terminal, not from assumptions
   bool Load(const string symbol)
   {
      if(symbol == "") { m_reason = "empty_symbol"; return(false); }

      m_c.symbol            = symbol;
      m_c.digits            = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      m_c.point             = SymbolInfoDouble(symbol, SYMBOL_POINT);
      m_c.tick_size         = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      m_c.tick_value        = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      m_c.vol_min           = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      m_c.vol_max           = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      m_c.vol_step          = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      m_c.stops_level_pts   = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
      m_c.freeze_level_pts  = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
      m_c.exec_mode         = SymbolInfoInteger(symbol, SYMBOL_TRADE_EXEMODE);
      m_c.filling_flags     = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);

      if(m_c.point <= 0.0)                              { m_reason = "point_not_available";        return(false); }
      if(m_c.vol_step <= 0.0 || m_c.vol_max <= 0.0)     { m_reason = "volume_limits_not_available"; return(false); }
      if(!SymbolSelect(symbol, true))                   { m_reason = "symbol_not_in_market_watch";  return(false); }

      m_reason = "";
      return(true);
   }

   //--- FILLING MODE -------------------------------------------------
   // Market Execution symbols reject ORDER_FILLING_RETURN, and a symbol
   // that advertises neither FOK nor IOC cannot be traded with a market
   // order at this price. Returning false is the honest answer; guessing
   // FOK is how EAs fail on one broker and work on another.
   bool ResolveFilling(const ENUM_ORDER_TYPE type, ENUM_ORDER_TYPE_FILLING &mode)
   {
      if(m_c.exec_mode != SYMBOL_TRADE_EXECUTION_MARKET)
      {
         // Request / Instant / Exchange execution: RETURN is accepted and
         // is the only mode that tolerates a partial fill on a market order.
         mode = ORDER_FILLING_RETURN;
         return(true);
      }

      if((m_c.filling_flags & SYMBOL_FILLING_FOK) != 0) { mode = ORDER_FILLING_FOK; return(true); }
      if((m_c.filling_flags & SYMBOL_FILLING_IOC) != 0) { mode = ORDER_FILLING_IOC; return(true); }

      m_reason = "broker_advertises_no_market_filling_mode";
      return(false);
   }

   //--- VOLUME -------------------------------------------------------
   // Snap to the step grid, clamp to min/max, and re-snap so the server
   // never receives 0.30000000000000004.
   double NormaliseVolume(const double requested)
   {
      if(m_c.vol_step <= 0.0) return(0.0);

      double steps  = MathFloor(requested / m_c.vol_step + 1e-8);
      double volume = steps * m_c.vol_step;

      volume = MathMin(MathMax(volume, m_c.vol_min), m_c.vol_max);
      volume = MathFloor(volume / m_c.vol_step + 1e-8) * m_c.vol_step;

      return(NormalizeDouble(volume, 2));
   }

   //--- MARGIN -------------------------------------------------------
   // A trade that the server would reject for margin is not a trade;
   // check it locally first and keep a safety buffer untouched.
   bool HasMargin(const ENUM_ORDER_TYPE type, const double volume,
                  const double price, const double buffer_pct, double &margin_needed)
   {
      margin_needed = 0.0;
      if(volume <= 0.0) { m_reason = "zero_volume"; return(false); }

      if(!OrderCalcMargin(type, m_c.symbol, volume, price, margin_needed))
      { m_reason = "order_calc_margin_failed"; return(false); }

      if(margin_needed <= 0.0) { m_reason = "margin_not_reported"; return(false); }

      const double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      const double usable      = free_margin * (1.0 - MathMax(0.0, MathMin(buffer_pct, 95.0)) / 100.0);

      if(margin_needed > usable)
      {
         m_reason = StringFormat("insufficient_margin need=%.2f usable=%.2f", margin_needed, usable);
         return(false);
      }

      return(true);
   }

   //--- STOPS --------------------------------------------------------
   // Clamp SL/TP to the broker's minimum distance on the correct side.
   // Returns false only when the request is structurally wrong
   // (e.g. a buy stop-loss above the market by more than the level).
   bool NormaliseStops(const bool is_buy, const double ref_price,
                       double &sl, double &tp, bool &sl_moved, bool &tp_moved)
   {
      sl_moved = false;
      tp_moved = false;

      const double min_pts   = MathMax((double)m_c.stops_level_pts, (double)m_c.freeze_level_pts);
      const double min_dist  = min_pts * m_c.point;

      if(sl > 0.0)
      {
         const double lowest_ok  = ref_price - min_dist;
         const double highest_ok = ref_price + min_dist;

         if(is_buy)
         {
            if(sl > lowest_ok) { sl = lowest_ok; sl_moved = true; }
         }
         else
         {
            if(sl < highest_ok) { sl = highest_ok; sl_moved = true; }
         }
         sl = NormalizeDouble(sl, m_c.digits);
      }

      if(tp > 0.0)
      {
         if(is_buy)
         {
            const double lowest_tp = ref_price + min_dist;
            if(tp < lowest_tp) { tp = lowest_tp; tp_moved = true; }
         }
         else
         {
            const double highest_tp = ref_price - min_dist;
            if(tp > highest_tp) { tp = highest_tp; tp_moved = true; }
         }
         tp = NormalizeDouble(tp, m_c.digits);
      }

      if(is_buy && sl > 0.0 && tp > 0.0 && sl >= tp)
      { m_reason = "buy_stops_inverted"; return(false); }

      if(!is_buy && sl > 0.0 && tp > 0.0 && sl <= tp)
      { m_reason = "sell_stops_inverted"; return(false); }

      return(true);
   }

   //--- spread guard in points
   double SpreadPoints(void)
   {
      if(m_c.point <= 0.0) return(0.0);
      const double ask = SymbolInfoDouble(m_c.symbol, SYMBOL_ASK);
      const double bid = SymbolInfoDouble(m_c.symbol, SYMBOL_BID);
      return((ask - bid) / m_c.point);
   }
};

//+------------------------------------------------------------------+
//| Execution engine: one intent in flight, deal-confirmed outcome   |
//+------------------------------------------------------------------+
class CExecutionEngine
{
private:
   CTrade         m_trade;
   CExecutionSpec m_spec;
   string         m_symbol;
   long           m_magic;
   string         m_log_name;

   bool           m_request_in_flight;   // an intent was accepted and not yet confirmed by a deal
   ulong          m_request_id;
   ulong          m_request_order;
   ulong          m_request_deal;
   ulong          m_send_us;             // GetMicrosecondCount() at the trade call
   datetime       m_send_time;

   string         m_phase;               // IDLE / SENT / DEAL_SEEN / REJECTED
   datetime       m_last_dry_log;        // last dry-run audit row, for throttling
   int            m_dry_log_seconds;     // throttle window (seconds): one dry-run row per hour

   //--- append one row; the file is never truncated, so a restart does not
   //--- destroy the audit trail of earlier sessions
   void LogRow(const string event, const string detail,
               const double volume, const double price, const double latency_ms)
   {
      const int handle = FileOpen(m_log_name,
                                  FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ,
                                  ',');
      if(handle == INVALID_HANDLE)
      {
         PrintFormat("audit log unavailable (%s) error=%d", m_log_name, GetLastError());
         return;
      }

      FileSeek(handle, 0, SEEK_END);
      if(FileTell(handle) == 0)
      {
         FileWrite(handle,
                   "server_time", "symbol", "phase", "event",
                   "magic", "request_id", "order", "deal",
                   "volume", "price", "terminal_observed_ms", "detail");
      }

      FileWrite(handle,
                TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                m_symbol,
                m_phase,
                event,
                (string)m_magic,
                (string)m_request_id,
                (string)m_request_order,
                (string)m_request_deal,
                DoubleToString(volume, 2),
                DoubleToString(price, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS)),
                (latency_ms >= 0.0 ? DoubleToString(latency_ms, 1) : ""),
                detail);

      FileClose(handle);
   }

public:
   CExecutionEngine(void)
   {
      m_symbol = ""; m_magic = 0; m_log_name = "";
      m_request_in_flight = false;
      m_request_id = 0; m_request_order = 0; m_request_deal = 0;
      m_send_us = 0; m_send_time = 0;
      m_phase = "IDLE";
      m_last_dry_log = 0;
      m_dry_log_seconds = 3600;
   }

   bool Init(const string symbol, const long magic, const int slippage_points, const string log_name)
   {
      m_symbol   = symbol;
      m_magic    = magic;
      m_log_name = log_name;

      if(!m_spec.Load(symbol))
      {
         PrintFormat("Init failed: %s", m_spec.Reason());
         return(false);
      }

      m_trade.SetExpertMagicNumber((ulong)magic);
      m_trade.SetDeviationInPoints((ulong)slippage_points);
      m_trade.SetMarginMode();
      m_trade.SetAsyncMode(false);

      PrintFormat("%s | digits=%d point=%.*f vol[%.2f..%.2f step %.2f] stops=%dpt freeze=%dpt exec=%d filling_flags=%d",
                  symbol,
                  m_spec.Contract().digits,
                  m_spec.Contract().digits,
                  m_spec.Contract().point,
                  m_spec.Contract().vol_min,
                  m_spec.Contract().vol_max,
                  m_spec.Contract().vol_step,
                  m_spec.Contract().stops_level_pts,
                  m_spec.Contract().freeze_level_pts,
                  (int)m_spec.Contract().exec_mode,
                  (int)m_spec.Contract().filling_flags);

      m_phase = "IDLE";
      return(true);
   }

   //--- positions and orders scoped by symbol + magic only
   int OpenPositions(void) const
   {
      int n = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         const ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic)  continue;
         n++;
      }
      return(n);
   }

   bool RequestInFlight(void) const { return(m_request_in_flight); }
   string Phase(void) const { return(m_phase); }

   //--- the whole pre-trade gate, in one place, in one order
   bool Open(const ENUM_ORDER_TYPE type, const double requested_lots,
             const double sl_points, const double tp_points,
             const double max_spread_points, const double margin_buffer_pct,
             const bool dry_run, const string comment)
   {
      const SymbolContract c = m_spec.Contract();
      const bool is_buy      = (type == ORDER_TYPE_BUY);

      // 1. one intent at a time: a rejected-but-slow request must not be doubled
      if(m_request_in_flight)
      { m_phase = "REJECTED"; LogRow("rejected", "request_already_in_flight", 0, 0, -1); return(false); }

      // 2. spread
      const double spread = m_spec.SpreadPoints();
      if(max_spread_points > 0.0 && spread > max_spread_points)
      {
         m_phase = "REJECTED";
         LogRow("rejected", StringFormat("spread %.0fpt > %.0fpt", spread, max_spread_points), 0, 0, -1);
         return(false);
      }

      // 3. filling mode the broker actually advertises
      ENUM_ORDER_TYPE_FILLING filling;
      if(!m_spec.ResolveFilling(type, filling))
      { m_phase = "REJECTED"; LogRow("rejected", m_spec.Reason(), 0, 0, -1); return(false); }
      m_trade.SetTypeFilling(filling);

      // 4. volume on the step grid
      const double volume = m_spec.NormaliseVolume(requested_lots);
      if(volume <= 0.0)
      { m_phase = "REJECTED"; LogRow("rejected", "volume_normalised_to_zero", 0, 0, -1); return(false); }

      // 5. reference price for this side
      const double ref_price = (is_buy ? SymbolInfoDouble(m_symbol, SYMBOL_ASK)
                                       : SymbolInfoDouble(m_symbol, SYMBOL_BID));
      if(ref_price <= 0.0)
      { m_phase = "REJECTED"; LogRow("rejected", "no_price", 0, 0, -1); return(false); }

      // 6. margin, with a buffer left untouched
      double margin_needed = 0.0;
      if(!m_spec.HasMargin(type, volume, ref_price, margin_buffer_pct, margin_needed))
      { m_phase = "REJECTED"; LogRow("rejected", m_spec.Reason(), volume, ref_price, -1); return(false); }

      // 7. stops, clamped to the broker's distance rules
      double sl = (sl_points  > 0.0 ? ref_price + (is_buy ? -1.0 : 1.0) * sl_points * c.point : 0.0);
      double tp = (tp_points  > 0.0 ? ref_price + (is_buy ?  1.0 : -1.0) * tp_points * c.point : 0.0);
      bool   sl_moved = false, tp_moved = false;
      if(!m_spec.NormaliseStops(is_buy, ref_price, sl, tp, sl_moved, tp_moved))
      { m_phase = "REJECTED"; LogRow("rejected", m_spec.Reason(), volume, ref_price, -1); return(false); }

      // 8. dry run stops here on purpose: everything above is the real gate
      if(dry_run)
      {
         m_phase = "DRYRUN";

         // Nothing opens in dry run, so a naive log writes one row per bar (1,400 rows over three
         // weeks of M15). The decision is unchanged; only the audit row is throttled to hourly.
         if(m_last_dry_log > 0 && (TimeCurrent() - m_last_dry_log) < m_dry_log_seconds)
            return(true);

         LogRow("dry_run_pass",
                StringFormat("filling=%d sl=%.*f%s tp=%.*f%s margin=%.2f",
                             (int)filling,
                             c.digits, sl, (sl_moved ? "(clamped)" : ""),
                             c.digits, tp, (tp_moved ? "(clamped)" : ""),
                             margin_needed),
                volume, ref_price, -1);
         m_last_dry_log = TimeCurrent();
         return(true);
      }

      // 9. send
      m_send_us   = GetMicrosecondCount();
      m_send_time = TimeCurrent();
      m_phase     = "SENT";

      const bool sent = (is_buy ? m_trade.Buy(volume, m_symbol, 0.0, sl, tp, comment)
                                : m_trade.Sell(volume, m_symbol, 0.0, sl, tp, comment));

      const uint   rc      = m_trade.ResultRetcode();
      m_request_id         = 0;   // CTrade does not expose the id; captured from the transaction event
      m_request_order      = m_trade.ResultOrder();
      m_request_deal       = m_trade.ResultDeal();

      const bool accepted = sent &&
                            (rc == TRADE_RETCODE_DONE ||
                             rc == TRADE_RETCODE_DONE_PARTIAL ||
                             rc == TRADE_RETCODE_PLACED);

      if(!accepted)
      {
         m_phase = "REJECTED";
         LogRow("send_rejected",
                StringFormat("retcode=%u %s", rc, m_trade.ResultRetcodeDescription()),
                volume, ref_price, -1);
         return(false);
      }

      // DONE means the deal is already there; anything else waits for the
      // transaction, so the in-flight flag is only cleared by the event path.
      if(rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL)
      {
         m_request_in_flight = false;
         m_phase             = "DEAL_SEEN";
      }
      else
      {
         m_request_in_flight = true;
      }

      LogRow("send_accepted",
             StringFormat("retcode=%u filling=%d requested=%.2f sent=%.2f",
                          rc, (int)filling, requested_lots, volume),
             volume, ref_price, -1);

      return(true);
   }

   //--- the event path: the deal, not the return code, is the outcome
   void OnTransaction(const MqlTradeTransaction &trans, const MqlTradeResult &result)
   {
      if(trans.symbol != m_symbol) return;

      switch(trans.type)
      {
      case TRADE_TRANSACTION_ORDER_ADD:
         if(trans.order == m_request_order || m_request_order == 0)
            m_request_order = trans.order;
         break;

      case TRADE_TRANSACTION_DEAL_ADD:
      {
         if(!HistoryDealSelect(trans.deal)) break;

         const long   magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
         const long   entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         if(magic != m_magic) break;

         const double latency_ms = (double)(GetMicrosecondCount() - m_send_us) / 1000.0;
         const double deal_volume = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
         const double deal_price  = HistoryDealGetDouble(trans.deal, DEAL_PRICE);

         m_request_deal      = trans.deal;
         m_request_in_flight = false;
         m_phase             = "DEAL_SEEN";

         if(entry == DEAL_ENTRY_IN)
         {
            LogRow("deal_in",
                   StringFormat("deal_time=%s send_time=%s",
                                TimeToString((datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME),
                                             TIME_DATE | TIME_SECONDS),
                                TimeToString(m_send_time, TIME_DATE | TIME_SECONDS)),
                   deal_volume, deal_price, latency_ms);
         }
         else
         {
            LogRow("deal_out", "exit_fill", deal_volume, deal_price, latency_ms);
         }
         break;
      }

      case TRADE_TRANSACTION_ORDER_DELETE:
         // a cancelled/rejected order is also an outcome: release the guard
         if(trans.order == m_request_order)
         {
            m_request_in_flight = false;
            m_phase             = "IDLE";
            LogRow("order_closed", "order_left_the_book", 0, 0, -1);
         }
         break;

      case TRADE_TRANSACTION_REQUEST:
         if(m_request_id == 0 && result.request_id != 0) m_request_id = result.request_id;
         m_phase = "IDLE";
         break;

      default:
         break;
      }
   }
};

//--- globals --------------------------------------------------------
CExecutionEngine g_engine;
datetime          g_last_bar_time = 0;

//+------------------------------------------------------------------+
int OnInit(void)
{
   if(!g_engine.Init(_Symbol, InpMagic, InpSlippagePoints, InpLogFileName))
      return(INIT_FAILED);

   if(InpDryRun)
      Print("Dry run is ON: every pre-trade check executes, no order leaves the terminal.");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   PrintFormat("Stop. phase=%s open_positions=%d reason=%d",
               g_engine.Phase(), g_engine.OpenPositions(), reason);
}

//+------------------------------------------------------------------+
//| Mechanical new-bar test trigger. Not a strategy.                  |
//+------------------------------------------------------------------+
void OnTick(void)
{
   const datetime bar_time = (datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
   if(bar_time == g_last_bar_time) return;
   g_last_bar_time = bar_time;

   if(!InpDemoEntries) return;
   if(g_engine.OpenPositions() > 0) return;
   if(g_engine.RequestInFlight()) return;

   g_engine.Open(ORDER_TYPE_BUY,
                 InpLots,
                 InpStopLossPoints,
                 InpTakeProfitPoints,
                 InpMaxSpreadPoints,
                 InpMarginBufferPct,
                 InpDryRun,
                 "execution-lifecycle-demo");
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest    &request,
                        const MqlTradeResult     &result)
{
   g_engine.OnTransaction(trans, result);
}
//+------------------------------------------------------------------+