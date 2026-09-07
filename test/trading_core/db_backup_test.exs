defmodule TradingCore.DbBackupTest do
  use ExUnit.Case, async: true

  alias TradingCore.DbBackup

  @moduletag :tmp_dir

  # A real, already-existing local dev database — trading_core has no
  # database of its own, so this borrows a sibling app's, purely to
  # exercise the success path of a genuine `pg_dump` invocation.
  @live_config [
    database: "dream2_dev",
    hostname: "localhost",
    username: "postgres",
    password: "postgres"
  ]

  describe "dump/3" do
    test "returns {:error, {:pg_dump_not_found, _}} when the executable can't be found", %{
      tmp_dir: tmp_dir
    } do
      config = [database: "whatever_dev", hostname: "localhost", username: "postgres"]

      assert {:error, {:pg_dump_not_found, "/nonexistent/pg_dump"}} =
               DbBackup.dump(config, tmp_dir, pg_dump_path: "/nonexistent/pg_dump")
    end

    test "surfaces a connection failure as {:error, {:pg_dump_failed, _, _}} and cleans up the partial file",
         %{tmp_dir: tmp_dir} do
      config = [
        database: "definitely_not_a_real_db_#{System.unique_integer([:positive])}",
        hostname: "127.0.0.1",
        port: 1,
        username: "postgres",
        password: "wrong"
      ]

      assert {:error, {:pg_dump_failed, exit_status, _output}} = DbBackup.dump(config, tmp_dir)
      assert exit_status != 0
      assert Path.wildcard(Path.join(tmp_dir, "*.pgdump")) == []
    end

    test "creates the output directory if it doesn't exist", %{tmp_dir: tmp_dir} do
      nested_dir = Path.join(tmp_dir, "nested/backups")
      config = [database: "nope_dev", hostname: "127.0.0.1", port: 1]

      DbBackup.dump(config, nested_dir)

      assert File.dir?(nested_dir)
    end

    test "on success, writes a .pgdump file named after the database and returns its path", %{
      tmp_dir: tmp_dir
    } do
      assert {:ok, path} = DbBackup.dump(@live_config, tmp_dir)
      assert File.exists?(path)
      assert Path.dirname(path) == tmp_dir
      assert Path.basename(path) =~ ~r/^dream2_dev-\d{8}T\d{6}\.pgdump$/
      assert File.stat!(path).size > 0
    end

    test "the resulting dump is a valid pg_restore-readable archive", %{tmp_dir: tmp_dir} do
      {:ok, path} = DbBackup.dump(@live_config, tmp_dir)

      pg_restore = System.find_executable("pg_restore")
      {output, exit_status} = System.cmd(pg_restore, ["-l", path], stderr_to_stdout: true)

      assert exit_status == 0, "pg_restore -l failed on the produced dump: #{output}"
    end
  end

  describe "dump!/3" do
    test "returns the path on success", %{tmp_dir: tmp_dir} do
      assert path = DbBackup.dump!(@live_config, tmp_dir)
      assert File.exists?(path)
    end

    test "raises with the error reason on failure", %{tmp_dir: tmp_dir} do
      config = [database: "nope_dev", hostname: "127.0.0.1", port: 1]

      assert_raise RuntimeError, ~r/TradingCore.DbBackup.dump\/3 failed/, fn ->
        DbBackup.dump!(config, tmp_dir)
      end
    end
  end
end
