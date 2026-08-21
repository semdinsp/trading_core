defmodule TradingCore.RiskControlsTest do
  use ExUnit.Case, async: true

  alias TradingCore.RiskControls

  describe "levels/3 — long (default direction)" do
    test "falls back to the 5%/10% default when config is nil" do
      {stop_loss, take_profit} = RiskControls.levels(Decimal.new("100"), nil)

      assert Decimal.equal?(stop_loss, Decimal.new("95.0"))
      assert Decimal.equal?(take_profit, Decimal.new("110.0"))
    end

    test "falls back to the default when config has no risk_controls-shaped method" do
      {stop_loss, take_profit} = RiskControls.levels(Decimal.new("100"), %{})

      assert Decimal.equal?(stop_loss, Decimal.new("95.0"))
      assert Decimal.equal?(take_profit, Decimal.new("110.0"))
    end

    test "falls back to the default when the config method is unrecognized" do
      config = %{"method" => "atr"}
      {stop_loss, take_profit} = RiskControls.levels(Decimal.new("100"), config)

      assert Decimal.equal?(stop_loss, Decimal.new("95.0"))
      assert Decimal.equal?(take_profit, Decimal.new("110.0"))
    end

    test "percent_of_entry computes levels from the configured percentages" do
      config = %{
        "method" => "percent_of_entry",
        "stop_loss_percent" => 2.0,
        "take_profit_percent" => 4.0
      }

      {stop_loss, take_profit} = RiskControls.levels(Decimal.new("100"), config)

      assert Decimal.equal?(stop_loss, Decimal.new("98.0"))
      assert Decimal.equal?(take_profit, Decimal.new("104.0"))
    end

    test "percent_of_entry works for a non-100 entry price" do
      config = %{
        "method" => "percent_of_entry",
        "stop_loss_percent" => 5.0,
        "take_profit_percent" => 10.0
      }

      {stop_loss, take_profit} = RiskControls.levels(Decimal.new("250"), config)

      assert Decimal.equal?(stop_loss, Decimal.new("237.5"))
      assert Decimal.equal?(take_profit, Decimal.new("275.0"))
    end
  end

  describe "levels/3 — short direction" do
    test "inverts placement: stop-loss above entry, take-profit below" do
      config = %{
        "method" => "percent_of_entry",
        "stop_loss_percent" => 2.0,
        "take_profit_percent" => 4.0
      }

      {stop_loss, take_profit} = RiskControls.levels(Decimal.new("100"), config, "short")

      assert Decimal.equal?(stop_loss, Decimal.new("102.0"))
      assert Decimal.equal?(take_profit, Decimal.new("96.0"))
    end

    test "falls back to the 5%/10% default, inverted, when config is nil" do
      {stop_loss, take_profit} = RiskControls.levels(Decimal.new("100"), nil, "short")

      assert Decimal.equal?(stop_loss, Decimal.new("105.0"))
      assert Decimal.equal?(take_profit, Decimal.new("90.0"))
    end
  end

  describe "hit_stop_loss?/3 — long (default direction)" do
    test "true when current price has fallen to the stop level" do
      assert RiskControls.hit_stop_loss?(Decimal.new("95"), Decimal.new("95"))
    end

    test "true when current price has fallen through the stop level" do
      assert RiskControls.hit_stop_loss?(Decimal.new("95"), Decimal.new("90"))
    end

    test "false when current price is still above the stop level" do
      refute RiskControls.hit_stop_loss?(Decimal.new("95"), Decimal.new("100"))
    end

    test "false when there is no stop_loss_price set" do
      refute RiskControls.hit_stop_loss?(nil, Decimal.new("0"))
    end
  end

  describe "hit_take_profit?/3 — long (default direction)" do
    test "true when current price has risen to the target level" do
      assert RiskControls.hit_take_profit?(Decimal.new("110"), Decimal.new("110"))
    end

    test "true when current price has risen through the target level" do
      assert RiskControls.hit_take_profit?(Decimal.new("110"), Decimal.new("120"))
    end

    test "false when current price is still below the target level" do
      refute RiskControls.hit_take_profit?(Decimal.new("110"), Decimal.new("100"))
    end

    test "false when there is no take_profit_price set" do
      refute RiskControls.hit_take_profit?(nil, Decimal.new("999999"))
    end
  end

  describe "hit_stop_loss?/3 — short direction (inverted)" do
    test "true when current price has risen to the stop level" do
      assert RiskControls.hit_stop_loss?(Decimal.new("105"), Decimal.new("105"), "short")
    end

    test "true when current price has risen through the stop level" do
      assert RiskControls.hit_stop_loss?(Decimal.new("105"), Decimal.new("110"), "short")
    end

    test "false when current price is still below the stop level" do
      refute RiskControls.hit_stop_loss?(Decimal.new("105"), Decimal.new("100"), "short")
    end
  end

  describe "hit_take_profit?/3 — short direction (inverted)" do
    test "true when current price has fallen to the target level" do
      assert RiskControls.hit_take_profit?(Decimal.new("90"), Decimal.new("90"), "short")
    end

    test "true when current price has fallen through the target level" do
      assert RiskControls.hit_take_profit?(Decimal.new("90"), Decimal.new("80"), "short")
    end

    test "false when current price is still above the target level" do
      refute RiskControls.hit_take_profit?(Decimal.new("90"), Decimal.new("100"), "short")
    end
  end

  describe "check/4 — long (default direction)" do
    test "returns {:stopped_out, snapshot} when the stop level is hit" do
      assert {:stopped_out, snapshot} =
               RiskControls.check(Decimal.new("95"), Decimal.new("110"), Decimal.new("90"))

      assert snapshot == %{
               "run_current_price" => Decimal.new("90"),
               "run_stop_loss_price" => Decimal.new("95"),
               "run_take_profit_price" => Decimal.new("110")
             }
    end

    test "returns {:target_hit, snapshot} when the target level is hit" do
      assert {:target_hit, _snapshot} =
               RiskControls.check(Decimal.new("95"), Decimal.new("110"), Decimal.new("120"))
    end

    test "returns nil when neither level is hit" do
      assert RiskControls.check(Decimal.new("95"), Decimal.new("110"), Decimal.new("100")) == nil
    end
  end

  describe "check/4 — short direction" do
    test "returns {:stopped_out, snapshot} when price rises to the (inverted) stop level" do
      assert {:stopped_out, snapshot} =
               RiskControls.check(
                 Decimal.new("105"),
                 Decimal.new("90"),
                 Decimal.new("110"),
                 "short"
               )

      assert snapshot == %{
               "run_current_price" => Decimal.new("110"),
               "run_stop_loss_price" => Decimal.new("105"),
               "run_take_profit_price" => Decimal.new("90")
             }
    end

    test "returns {:target_hit, snapshot} when price falls to the (inverted) target level" do
      assert {:target_hit, _snapshot} =
               RiskControls.check(
                 Decimal.new("105"),
                 Decimal.new("90"),
                 Decimal.new("80"),
                 "short"
               )
    end

    test "returns nil when neither level is hit" do
      assert RiskControls.check(Decimal.new("105"), Decimal.new("90"), Decimal.new("100"), "short") ==
               nil
    end
  end
end
