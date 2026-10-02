defmodule TradingCore.MarketContextTest do
  use ExUnit.Case, async: true

  alias TradingCore.MarketContext

  # Friday 2026-10-02, EDT: 12:00 ET = 16:00 UTC.
  @noon ~U[2026-10-02 16:00:00Z]

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        label: "normal|up",
        trend_state: :up,
        vol_state: :normal,
        vol_state_percentile: :calm,
        vix_level: 17.25,
        spy_slope_20: Decimal.new("0.412"),
        spy_price: 763.99,
        spy_sma_20: "755.10",
        evaluated_at: ~U[2026-10-02 15:30:00Z],
        session_date: ~D[2026-10-02]
      },
      overrides
    )
  end

  defp ago(now, seconds), do: DateTime.add(now, -seconds, :second)

  defp signals(now \\ @noon) do
    %{
      "cboe_spy_gamma_exposure_ex0dte" => {Decimal.new("-5180000000"), ago(now, 60)},
      "cboe_sp500_combined_gamma_exposure" => {7_100_000_000, ago(now, 300)},
      "massive_spy_return_since_prior_close" => {0.42, ago(now, 30)},
      "massive_qqq_noise_band_ratio" => {Decimal.new("1.25"), ago(now, 30)},
      "massive_spy_opening_range_position_5m" => {1, ago(now, 30)},
      "massive_qqq_opening_range_direction_30m" => {Decimal.new("-1"), ago(now, 30)}
    }
  end

  test "version, keys and the always-present fields" do
    assert MarketContext.version() == 1
    keys = MarketContext.keys()
    assert length(keys) == 35
    assert length(Enum.uniq(keys)) == 35

    stamp = MarketContext.build(nil, %{}, @noon)
    assert stamp == %{"market_context_version" => 1, "captured_at" => "2026-10-02T16:00:00Z"}
  end

  test "signal_slugs/0 is exactly the slugs build/3 reads" do
    slugs = MarketContext.signal_slugs()
    assert length(slugs) == 22 and length(Enum.uniq(slugs)) == 22

    # Every listed slug produces a key; an unlisted one produces nothing.
    values = Map.new(slugs, &{&1, {1, @noon}})
    stamp = MarketContext.build(nil, values, @noon)
    assert map_size(stamp["as_of"]) == 22

    assert MarketContext.build(nil, %{"not_a_listed_slug" => {1, @noon}}, @noon)
           |> Map.has_key?("as_of") == false
  end

  test "every key build/3 writes is listed in keys/0" do
    stamp = MarketContext.build(payload(), signals(), @noon)
    assert Map.keys(stamp) -- MarketContext.keys() == []
  end

  describe "regime group" do
    test "kept when session_date is the ET date of now, serialized" do
      stamp = MarketContext.build(payload(), %{}, @noon)

      assert stamp["regime_label"] == "normal|up"
      assert stamp["regime_trend_ordinal"] == 1
      assert stamp["regime_vol_ordinal"] == 0
      assert stamp["regime_vol_percentile_state"] == "calm"
      assert stamp["vix_level"] == "17.25"
      assert stamp["spy_slope_20"] == "0.412"
      assert stamp["spy_price"] == "763.99"
      assert stamp["spy_sma_20"] == "755.10"
      assert stamp["regime_session_date"] == "2026-10-02"
      assert stamp["as_of"] == %{"regime" => "2026-10-02T15:30:00Z"}
    end

    test "string keys and string states work the same" do
      string_payload =
        payload(%{trend_state: "down", vol_state: "stressed", vol_state_percentile: "stressed"})
        |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

      stamp = MarketContext.build(string_payload, %{}, @noon)
      assert stamp["regime_trend_ordinal"] == -1
      assert stamp["regime_vol_ordinal"] == 1
      assert stamp["regime_vol_percentile_state"] == "stressed"
      assert stamp["regime_label"] == "normal|up"
    end

    test "omitted pre-open with yesterday's label" do
      # 09:00 ET Friday, label from Thursday's session.
      stamp =
        MarketContext.build(
          payload(%{session_date: ~D[2026-10-01]}),
          %{},
          ~U[2026-10-02 13:00:00Z]
        )

      refute Map.has_key?(stamp, "regime_label")
      refute Map.has_key?(stamp, "as_of")
    end

    test "omitted on a weekend" do
      # Saturday noon ET, Friday's label.
      stamp = MarketContext.build(payload(), %{}, ~U[2026-10-03 16:00:00Z])
      assert Enum.filter(Map.keys(stamp), &String.starts_with?(&1, "regime")) == []
      refute Map.has_key?(stamp, "vix_level")
    end

    test "kept at 16:05 ET the same day" do
      stamp = MarketContext.build(payload(), %{}, ~U[2026-10-02 20:05:00Z])
      assert stamp["regime_label"] == "normal|up"
    end

    test "unknown states and missing fields are omitted, not zero" do
      stamp =
        MarketContext.build(
          payload(%{
            trend_state: :sideways,
            vol_state: nil,
            vix_level: nil,
            spy_price: "n/a",
            evaluated_at: nil
          }),
          %{},
          @noon
        )

      for key <- ["regime_trend_ordinal", "regime_vol_ordinal", "vix_level", "spy_price", "as_of"] do
        refute Map.has_key?(stamp, key), "#{key} should be omitted"
      end

      assert stamp["regime_label"] == "normal|up"
    end

    test "a payload without a usable session_date is no regime" do
      for bad <- [nil, "not a date", 20_261_002] do
        stamp = MarketContext.build(payload(%{session_date: bad}), %{}, @noon)
        refute Map.has_key?(stamp, "regime_label")
      end

      assert MarketContext.build(payload(%{session_date: "2026-10-02"}), %{}, @noon)[
               "regime_label"
             ] ==
               "normal|up"
    end
  end

  describe "signal freshness" do
    test "gamma kept at 11 and 12 minutes old, omitted at 13" do
      for {age, kept?} <- [{11 * 60, true}, {12 * 60, true}, {13 * 60, false}] do
        stamp =
          MarketContext.build(nil, %{"cboe_spy_gamma_exposure" => {1, ago(@noon, age)}}, @noon)

        assert Map.has_key?(stamp, "gamma_spy_all") == kept?, "age #{age}s"
      end
    end

    test "returns, noise band and opening range kept at 1 minute old, omitted at 3" do
      for slug <- [
            "massive_spy_return_since_prior_close",
            "massive_spy_noise_band_ratio",
            "massive_spy_opening_range_position_15m"
          ] do
        assert map_size(MarketContext.build(nil, %{slug => {1, ago(@noon, 60)}}, @noon)) == 4
        assert map_size(MarketContext.build(nil, %{slug => {1, ago(@noon, 180)}}, @noon)) == 2
      end
    end
  end

  describe "signal values" do
    test "nil, missing and non-numeric values are omitted, never 0" do
      values = %{
        "cboe_spy_gamma_exposure" => {nil, @noon},
        "massive_spy_return_since_prior_close" => {"abc", @noon},
        "massive_spy_opening_range_position_5m" => {2, @noon},
        "massive_spy_opening_range_direction_5m" => {0.5, @noon},
        "massive_qqq_noise_band_ratio" => {Decimal.new("NaN"), @noon},
        "massive_qqq_return_since_prior_close" => :not_a_tuple,
        "massive_spy_noise_band_ratio" => {1, "2026-10-02T16:00:00Z"}
      }

      assert MarketContext.build(nil, values, @noon) ==
               %{"market_context_version" => 1, "captured_at" => "2026-10-02T16:00:00Z"}
    end

    test "zero is kept when it is the real value" do
      stamp =
        MarketContext.build(
          nil,
          %{
            "massive_spy_opening_range_position_5m" => {0, @noon},
            "cboe_qqq_gamma_exposure" => {0, @noon}
          },
          @noon
        )

      assert stamp["spy_opening_range_position_5m"] == 0
      assert stamp["gamma_qqq_all"] == "0"
    end

    test "numbers are strings, ordinals and opening-range values integers" do
      stamp = MarketContext.build(payload(), signals(), @noon)

      assert stamp["gamma_spy_ex0dte"] == "-5180000000"
      assert stamp["gamma_spx_combined_all"] == "7100000000"
      assert stamp["spy_return_since_prior_close"] == "0.42"
      assert stamp["qqq_noise_band_ratio"] == "1.25"
      assert stamp["spy_opening_range_position_5m"] == 1
      assert stamp["qqq_opening_range_direction_30m"] == -1
    end

    test "no Decimal or float anywhere in the output" do
      stamp = MarketContext.build(payload(), signals(), @noon)
      assert_json_safe(stamp)
      assert stamp |> JSON.encode!() |> JSON.decode!() == stamp
    end
  end

  test "as_of has exactly the present signal keys plus regime" do
    stamp = MarketContext.build(payload(), signals(), @noon)

    assert Enum.sort(Map.keys(stamp["as_of"])) ==
             Enum.sort([
               "regime",
               "gamma_spy_ex0dte",
               "gamma_spx_combined_all",
               "spy_return_since_prior_close",
               "qqq_noise_band_ratio",
               "spy_opening_range_position_5m",
               "qqq_opening_range_direction_30m"
             ])

    assert stamp["as_of"]["gamma_spx_combined_all"] == "2026-10-02T15:55:00Z"
  end

  describe "out_of_session" do
    test "true before the open and after the close, absent mid-session" do
      assert MarketContext.build(nil, %{}, ~U[2026-10-02 13:00:00Z])["out_of_session"] == true
      assert MarketContext.build(nil, %{}, ~U[2026-10-02 20:05:00Z])["out_of_session"] == true
      refute Map.has_key?(MarketContext.build(nil, %{}, @noon), "out_of_session")
    end

    test "true on a weekend and after a half day's 13:00 close" do
      assert MarketContext.build(nil, %{}, ~U[2026-10-03 16:00:00Z])["out_of_session"] == true
      # 2026-11-27 is EST: 13:30 ET = 18:30 UTC.
      assert MarketContext.build(nil, %{}, ~U[2026-11-27 18:30:00Z])["out_of_session"] == true

      refute Map.has_key?(
               MarketContext.build(nil, %{}, ~U[2026-11-27 17:30:00Z]),
               "out_of_session"
             )
    end
  end

  defp assert_json_safe(%Decimal{} = d), do: flunk("Decimal in output: #{inspect(d)}")
  defp assert_json_safe(f) when is_float(f), do: flunk("float in output: #{f}")

  defp assert_json_safe(%{} = map),
    do:
      Enum.each(map, fn {k, v} ->
        assert is_binary(k)
        assert_json_safe(v)
      end)

  defp assert_json_safe(v) when is_binary(v) or is_integer(v) or v == true, do: :ok
  defp assert_json_safe(other), do: flunk("unexpected value in output: #{inspect(other)}")
end
