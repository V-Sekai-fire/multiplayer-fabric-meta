#!/usr/bin/env elixir
# Activate Meta XR Simulator as the system OpenXR runtime and record the
# result in CockroachDB via the taskweft Postgrex pool.
#
# Usage (from multiplayer-fabric-meta/):
#   elixir activate_smoke_test.exs
#
# Uses the same DB connection env vars as multiplayer-fabric-taskweft:
#   TEST_DATABASE_URL  or  TEST_DB_HOST / TEST_DB_PORT / TEST_DB_NAME etc.
# Falls back to the local Docker CRDB stack if certs exist at the default path.

Mix.install([
  {:postgrex, "~> 0.19"},
  {:jason, "~> 1.4"}
])

defmodule MetaXRSmokeTest do
  @moduledoc """
  HTN-style smoke test for Meta XR Simulator activation on macOS.

  Steps (plan):
    1. ensure_app_running  – launch MetaXRSimulator.app if not running
    2. activate_runtime    – sudo bash activate_simulator.sh
    3. verify_runtime      – confirm active_runtime.json points to Meta XR
    4. record_result       – persist outcome to CRDB smoke_test_runs table
  """

  @app_bundle Path.expand("MetaXRSimulator.app", Path.dirname(__ENV__.file))
  @activate_sh Path.join([@app_bundle, "Contents/Resources/MetaXRSimulator/activate_simulator.sh"])
  @runtime_json "/usr/local/share/openxr/1/active_runtime.json"

  @default_certs Path.expand(
    "../multiplayer-fabric-hosting/certs/crdb",
    Path.dirname(__ENV__.file)
  )

  # ── DB connection ──────────────────────────────────────────────────────────

  defp conn_opts do
    case System.get_env("TEST_DATABASE_URL") do
      url when is_binary(url) and url != "" ->
        [url: url]

      _ ->
        ca   = System.get_env("TEST_DB_CA_CERT",   Path.join(@default_certs, "ca.crt"))
        cert = System.get_env("TEST_DB_CERT",      Path.join(@default_certs, "client.root.crt"))
        key  = System.get_env("TEST_DB_KEY",       Path.join(@default_certs, "client.root.key"))
        host = System.get_env("TEST_DB_HOST", "localhost")
        port = System.get_env("TEST_DB_PORT", "26257") |> String.to_integer()
        db   = System.get_env("TEST_DB_NAME", "taskweft_test")
        user = System.get_env("TEST_DB_USER", "root")
        sni  = System.get_env("TEST_DB_SNI",  "localhost") |> String.to_charlist()

        base = [hostname: host, port: port, database: db, username: user]

        if File.exists?(ca) do
          base ++ [ssl: [cacertfile: ca, certfile: cert, keyfile: key,
                         server_name_indication: sni, verify: :verify_peer]]
        else
          base
        end
    end
  end

  defp ensure_schema!(conn) do
    Postgrex.query!(conn, """
      CREATE TABLE IF NOT EXISTS smoke_test_runs (
        id      BIGSERIAL PRIMARY KEY,
        run_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
        step    TEXT NOT NULL,
        status  TEXT NOT NULL,
        detail  TEXT
      )
    """, [])
  end

  defp record(conn, step, status, detail) do
    Postgrex.query!(conn, """
      INSERT INTO smoke_test_runs (step, status, detail) VALUES ($1, $2, $3)
    """, [step, to_string(status), detail])
  end

  # ── Steps ──────────────────────────────────────────────────────────────────

  defp ensure_app_running(conn) do
    case System.cmd("pgrep", ["-x", "MetaXRSimulator"], stderr_to_stdout: true) do
      {_, 0} ->
        IO.puts("  [ok] MetaXRSimulator already running")
        record(conn, "ensure_app_running", "ok", "already running")

      {_, _} ->
        IO.puts("  [..] Launching #{@app_bundle}")
        {out, code} = System.cmd("open", [@app_bundle], stderr_to_stdout: true)
        if code != 0, do: raise("Failed to launch: #{out}")
        Process.sleep(3_000)
        record(conn, "ensure_app_running", "ok", "launched")
    end
  end

  defp activate_runtime(conn) do
    IO.puts("  [..] Running activate_simulator.sh (sudo)")
    {out, code} = System.cmd("sudo", ["bash", @activate_sh], stderr_to_stdout: true)
    detail = String.trim(out)
    if code != 0, do: raise("activate_simulator.sh failed: #{detail}")
    IO.puts("  [ok] #{detail}")
    record(conn, "activate_runtime", "ok", detail)
  end

  defp verify_runtime(conn) do
    IO.puts("  [..] Verifying #{@runtime_json}")
    case File.read(@runtime_json) do
      {:ok, content} when is_binary(content) ->
        if String.contains?(content, "Meta") do
          IO.puts("  [ok] Runtime points to Meta XR Simulator")
          record(conn, "verify_runtime", "ok", String.trim(content))
        else
          record(conn, "verify_runtime", "error", content)
          raise "active_runtime.json does not reference Meta XR Simulator"
        end

      {:error, reason} ->
        record(conn, "verify_runtime", "error", inspect(reason))
        raise "Cannot read #{@runtime_json}: #{inspect(reason)}"
    end
  end

  # ── Entry point ────────────────────────────────────────────────────────────

  def run do
    IO.puts("=== Meta XR Simulator smoke test ===")
    {:ok, conn} = Postgrex.start_link([name: :smoke_test_pool] ++ conn_opts())
    ensure_schema!(conn)

    [&ensure_app_running/1, &activate_runtime/1, &verify_runtime/1]
    |> Enum.each(& &1.(conn))

    record(conn, "smoke_test", "ok", "all steps passed")
    IO.puts("\n=== PASS: all steps recorded to smoke_test_runs ===")
    GenServer.stop(conn)
  end
end

MetaXRSmokeTest.run()
