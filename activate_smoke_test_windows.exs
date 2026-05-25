#!/usr/bin/env elixir
# Activate Meta XR Simulator as the system OpenXR runtime on Windows and
# record the result in CockroachDB.
#
# Usage (from multiplayer-fabric-meta/, elevated PowerShell):
#   elixir activate_smoke_test_windows.exs
#
# Requires: Meta XR Simulator installed (from developers.meta.com).
# The simulator's runtime manifest JSON must exist at:
#   <install_dir>\meta_openxr_simulator.json
#
# Uses the same DB connection env vars as multiplayer-fabric-taskweft:
#   TEST_DATABASE_URL  or  TEST_DB_HOST / TEST_DB_PORT / TEST_DB_NAME etc.
# Falls back to the Harvester CRDB at 192.168.1.220:26257 if certs exist.

Mix.install([
  {:postgrex, "~> 0.19"},
  {:jason, "~> 1.4"}
])

defmodule MetaXRSmokeTest.Windows do
  @moduledoc """
  HTN-style smoke test for Meta XR Simulator activation on Windows.

  Steps (plan):
    1. find_simulator      – locate MetaXRSimulator.exe install path
    2. ensure_app_running  – launch MetaXRSimulator.exe if not running
    3. activate_runtime    – set HKLM OpenXR ActiveRuntime registry key
    4. verify_runtime      – confirm registry points to Meta XR Simulator
    5. record_result       – persist outcome to CRDB smoke_test_runs table
  """

  @simulator_exe "MetaXRSimulator.exe"

  @candidate_dirs (
    [Path.expand("MetaXRSimulator", Path.dirname(__ENV__.file))] ++
    (for v <- ["v201.0", "v200.0", "v199.0", ""],
     do: "C:/Program Files/MetaXRSimulator/#{v}" |> String.trim_trailing("/")) ++
    ["C:/Program Files/Meta/Meta XR Simulator",
     "C:/Program Files (x86)/Meta/Meta XR Simulator"]
  )

  @default_certs Path.expand(
    "../multiplayer-fabric-hosting/certs/crdb",
    Path.dirname(__ENV__.file)
  )

  @harvester_certs Path.expand(
    "../v-sekai-infra/certs/gateway",
    Path.dirname(__ENV__.file)
  )

  # ── DB connection ──────────────────────────────────────────────────────────

  defp conn_opts do
    case System.get_env("TEST_DATABASE_URL") do
      url when is_binary(url) and url != "" ->
        [url: url]

      _ ->
        {ca, cert, key, host, sni} = pick_certs()
        port = System.get_env("TEST_DB_PORT", "26257") |> String.to_integer()
        db   = System.get_env("TEST_DB_NAME", "taskweft_test")
        user = System.get_env("TEST_DB_USER", "root")

        base = [hostname: host, port: port, database: db, username: user]

        if ca != nil and File.exists?(ca) do
          base ++ [ssl: [cacertfile: ca, certfile: cert, keyfile: key,
                         server_name_indication: String.to_charlist(sni),
                         verify: :verify_peer]]
        else
          base ++ [hostname: host]
        end
    end
  end

  defp pick_certs do
    ca_env   = System.get_env("TEST_DB_CA_CERT")
    cert_env = System.get_env("TEST_DB_CERT")
    key_env  = System.get_env("TEST_DB_KEY")
    host_env = System.get_env("TEST_DB_HOST")
    sni_env  = System.get_env("TEST_DB_SNI")

    cond do
      ca_env != nil ->
        {ca_env, cert_env, key_env, host_env || "localhost", sni_env || "localhost"}

      File.exists?(Path.join(@default_certs, "ca.crt")) ->
        {Path.join(@default_certs, "ca.crt"),
         Path.join(@default_certs, "client.root.crt"),
         Path.join(@default_certs, "client.root.key"),
         host_env || "localhost", sni_env || "localhost"}

      File.exists?(Path.join(@harvester_certs, "ca.crt")) ->
        {Path.join(@harvester_certs, "ca.crt"),
         Path.join(@harvester_certs, "client.gateway_writer.crt"),
         Path.join(@harvester_certs, "client.gateway_writer.key"),
         host_env || "192.168.1.220", sni_env || "localhost"}

      true ->
        {nil, nil, nil, host_env || "localhost", sni_env || "localhost"}
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

  defp record(nil, _step, _status, _detail), do: :ok
  defp record(conn, step, status, detail) do
    Postgrex.query!(conn, """
      INSERT INTO smoke_test_runs (step, status, detail) VALUES ($1, $2, $3)
    """, [step, to_string(status), detail])
  end

  # ── Registry helpers ───────────────────────────────────────────────────────

  defp read_registry(path, value_name) do
    {out, code} = System.cmd("reg", [
      "query", "HKLM\\#{path}", "/v", value_name
    ], stderr_to_stdout: true)

    if code == 0 do
      case Regex.run(~r/REG_SZ\s+(.+)/, out) do
        [_, val] -> {:ok, String.trim(val)}
        _        -> {:error, "could not parse reg output: #{out}"}
      end
    else
      {:error, String.trim(out)}
    end
  end

  defp write_registry(path, value_name, value) do
    {out, code} = System.cmd("reg", [
      "add", "HKLM\\#{path}", "/v", value_name,
      "/t", "REG_SZ", "/d", value, "/f"
    ], stderr_to_stdout: true)

    if code == 0, do: :ok, else: {:error, String.trim(out)}
  end

  # ── Steps ──────────────────────────────────────────────────────────────────

  defp find_simulator(conn) do
    IO.puts("  [..] Searching for #{@simulator_exe}")

    install_dir = Enum.find(@candidate_dirs, fn dir ->
      File.exists?(Path.join(dir, @simulator_exe))
    end)

    if install_dir do
      IO.puts("  [ok] Found at #{install_dir}")
      record(conn, "find_simulator", "ok", install_dir)
      install_dir
    else
      detail = "Searched: #{inspect(@candidate_dirs)}"
      record(conn, "find_simulator", "error", detail)
      raise "#{@simulator_exe} not found. #{detail}"
    end
  end

  defp find_runtime_json(install_dir) do
    candidates = [
      Path.join(install_dir, "meta_openxr_simulator.json"),
      Path.join(install_dir, "meta_openxr_simulator_64.json")
    ]

    Enum.find(candidates, &File.exists?/1) ||
      raise "No runtime manifest JSON in #{install_dir}. Expected one of: #{inspect(candidates)}"
  end

  defp ensure_app_running(conn, install_dir) do
    {out, _code} = System.cmd("tasklist", ["/FI", "IMAGENAME eq #{@simulator_exe}"],
                              stderr_to_stdout: true)

    if String.contains?(out, @simulator_exe) do
      IO.puts("  [ok] #{@simulator_exe} already running")
      record(conn, "ensure_app_running", "ok", "already running")
    else
      exe = Path.join(install_dir, @simulator_exe)
      IO.puts("  [..] Launching #{exe}")
      {launch_out, code} = System.cmd("cmd", ["/c", "start", "", exe],
                                       stderr_to_stdout: true)
      if code != 0, do: raise("Failed to launch: #{launch_out}")
      Process.sleep(5_000)
      record(conn, "ensure_app_running", "ok", "launched")
    end
  end

  defp activate_runtime(conn, install_dir) do
    activate_ps1 = Path.join(install_dir, "activate_simulator.ps1")

    if File.exists?(activate_ps1) do
      IO.puts("  [..] Running #{activate_ps1}")
      {out, code} = System.cmd("powershell", [
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", activate_ps1, "-MessageTime", "0"
      ], stderr_to_stdout: true)
      detail = String.trim(out)
      if code != 0, do: raise("activate_simulator.ps1 failed: #{detail}")
      IO.puts("  [ok] #{detail}")
      record(conn, "activate_runtime", "ok", detail)
    else
      runtime_json = find_runtime_json(install_dir)
      IO.puts("  [..] Setting OpenXR ActiveRuntime → #{runtime_json}")

      case write_registry("SOFTWARE\\Khronos\\OpenXR\\1", "ActiveRuntime", runtime_json) do
        :ok ->
          IO.puts("  [ok] Registry updated")
          record(conn, "activate_runtime", "ok", runtime_json)
        {:error, reason} ->
          record(conn, "activate_runtime", "error", reason)
          raise "Registry write failed (run as admin?): #{reason}"
      end
    end
  end

  defp verify_runtime(conn) do
    IO.puts("  [..] Verifying HKLM\\SOFTWARE\\Khronos\\OpenXR\\1\\ActiveRuntime")

    case read_registry("SOFTWARE\\Khronos\\OpenXR\\1", "ActiveRuntime") do
      {:ok, value} ->
        if String.contains?(String.downcase(value), "meta") do
          IO.puts("  [ok] ActiveRuntime → #{value}")
          record(conn, "verify_runtime", "ok", value)
        else
          record(conn, "verify_runtime", "error", value)
          raise "ActiveRuntime does not reference Meta XR Simulator: #{value}"
        end

      {:error, reason} ->
        record(conn, "verify_runtime", "error", reason)
        raise "Cannot read ActiveRuntime: #{reason}"
    end
  end

  # ── Entry point ────────────────────────────────────────────────────────────

  def run do
    IO.puts("=== Meta XR Simulator smoke test (Windows) ===")

    conn = try do
      {:ok, c} = Postgrex.start_link(
        [name: :smoke_test_pool, pool_size: 1, queue_target: 1000, queue_interval: 1000]
        ++ conn_opts()
      )
      ensure_schema!(c)
      IO.puts("  [ok] Connected to CockroachDB")
      c
    rescue
      e ->
        IO.puts("  [warn] No DB connection (#{Exception.message(e)}); results will not be persisted")
        nil
    catch
      :exit, reason ->
        IO.puts("  [warn] No DB connection (#{inspect(reason)}); results will not be persisted")
        nil
    end

    install_dir = find_simulator(conn)
    ensure_app_running(conn, install_dir)
    activate_runtime(conn, install_dir)
    verify_runtime(conn)

    if conn do
      record(conn, "smoke_test", "ok", "all steps passed")
      GenServer.stop(conn)
    end
    IO.puts("\n=== PASS ===")
  end
end

MetaXRSmokeTest.Windows.run()
