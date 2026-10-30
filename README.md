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

**Download:** [release v1.0.0](https://github.com/Smc-AlgoTrading/MQL5-Execution-Lifecycle-Demo/releases/tag/v1.0.0) carries the compiled `.ex5` plus the source, so the module can be attached to a chart without a compiler.

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

### 1. Compiled

MetaEditor64 CLI, Windows 11, MetaTrader 5 build 6090:

```
Result: 0 errors, 0 warnings, 733 msec elapsed, cpu='X64 Regular'
MT5_ExecutionLifecycleDemo.ex5 — 42,670 bytes
```

### 2. Strategy Tester (XAUUSD, M15, 2026.10.01 – 2026.10.20, 1-minute OHLC, Alpari-MT5-Demo, 10,000 USD)

Contract as the terminal reported it: `digits=2 point=0.01 vol[0.01..100.00 step 0.01] stops=0pt freeze=0pt exec=2 filling_flags=3`
(execution mode 2 = Market Execution, flags 3 = FOK|IOC → the resolver picked **FOK**).

**Dry run (`InpDryRun=true`)** — 299 audit rows, one per hour by design:

| measured | value |
|---|---|
| entries that passed every gate | 299 (no rejections) |
| filling mode resolved | FOK (`filling=0`) |
| volume normalised | 0.10 on a 0.01 step grid |
| margin reported by `OrderCalcMargin` | 415.27 – 415.96 USD per 0.10 lot |
| stop distances | exactly 300 / 600 points (3.00 / 6.00 on gold) |
| stops clamped | never — this broker reports `stops=0 freeze=0`, so the clamp path was not exercised |

**Live send path in the tester (`InpDryRun=false`)** — 2,871 audit rows:

| measured | value |
|---|---|
| entries accepted | **716**, every one `retcode=10009` (`TRADE_RETCODE_DONE`) |
| exits recorded | 715 |
| rejections | **8 × `retcode=10018` (market closed)** — logged, guard released, no cascade, no duplicate order |
| duplicate intents | 0 (one request in flight at a time, released only by the transaction event) |
| distinct orders / deals | 716 / 1,431 |
| `terminal_observed_ms`, entries | min 0.2 · median 0.2 · p95 0.4 · max 0.7 |
| `terminal_observed_ms`, exits | min 0.2 · median 0.8 · p95 1.1 · max 2.0 |

> **These latency numbers are not execution latency.** Inside the Strategy Tester the deal is generated
> by the same simulated tick, so the column measures the terminal's event dispatch (sub-millisecond),
> not network or server matching time. They are published as evidence that the measurement path works
> and that the state machine resolves in the right order — not as a speed claim. Real numbers require a
> demo account with live pricing.

### 3. Two defects this run exposed (now fixed)

- the dry-run log line passed 7 arguments to 8 format specifiers, so `margin` printed as `0.00`; the
  value was always computed, only the row was wrong;
- in dry run nothing ever opens, so an unthrottled audit wrote one row per bar (≈1,400 rows over three
  weeks of M15). The decision is unchanged; the audit row is now throttled to one per hour.

### 4. Still not verified

- real demo/live fill latency (see the note above);
- the stop-clamping branch, untested because this broker advertises `stops=0 / freeze=0` — a broker
  with a non-zero stops level is needed;
- partial fills (`TRADE_RETCODE_DONE_PARTIAL`), not produced by this symbol/market.

## License

MIT — see `LICENSE`.