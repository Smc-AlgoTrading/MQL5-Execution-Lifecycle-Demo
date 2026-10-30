# Compile verification

Verbatim, from MetaEditor64 CLI on the build machine. This is the complete compile record for
`MT5/Experts/MT5_ExecutionLifecycleDemo.mq5` at the current commit.

## Environment

| item | value |
|---|---|
| Compiler | `C:\Program Files\MetaTrader 5 IC Markets (SC)\metaeditor64.exe` (build 6090) |
| Terminal data folder used | `...\MetaQuotes\Terminal\1640F6577B1C4EC659BF41EA9F6C38ED` |
| Emitted target | `MT5_ExecutionLifecycleDemo.ex5` (42,670 bytes) |
| Host | Windows 11 |
| Command | `metaeditor64.exe /compile:"<path>.mq5" /log:"<path>.log"` |

## Result

```
Result: 0 errors, 0 warnings, 733 msec elapsed, cpu='X64 Regular'
```

Standard-library includes resolved during the compile (from the terminal's own `MQL5\Include`):

```
Trade\Trade.mqh → Object.mqh, StdLibErr.mqh, OrderInfo.mqh, HistoryOrderInfo.mqh,
                  PositionInfo.mqh, DealInfo.mqh
```

## Two API facts the compile pass corrected

Kept here because they are the kind of detail that only shows up when a file is actually built rather
than described:

1. `CTrade` exposes `ResultRetcode()`, `ResultOrder()`, `ResultDeal()`, `ResultVolume()`, `ResultPrice()`,
   `ResultComment()` — **not** a request-id getter. The request id is taken from the
   `MqlTradeResult` handed to `OnTradeTransaction`.
2. `MqlTradeTransaction` has **no** `time` and **no** `request_id` field. The deal timestamp must be read
   from history: `HistoryDealGetInteger(trans.deal, DEAL_TIME)`.

## Third fact, from the first headless tester run

A constant class member (`const int m_dry_log_seconds`) cannot be assigned in the constructor:
`error 189: 'm_dry_log_seconds' - constant cannot be modified`. A `#define` or a plain member is
required. Fixed by dropping the qualifier.

## Runtime record (Strategy Tester)

```
terminal64.exe /config:<ini>   →   exit 0
2026.10.01 00:00:00   XAUUSD | digits=2 point=0.01 vol[0.01..100.00 step 0.01]
                                stops=0pt freeze=0pt exec=2 filling_flags=3
XAUUSD,M15: 71240 ticks, 1196 bars generated. Test passed in 0:00:00.370.
```

Injection requires the account to belong to the same data folder as the terminal binary; a copied
`accounts.dat` is rejected by build version (`Accounts: deleted due old version`), and a data folder
with no account refuses outright (`tester not started because the account is not specified`).

Raw audit CSVs from that run are in `docs/evidence/`:

- `dry_run_audit_xauusd_m15.csv` — 299 gate passes, no rejections, `margin=415.x` USD per 0.10 lot
- `live_send_audit_xauusd_m15.csv` — 716 accepted entries (all `retcode=10009`), 715 exits,
  8 × `retcode=10018` market-closed rejections handled without a duplicate order

## What this record does not prove

Compilation proves the file builds against the shipped standard library with zero diagnostics, and the
tester run proves the gate order and state machine resolve in sequence. Neither proves execution
latency: inside the tester the deal is produced by the same simulated tick, so `terminal_observed_ms`
there measures event dispatch, not matching time. Real numbers need a demo account with live pricing.
Partial fills and the stop-clamping branch are also unexercised — this broker reports `stops=0 freeze=0`.