# Compile verification

Verbatim, from MetaEditor64 CLI on the build machine. This is the complete compile record for
`MT5/Experts/MT5_ExecutionLifecycleDemo.mq5` at the current commit.

## Environment

| item | value |
|---|---|
| Compiler | `C:\Program Files\MetaTrader 5\metaeditor64.exe` |
| Terminal data folder used | `...\MetaQuotes\Terminal\1640F6577B1C4EC659BF41EA9F6C38ED` |
| Emitted target | `MT5_ExecutionLifecycleDemo.ex5` (42,024 bytes) |
| Host | Windows 11 |
| Command | `metaeditor64.exe /compile:"<path>.mq5" /log:"<path>.log"` |

## Result

```
Result: 0 errors, 0 warnings, 642 msec elapsed, cpu='X64 Regular'
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

## What this record does not prove

Compilation proves the file builds against the shipped standard library with zero diagnostics. It does
not prove runtime behaviour. No Strategy Tester run and no demo fill is claimed for this revision — see
the "Verification" section of the top-level README, which states the same thing.