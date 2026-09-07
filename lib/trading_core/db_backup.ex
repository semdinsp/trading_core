defmodule TradingCore.DbBackup do
  @moduledoc """
  Shells out to `pg_dump` to snapshot a caller's Ecto repo, so each
  DB-owning app in this workspace (`trading_system`, `trading_signal`,
  `trading_live`, `trading_risk`, `trading_backtest`, `dream2`) can offer
  a "back up my database" action — a settings-panel button, a mix task,
  a scheduled job — without re-implementing the shell-out itself five
  times over.

  This module never touches `Ecto.Repo` as a dependency and never reads
  a repo's connection pool — it only reads the *config* a repo was
  started with (`MyApp.Repo.config/0`) and turns that into a `pg_dump`
  invocation. `trading_core` intentionally carries no `:ecto`/`:ecto_sql`
  dependency, so callers pass the config keyword list directly rather
  than the repo module.

  ## Format

  Dumps use `pg_dump`'s own custom format (`-Fc`), not plain SQL piped
  through `gzip`: it's already compressed, restorable with `pg_restore`
  (including selective table restore and parallel jobs), and doesn't
  depend on a separate `gzip` binary being on `PATH`. There is
  deliberately no plain-SQL or manual-gzip mode — one format, one
  restore path (`pg_restore`), one thing for every caller to remember.

  ## Security

  The password is passed to `pg_dump` via the `PGPASSWORD` environment
  variable, never as a command-line argument or interpolated into a
  shell string — argv is visible to every other process on the host via
  `ps`, a shell string invites injection if any config value ever came
  from outside a trusted `config/*.exs` file. `System.cmd/3` is called
  with an explicit argument list (never `:os.cmd/1` or a shell
  invocation), so no argument is ever subject to shell interpretation
  even if a database name or path contained shell metacharacters.
  """

  require Logger

  @type repo_config :: keyword()
  @type dump_result :: {:ok, path :: String.t()} | {:error, term()}

  @doc """
  Dumps the database described by `repo_config` (an Ecto repo's own
  `config/0`) to a timestamped `.pgdump` file under `dir`.

  `dir` is created if it doesn't exist. The output filename is
  `<database>-<YYYYMMDDHHMMSS>.pgdump`, UTC, so repeated calls never
  collide and sort chronologically by filename.

  Returns `{:ok, path}` on a zero-exit `pg_dump`, `{:error, reason}`
  otherwise — `reason` is `{:pg_dump_failed, exit_status, output}` for a
  nonzero exit, or `{:pg_dump_not_found, executable}` if `pg_dump` isn't
  on `PATH`.

  ## Options

    * `:pg_dump_path` — override the `pg_dump` executable. Must exist
      (checked with `File.exists?/1`) or `dump/3` returns
      `{:error, {:pg_dump_not_found, path}}` before shelling out.
      Default: whatever `System.find_executable("pg_dump")` finds on
      `PATH`.
    * `:timeout` — milliseconds to wait for `pg_dump` to exit (default
      `300_000`, five minutes). A dump that runs longer than this is
      killed and treated as a failure.

  ## Examples

      iex> TradingCore.DbBackup.dump(MyApp.Repo.config(), "/var/backups/myapp")
      {:ok, "/var/backups/myapp/myapp_dev-20260907143022.pgdump"}
  """
  @spec dump(repo_config(), Path.t(), keyword()) :: dump_result()
  def dump(repo_config, dir, opts \\ []) do
    with {:ok, pg_dump} <- find_pg_dump(opts),
         :ok <- File.mkdir_p(dir) do
      database = Keyword.fetch!(repo_config, :database)
      path = Path.join(dir, dump_filename(database))
      args = pg_dump_args(repo_config, path)
      env = pg_dump_env(repo_config)
      timeout = Keyword.get(opts, :timeout, 300_000)

      run(pg_dump, args, env, timeout, path)
    end
  end

  @doc """
  Like `dump/3`, but raises on failure instead of returning `{:error,
  _}` — for mix tasks and other call sites where a failed backup should
  halt the caller rather than be pattern-matched on.
  """
  @spec dump!(repo_config(), Path.t(), keyword()) :: String.t()
  def dump!(repo_config, dir, opts \\ []) do
    case dump(repo_config, dir, opts) do
      {:ok, path} -> path
      {:error, reason} -> raise "TradingCore.DbBackup.dump/3 failed: #{inspect(reason)}"
    end
  end

  defp find_pg_dump(opts) do
    case Keyword.get(opts, :pg_dump_path) do
      nil ->
        case System.find_executable("pg_dump") do
          nil -> {:error, {:pg_dump_not_found, "pg_dump"}}
          executable -> {:ok, executable}
        end

      explicit_path ->
        if File.exists?(explicit_path) do
          {:ok, explicit_path}
        else
          {:error, {:pg_dump_not_found, explicit_path}}
        end
    end
  end

  defp dump_filename(database) do
    timestamp =
      DateTime.utc_now()
      |> DateTime.to_naive()
      |> NaiveDateTime.to_iso8601(:basic)
      |> String.replace(~r/\..*$/, "")

    "#{database}-#{timestamp}.pgdump"
  end

  defp pg_dump_args(repo_config, path) do
    database = Keyword.fetch!(repo_config, :database)
    hostname = Keyword.get(repo_config, :hostname, "localhost")
    port = Keyword.get(repo_config, :port, 5432)
    username = Keyword.get(repo_config, :username)

    args = [
      "-h",
      hostname,
      "-p",
      to_string(port),
      "-d",
      database,
      "-Fc",
      "-f",
      path
    ]

    if username, do: args ++ ["-U", username], else: args
  end

  defp pg_dump_env(repo_config) do
    case Keyword.get(repo_config, :password) do
      nil -> []
      password -> [{"PGPASSWORD", password}]
    end
  end

  defp run(executable, args, env, timeout, path) do
    task =
      Task.async(fn ->
        System.cmd(executable, args, env: env, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} ->
        {:ok, path}

      {:ok, {output, exit_status}} ->
        File.rm(path)
        Logger.error("[DbBackup] pg_dump exited #{exit_status}: #{output}")
        {:error, {:pg_dump_failed, exit_status, output}}

      nil ->
        File.rm(path)
        Logger.error("[DbBackup] pg_dump timed out after #{timeout}ms")
        {:error, {:pg_dump_timeout, timeout}}
    end
  end
end
