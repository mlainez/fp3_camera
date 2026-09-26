defmodule Fp3Camera.FakeSystem do
  @moduledoc false
  # Stand-ins for fp3-cam-setup, cam-snap and cam-stream, written as shell
  # scripts into a temp dir and wired in through the application env
  # (see Fp3Camera.Paths). Each records its argv to <dir>/<name>.calls.

  import ExUnit.Callbacks

  @doc """
  Points the library at a fresh temp dir. `opts`:

    * `:full` / `:binned` — `{w, h}` the fake fp3-cam-setup publishes
    * `:sensor` — SENSOR value (default `"imx363 3-0010"`)
    * `:setup`, `:cam_snap`, `:cam_stream` — script bodies, or `:missing`
  """
  def install(opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "fp3_fake_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    old_bins = Application.get_env(:fp3_camera, :binaries)
    old_conf = Application.get_env(:fp3_camera, :conf_dir)

    on_exit(fn ->
      restore(:binaries, old_bins)
      restore(:conf_dir, old_conf)
      File.rm_rf!(dir)
    end)

    {fw, fh} = Keyword.get(opts, :full, {4032, 3024})
    {bw, bh} = Keyword.get(opts, :binned, {2016, 1512})
    sensor = Keyword.get(opts, :sensor, "imx363 3-0010")

    default_setup = """
    binned=0; cam=""
    for a in "$@"; do
      case "$a" in --binned) binned=1 ;; rear|front) cam="$a" ;; esac
    done
    if [ "$binned" = 1 ]; then W=#{bw}; H=#{bh}; else W=#{fw}; H=#{fh}; fi
    printf "SENSOR='#{sensor}'\\nVIDEO=/dev/video0\\nSUBDEV=/dev/v4l-subdev16\\nLENS=\\nWIDTH=$W\\nHEIGHT=$H\\nBAYER=rggb\\n" > "#{dir}/fp3-cam-$cam.conf"
    echo "fp3-cam-setup: $cam ready"
    """

    bins = [
      fp3_cam_setup: script(dir, "fp3-cam-setup", Keyword.get(opts, :setup, default_setup)),
      cam_snap: script(dir, "cam-snap", Keyword.get(opts, :cam_snap, cam_snap_ok())),
      cam_stream: script(dir, "cam-stream", Keyword.get(opts, :cam_stream, cam_stream_ok()))
    ]

    Application.put_env(:fp3_camera, :binaries, bins)
    Application.put_env(:fp3_camera, :conf_dir, dir)
    dir
  end

  def calls(dir, name) do
    case File.read(Path.join(dir, "#{name}.calls")) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      _ -> []
    end
  end

  def cam_snap_ok do
    """
    out=""
    while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
    printf '\\377\\330fakejpeg' > "$out"
    echo "cam-snap: sensor imx363 3-0010" >&2
    echo "with bayer=rggb: R=300.0 G=420.0 B=310.5 (G/R=1.40 G/B=1.35)" >&2
    echo "wb gains: R=2.100 G=1.000 B=1.500 (warm_bias=1.05, lsc=0.40)" >&2
    """
  end

  # Stays up like a listening cam-stream. sleep's fds are detached so a
  # SIGTERM to the script ends the Port cleanly.
  def cam_stream_ok do
    """
    echo "cam-stream: listening on tcp, waiting for client" >&2
    sleep 30 </dev/null >/dev/null 2>&1
    """
  end

  defp script(dir, name, :missing), do: Path.join(dir, "missing-" <> name)

  defp script(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\necho \"$@\" >> \"#{dir}/#{name}.calls\"\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp restore(key, nil), do: Application.delete_env(:fp3_camera, key)
  defp restore(key, value), do: Application.put_env(:fp3_camera, key, value)
end
