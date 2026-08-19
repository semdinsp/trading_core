# trading_core

Shared Elixir library for logic that must behave identically wherever
strategies are evaluated — `trading_system`'s paper simulator and
`trading_live`'s live GenServers, primarily.

## Modules

- `TradingCore.RuleEngine` — evaluates a strategy's rule tree (entry/exit
  conditions) against a signal snapshot. Extracted from
  `TradingSystem.Trading.RuleEngine`; API preserved exactly.
- `TradingCore.MarketHours` (+ `TradingCore.MarketHours.Session`) —
  time-math for a named market session window (open?/closed-for-today?/
  next-close/etc), extracted from `TradingSystem.Trading.MarketHour`.
  Operates on a plain struct, not an Ecto schema — each consuming app owns
  its own session data independently and builds a `Session` from it.
- `TradingCore.ExchangeSessions` — lookup helper mapping an exchange string
  to a session name, given a caller-supplied mapping (each app owns its own
  map/table, not a shared hardcoded one).

## Important: timezone database

Any consuming application must set:

```elixir
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
```

in its own `config/config.exs`. Without this, `DateTime.shift_zone/2`
returns `{:error, :utc_only_time_zone_database}` for any zone other than
`"Etc/UTC"`, and every `TradingCore.MarketHours` function fails closed. This
bit `trading_system` once in production (see that repo's `config/config.exs`
for the incident notes) — don't reintroduce it in a new consumer.

## Deliberately not extracted here

- Position sizing and volatility calculation stay in `trading_system`
  (`TradingSystem.Trading.PositionSizing`) and `trading_hub`
  (`TradingHub.Volatility.Calculator`) respectively — consumers call those
  directly (RPC), not via this library.
- Condition-rating/authoring tables and tooling stay in `trading_system` —
  a possible future standalone `trading_conditions` app, not part of this
  library.
