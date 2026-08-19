import Config

# Required for TradingCore.MarketHours to resolve any timezone other than
# "Etc/UTC" (e.g. "America/New_York", "Asia/Tokyo") — Elixir's built-in
# Calendar.UTCOnlyTimeZoneDatabase only resolves "Etc/UTC", so without this,
# DateTime.shift_zone/2 returns {:error, :utc_only_time_zone_database} for
# every other zone and every TradingCore.MarketHours function silently fails
# closed. This is process-global `:elixir` application config, so it must
# also be set by any application that depends on trading_core (trading_system
# already sets this in its own config.exs; trading_live must too) — setting
# it here only covers trading_core's own test suite, it does not propagate to
# a consuming app's runtime.
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
