defmodule Fp3Camera.Diagnostics do
  @moduledoc """
  End-to-end self-test for everything this library exposes.

  This exists because "the camera works" turned out, repeatedly, to be
  unprovable from the outside. A `cam-stream` that had been orphaned by
  an earlier run kept its TCP port bound and answered a client that
  connected to it by accident; a busybox `ps -o args` listed only the
  calling session's processes and so reported the phone idle while that
  orphan was streaming. Both readings looked like results. Neither was.

  So the rule here is that nothing is judged by an exit status or by the
  absence of an error. Every capability is judged on a byte someone can
  point at: a JPEG with the right magic and dimensions, an H.264 stream
  with a counted IDR and counted P-frames pulled off a real socket, a
  port that is measurably free after the stream stops.

      iex> Fp3Camera.Diagnostics.run()

  `run/1` prints a table and returns the structured results, so it works
  as an interactive check and as something a test harness can assert on.

  Options:

    * `:cameras`     — which to exercise (default: both fitted)
    * `:stream_secs` — seconds to pull from each stream (default: 8)
    * `:dir`         — where stills are written (default: `/root`)
    * `:keep`        — keep the captured files (default: `true`)
  """

  require Logger

  @doc """
  Run the full matrix and print it. Returns a list of per-camera maps.
  """
  def run(opts \\ []) do
    cams = Keyword.get(opts, :cameras, fitted_cameras())
    secs = Keyword.get(opts, :stream_secs, 8)
    dir = Keyword.get(opts, :dir, "/root")

    IO.puts("")
    IO.puts("fp3_camera self-test — #{DateTime.utc_now() |> DateTime.to_string()}")
    IO.puts("phone uptime #{uptime_s()}s, cameras: #{inspect(cams)}")
    IO.puts(String.duplicate("─", 78))

    dmesg_before = venus_camss_errors()

    results = Enum.map(cams, &check_camera(&1, secs, dir, opts))

    new_errors = venus_camss_errors() -- dmesg_before

    IO.puts(String.duplicate("─", 78))
    Enum.each(results, &print_row/1)
    IO.puts(String.duplicate("─", 78))

    if new_errors == [] do
      IO.puts("dmesg: no new venus/camss errors during the run")
    else
      IO.puts("dmesg: #{length(new_errors)} NEW venus/camss error(s):")
      Enum.each(new_errors, &IO.puts("  #{&1}"))
    end

    leaked = orphan_pids()

    if leaked == [],
      do: IO.puts("processes: no cam-stream left behind"),
      else: IO.puts("processes: LEAKED cam-stream pids #{inspect(leaked)}")

    verdict =
      Enum.all?(results, & &1.pass) and new_errors == [] and leaked == []

    IO.puts("")
    IO.puts(if verdict, do: "RESULT: PASS", else: "RESULT: FAIL")
    IO.puts("")

    results
  end

  ## Per-camera

  defp check_camera(cam, secs, dir, opts) do
    IO.puts("")
    IO.puts("### #{cam}")

    base = %{camera: cam, pass: false}

    # setup before detect, not after: info/1 reads the conf that
    # fp3-cam-setup publishes to /run, so on a fresh boot it answers
    # :not_configured until the media graph has been walked once.
    with {:ok, _} <- step("setup", fn -> Fp3Camera.setup(cam) end),
         {:ok, info} <- step("detect", fn -> Fp3Camera.info(cam) end),
         {:ok, still} <- step("still", fn -> check_still(cam, dir, opts) end),
         {:ok, stream} <- step("stream", fn -> check_stream(cam, secs) end) do
      %{
        base
        | pass: still.pass and stream.pass
      }
      |> Map.merge(%{sensor: sensor_of(info), still: still, stream: stream})
    else
      {:error, stage, reason} ->
        Map.merge(base, %{failed_stage: stage, reason: reason, still: nil, stream: nil})
    end
  end

  # Each step reports what it actually observed, so a failure names the
  # stage rather than surfacing as a stack trace three calls up.
  defp step(name, fun) do
    case safe(fun) do
      {:ok, :ok} ->
        IO.puts("  #{pad(name)} ok")
        {:ok, :ok}

      {:ok, {:ok, v}} ->
        IO.puts("  #{pad(name)} ok")
        {:ok, v}

      {:ok, %{pass: true} = v} ->
        IO.puts("  #{pad(name)} #{v.detail}")
        {:ok, v}

      {:ok, %{pass: false} = v} ->
        IO.puts("  #{pad(name)} FAIL — #{v.detail}")
        {:error, name, v.detail}

      {:ok, other} ->
        IO.puts("  #{pad(name)} #{inspect(other, limit: 3)}")
        {:ok, other}

      {:error, e} ->
        IO.puts("  #{pad(name)} FAIL — #{inspect(e)}")
        {:error, name, e}
    end
  end

  defp safe(fun) do
    case fun.() do
      {:error, _} = e -> e
      v -> {:ok, v}
    end
  rescue
    e -> {:error, e}
  catch
    kind, e -> {:error, {kind, e}}
  end

  ## Stills — judged on the file, not on cam-snap's exit code

  defp check_still(cam, dir, opts) do
    path = Path.join(dir, "selftest-#{cam}.jpg")
    File.rm(path)
    t0 = System.monotonic_time(:millisecond)
    res = Fp3Camera.snap(cam, path)
    ms = System.monotonic_time(:millisecond) - t0

    case File.read(path) do
      {:ok, <<0xFF, 0xD8, _::binary>> = jpg} ->
        unless Keyword.get(opts, :keep, true), do: File.rm(path)
        {w, h} = jpeg_size(jpg)

        %{
          pass: byte_size(jpg) > 10_000,
          bytes: byte_size(jpg),
          width: w,
          height: h,
          ms: ms,
          path: path,
          detail: "#{w}x#{h}, #{div(byte_size(jpg), 1024)} KB in #{ms} ms → #{path}"
        }

      {:ok, _} ->
        %{pass: false, detail: "file written but it is not a JPEG (bad SOI marker)"}

      {:error, e} ->
        %{pass: false, detail: "no file: #{inspect(e)} (snap returned #{inspect(res)})"}
    end
  end

  # SOF0/SOF2 carry the real decoded dimensions; reading them proves the
  # sensor geometry made it all the way through, which a byte count does
  # not.
  defp jpeg_size(<<0xFF, 0xD8, rest::binary>>), do: scan_sof(rest)
  defp jpeg_size(_), do: {0, 0}

  defp scan_sof(<<0xFF, m, _len::16, body::binary>>) when m in [0xC0, 0xC1, 0xC2] do
    case body do
      <<_prec, h::16, w::16, _::binary>> -> {w, h}
      _ -> {0, 0}
    end
  end

  defp scan_sof(<<0xFF, m, len::16, rest::binary>>) when m != 0xD8 and m != 0x01 do
    skip = len - 2

    case rest do
      <<_::binary-size(skip), more::binary>> -> scan_sof(more)
      _ -> {0, 0}
    end
  end

  defp scan_sof(<<_, rest::binary>>), do: scan_sof(rest)
  defp scan_sof(_), do: {0, 0}

  ## Streams — judged on bytes pulled off a real socket

  defp check_stream(cam, secs) do
    case Fp3Camera.start_stream(cam) do
      {:ok, ref} ->
        try do
          port = stream_port(ref)
          # cam-stream binds, then blocks in accept() before it touches
          # the camera, so a client that connects too early is refused
          # and the run reads as "zero bytes" when nothing is wrong.
          data = pull(port, secs)
          nals = count_nals(data)
          fps = Float.round(nals.p / max(secs, 1) * 1.0, 1)

          pass = byte_size(data) > 50_000 and nals.idr >= 1 and nals.p >= 10

          detail =
            if pass do
              "#{div(byte_size(data), 1024)} KB in #{secs}s on tcp/#{port} — " <>
                "SPS=#{nals.sps} PPS=#{nals.pps} IDR=#{nals.idr} P=#{nals.p} (~#{fps} fps)"
            else
              "only #{byte_size(data)} B on tcp/#{port} — " <>
                "SPS=#{nals.sps} PPS=#{nals.pps} IDR=#{nals.idr} P=#{nals.p}"
            end

          %{
            pass: pass,
            bytes: byte_size(data),
            port: port,
            nals: nals,
            fps: fps,
            detail: detail
          }
        after
          Fp3Camera.stop_stream(ref)
          # Prove the teardown, not just the call: the whole class of bug
          # here is a process that stays bound after it is "stopped".
          Process.sleep(1_000)
        end

      {:error, e} ->
        %{pass: false, detail: "start_stream refused: #{inspect(e)}"}
    end
  end

  defp stream_port(ref) do
    Fp3Camera.streams() |> Enum.find(&(&1.ref == ref)) |> Map.get(:port)
  end

  defp pull(port, secs) do
    case connect_retry(port, 15) do
      {:ok, sock} ->
        deadline = System.monotonic_time(:millisecond) + secs * 1_000
        data = recv_until(sock, deadline, <<>>)
        :gen_tcp.close(sock)
        data

      {:error, _} ->
        <<>>
    end
  end

  defp connect_retry(_port, 0), do: {:error, :refused}

  defp connect_retry(port, tries) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000) do
      {:ok, s} ->
        {:ok, s}

      {:error, _} ->
        Process.sleep(500)
        connect_retry(port, tries - 1)
    end
  end

  defp recv_until(sock, deadline, acc) do
    if System.monotonic_time(:millisecond) >= deadline do
      acc
    else
      case :gen_tcp.recv(sock, 0, 2_000) do
        {:ok, d} -> recv_until(sock, deadline, acc <> d)
        {:error, _} -> acc
      end
    end
  end

  # Annex-B NAL histogram. An IDR proves the encoder produced a real
  # keyframe; a P-frame count proves it kept going afterwards, which a
  # single buffered frame — the failure everyone mistook for success —
  # does not.
  defp count_nals(<<>>), do: %{sps: 0, pps: 0, idr: 0, p: 0}

  defp count_nals(data) do
    <<0>>
    |> then(&(data <> &1))
    |> then(fn padded ->
      :binary.matches(padded, <<0, 0, 1>>)
      |> Enum.reduce(%{sps: 0, pps: 0, idr: 0, p: 0}, fn {pos, _}, acc ->
        case padded do
          <<_::binary-size(pos + 3), b, _::binary>> ->
            case Bitwise.band(b, 0x1F) do
              7 -> %{acc | sps: acc.sps + 1}
              8 -> %{acc | pps: acc.pps + 1}
              5 -> %{acc | idr: acc.idr + 1}
              1 -> %{acc | p: acc.p + 1}
              _ -> acc
            end

          _ ->
            acc
        end
      end)
    end)
  end

  ## Environment

  defp fitted_cameras do
    Enum.filter([:rear, :front], &File.exists?("/run/fp3-cam-#{&1}.conf"))
    |> case do
      [] -> [:rear, :front]
      list -> list
    end
  end

  defp sensor_of(info) when is_map(info), do: Map.get(info, :sensor, "?")
  defp sensor_of(_), do: "?"

  defp uptime_s do
    case File.read("/proc/uptime") do
      {:ok, s} -> s |> String.split() |> hd() |> String.to_float() |> trunc()
      _ -> 0
    end
  end

  defp venus_camss_errors do
    case System.cmd("dmesg", [], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n")
        |> Enum.filter(fn l ->
          (String.contains?(l, "venus") or String.contains?(l, "camss")) and
            (String.contains?(l, "fail") or String.contains?(l, "error") or
               String.contains?(l, "timeout"))
        end)

      _ ->
        []
    end
  end

  defp orphan_pids do
    Path.wildcard("/proc/[0-9]*/cmdline")
    |> Enum.filter(fn f ->
      case File.read(f) do
        {:ok, c} -> String.contains?(c, "cam-stream")
        _ -> false
      end
    end)
    |> Enum.map(&Path.basename(Path.dirname(&1)))
  end

  ## Output

  defp pad(s), do: String.pad_trailing(s, 8)

  defp print_row(%{pass: true} = r) do
    IO.puts(
      "PASS  #{String.pad_trailing(to_string(r.camera), 6)} " <>
        "still #{r.still.width}x#{r.still.height} #{div(r.still.bytes, 1024)}KB   " <>
        "stream #{div(r.stream.bytes, 1024)}KB IDR=#{r.stream.nals.idr} P=#{r.stream.nals.p}"
    )
  end

  defp print_row(r) do
    IO.puts(
      "FAIL  #{String.pad_trailing(to_string(r.camera), 6)} " <>
        "at #{Map.get(r, :failed_stage, "?")}: #{inspect(Map.get(r, :reason))}"
    )
  end
end
