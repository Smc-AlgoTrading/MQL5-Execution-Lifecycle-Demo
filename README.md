# MQL5 Execution Lifecycle — a single-file MetaTrader 5 case study

A 600-line, dependency-free MQL5 Expert Advisor that implements **only** the execution layer of an
algorithmic trading system: everything between "the strategy wants in" and "the terminal knows what
actually happened".

- **No strategy.** The entry trigger is a mechanical new-bar test, present so the execution path can be
  exercised. Nothing here predicts a market.
- **No profitability claim.** There is no equity curve, no backtest screenshot, no Sharpe number.
- **One file, one include** (`<Trade\Trade.mqh>`), no DLLs, no `WebRequest`, no external services.

```
MT5/Experts/MT5_ExecutionLifecycleDemo.mq5     609 lines total · 428 code · 2 classes · 16 methods
```

---

## Why this exists

Most "MQL5 portfolio" repos show a chart and a lot size. The failures that actually cost money live one
layer lower:

| Failure | What this file does about it |
|---|---|
| `ORDER_FILLING_RETURN` rejected on a Market Execution symbol | `CExecutionSpec::ResolveFilling()` reads `SYMBOL_TRADE_EXEMODE` + `SYMBOL_FILLING_MODE` and **returns false** when the broker advertises neither FOK nor IOC instead of inventing a mode |
| Server rejects for margin after the signal is gone | `HasMargin()` calls `OrderCalcMargin()` and keeps a configurable share of free margin untouched |
| `0.30000000000000004` sent as volume | `NormaliseVolume()` snaps to `SYMBOL_VOLUME_STEP`, clamps to min/max, re-snaps, normalises |
| Invalid stops → `TRADE_RETCODE_INVALID_STOPS` | `NormaliseStops()` clamps SL/TP against `SYMBOL_TRADE_STOPS_LEVEL` and `SYMBOL_TRADE_FREEZE_LEVEL` on the correct side of the market |
| Same intent sent twice while the broker is slow | a one-request-in-flight guard, released only by a transaction event |
| `ResultRetcode() == DONE` treated as "the trade happened" | `OnTradeTransaction` confirms with the **deal**, detects partial fills, and logs it |
| "Sub-15 ms execution" claimed with nothing behind it | latency is **measured** per request: `GetMicrosecondCount()` at the trade call → the moment the terminal delivers `TRADE_TRANSACTION_DEAL_ADD` |
| No audit trail | append-only CSV in `MQL5/Files`, never truncated, survives restarts |

---

## Architecture

```
        OnTick ── new bar ─┐
                           ▼
                 ┌──────────────────────┐
                 │  CExecutionEngine     │
                 │  Open(type, lots…)    │
                 └──────────┬───────────┘
                            │  8 ordered gates
   1 in-flight guard ────────┤
   2 spread cap ─────────────┤        ┌────────────────────────┐
   3 filling mode ───────────┼───────►│  CExecutionSpec        │  Load(symbol)
   4 volume normalisation ───┤        │  · digits / point      │  ResolveFilling()
   5 reference price ────────┤        │  · tick size / value   │  NormaliseVolume()
   6 margin buffered ────────┤        │  · vol min/max/step    │  HasMargin()
   7 stops clamped ──────────┤        │  · stops / freeze lvl  │  NormaliseStops()
   8 dry-run stop ───────────┤        │  · exec mode + flags   │
                            │        └────────────────────────┘
                            ▼
                  CTrade.Buy / CTrade.Sell
                            │
        ┌───────────────────┴────────────────────┐
        │  retcode accepted (DONE / PARTIAL /    │
        │  PLACED) → request stays in flight     │
        └───────────────────┬────────────────────┘
                            ▼
   OnTradeTransaction ── ORDER_ADD ── DEAL_ADD ── ORDER_DELETE
                            │
                            ▼
              deal-confirmed row + measured latency
                            │
                            ▼
      MQL5/Files/execution_lifecycle_audit.csv   (append-only)
```

## The audit log

| column | meaning |
|---|---|
| `server_time` | `TimeCurrent()` at write |
| `symbol` | the symbol this EA instance is scoped to |
| `phase` | `IDLE` / `SENT` / `DEAL_SEEN` / `REJECTED` / `DRYRUN` |
| `event` | `dry_run_pass`, `rejected`, `send_accepted`, `send_rejected`, `deal_in`, `deal_out`, `order_closed` |
| `magic`, `request_id`, `order`, `deal` | identifiers, so a fill can be followed end to end |
| `volume`, `price` | normalised volume and the reference/deal price |
| `terminal_observed_ms` | **measured** delta between the trade call and the `DEAL_ADD` event, in the terminal — it excludes network and server matching time by construction and does not claim to be an end-to-end execution latency |
| `detail` | retcode, filling mode used, clamps applied, requested vs sent volume |

## Build and run

```
1. Copy MT5/Experts/MT5_ExecutionLifecycleDemo.mq5 into  <terminal data>\MQL5\Experts\
2. Compile in MetaEditor (F7).
3. Attach to any chart. InpDryRun defaults to TRUE: every gate runs, no order is sent.
   The CSV then contains dry_run_pass rows with the resolved filling mode, clamped stops and margin.
4. Only on a demo account, set InpDryRun=false and InpDemoEntries=true to exercise the send path.
```

Inputs are grouped (`Execution`, `Protection`, `Demo trigger`, `Logging`). Everything is scoped by
`symbol + magic`, so the EA never touches another program's positions.

## Verification — what was actually run, and what was not

**Compiled:** MetaEditor64 CLI, Windows 11, terminal build 6090 data folder:

```
Result: 0 errors, 0 warnings, 642 msec elapsed, cpu='X64 Regular'
MT5_ExecutionLifecycleDemo.ex5 — 42,024 bytes
```

**Not yet verified, stated plainly:**
- no Strategy Tester run is claimed in this repository (the only initialised terminal on the build
  machine was an account with an open position, which was deliberately left alone);
- no live or demo fill has been exercised with `InpDryRun=false` in this revision;
- the latency column has therefore never been populated with real numbers — it will be, on the first
  demo run, and that is the point of shipping the measurement instead of the claim.

## License

MIT — see `LICENSE`.