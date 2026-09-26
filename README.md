# fp3_camera

> ### ⚠️ Very early work — built for a workshop, not for production
>
> Written for the **Goatmire Elixir workshop** on running Nerves on Fairphone 3 hardware. There are no stability guarantees and APIs will change without notice.

Stills, live H.264 and raw NV12 frames from the Fairphone 3 and 3+
cameras, on [nerves_system_fp3](https://github.com/mlainez/nerves_system_fp3).

```elixir
{:ok, path} = Fp3Camera.snap(:rear, "/root/photo.jpg")
{:ok, ref}  = Fp3Camera.start_stream(:rear)
{:ok, pid}  = Fp3Camera.subscribe(:front)
```

Each call configures the CAMSS media graph, picks settings for whichever
camera module is actually fitted, and captures. There is nothing to set
up first.

## Requirements

A Nerves system that ships these (nerves_system_fp3 does, from its
`fp3-camera-utils` package and libv4l's tools):

| Binary                   | Used for                                                                  |
| ------------------------ | ------------------------------------------------------------------------- |
| `/usr/bin/fp3-cam-setup` | Detects the fitted module, configures the media graph, writes `/run/fp3-cam-<camera>.conf` |
| `/usr/bin/cam-snap`      | Stills: software demosaic → JPEG                                          |
| `/usr/bin/cam-stream`    | Live video: Venus H.264 over TCP, or raw NV12 on stdout                   |
| `media-ctl`, `modprobe`  | Called by `fp3-cam-setup` (it also loads `venus-enc`/`venus-dec`)         |
| `/bin/sh`, `kill`        | Process plumbing                                                          |

`cam-snap` and `cam-stream` run `fp3-cam-setup` themselves before every
capture. Without these binaries (on a host, say) the application still
starts and every capture function returns an error tuple such as
`{:error, {:enoent, "/usr/bin/fp3-cam-setup"}}`.

## Toolchain

Built and tested with Erlang/OTP 29.1.1 and Elixir 1.20.4, matching the
official Nerves systems (see `.tool-versions`).

## Two phones, four sensors, one call

The camera modules are user-replaceable and the Fairphone 3+ kit fits
different silicon in the same slots, so a phone can carry any mix:

| Slot  | Fairphone 3           | Fairphone 3+           |
| ----- | --------------------- | ---------------------- |
| Rear  | Sony IMX363, 12MP     | Samsung S5KGM1SP, 48MP (captured at 4000×3000) |
| Front | Samsung S5K4H7YX, 8MP | Samsung S5K3P9SP, 16MP |

Nothing here is indexed by phone model. `fp3-cam-setup` walks the media
graph, and everything downstream — geometry, Bayer order, device nodes,
white balance — follows the part it finds. `Fp3Camera.info/1` reports it.

## Stills

```elixir
Fp3Camera.snap(:rear, "/root/photo.jpg")
Fp3Camera.snap(:rear, "/root/photo.jpg", focus: :auto, quality: 95)
Fp3Camera.snap(:front, "/root/small.jpg", binned: true)
{:ok, jpeg} = Fp3Camera.snap_bytes(:front)
```

Stills are the sensor's full native resolution, or its 2x2-binned mode
with `binned: true`. There is no output scaling.

## Live H.264 streams

Streams are **raw H.264 over TCP** — not HTTP, so a browser cannot open
them. Rear listens on 8888, front on 8890; each stream also uses the next
port up for its control socket. One client at a time; the stream is
restarted when a client disconnects.

```elixir
{:ok, ref} = Fp3Camera.start_stream(:rear, bitrate: 3_000_000, fps: 30)
Fp3Camera.streams()
Fp3Camera.stop_stream(ref)
```

```console
$ ffplay tcp://nerves.local:8888
$ mpv --profile=low-latency tcp://nerves.local:8888
$ vlc --demux=h264 tcp://nerves.local:8888
```

A running stream can be adjusted without restarting it:

```elixir
Fp3Camera.tune(ref, wb: {1.9, 1.0, 1.5}, focus: 700, saturation: 1.6)
```

Frames are the sensor's binned output centre-cropped to the largest
size Venus accepts within 1080p: **1920×1056**, or **1408×1056** on the
Fairphone 3 front camera.

## Raw frames in Elixir

`subscribe/2` runs `cam-stream --out-nv12` and sends each frame to the
calling process — for Evision, Nx or your own processing:

```elixir
{:ok, pid} = Fp3Camera.subscribe(:rear)

receive do
  {:camera_frame, %{format: :nv12, width: w, height: h, data: nv12}} ->
    # Y plane (w*h bytes) followed by interleaved UV (w*h/2 bytes)
    {w, h, byte_size(nv12)}
end

Fp3Camera.unsubscribe(pid)
```

Frame size follows the same rule as streams; always read `width` and
`height` from the message. The feed stops when the subscribing process
exits or cam-stream does. A camera serves one stream *or* one
subscription at a time.

## Settings

Defaults are compiled into `Fp3Camera.Config`, keyed by fitted sensor
*and* by mode (`:snap` for stills, `:stream` for streams and
subscriptions). Both halves matter: `cam-snap` demosaics with
Malvar-He-Cutler at full resolution while `cam-stream` runs a cheaper
bilinear pass over a 2x2-binned frame, and gains that render a still
neutral leave the stream visibly green on the same sensor.

Resolution order, later winning:

1. the built-in table, by sensor and mode
2. `config :fp3_camera, :defaults, [...]`
3. `config :fp3_camera, :sensor_defaults, %{"imx363" => [...]}`
4. runtime `Fp3Camera.configure/2` (`:all`, then `{camera | sensor, mode}`),
   persisted with `save_config/0`
5. options passed to the call

So calibrating is a session in IEx, not a rebuild:

```elixir
Fp3Camera.configure(:all, gamma: 1.8)
Fp3Camera.configure({:rear, :stream}, wb: {1.9, 1.0, 1.53})
Fp3Camera.save_config()     # /root/fp3-camera.config, reloaded at boot
Fp3Camera.config()
Fp3Camera.reset_config()
```

`snap_stats/2` reports what the sensor measured and what the pipeline
applied, so white balance can be closed as a loop on the device:

```elixir
{:ok, s} = Fp3Camera.snap_stats(:rear)
s.raw     #=> %{bayer: "rggb", r: 114.6, g: 174.0, b: 139.8}
s.gains   #=> %{r: 2.1, g: 1.0, b: 1.5}
Fp3Camera.snap_stats(:rear, wb: {s.raw.g / s.raw.r, 1.0, s.raw.g / s.raw.b})
```

`snap_stats/2` deliberately ignores the config table — it is the
measurement the table is derived from.

### Options

Stills (`snap/3`, `snap_bytes/2`, `snap_stats/2`):

- Sensor: `:exposure` (`:auto` meters first; not for `snap_stats/2`),
  `:gain`, `:focus` (`:auto`, or 0..1023, 0 = infinity — **rear only**),
  `:binned`, `:frames` (average 1..9), `:bayer` (override the detected
  order; debugging only)
- White balance: `:awb`, `:wb` as `{r, g, b}`, `:warm_bias`
- Tone and detail: `:gamma`, `:contrast`, `:saturation`, `:brightness`,
  `:sharpen`, `:denoise`, `:lsc`, `:auto_levels`, `:phone_curve`,
  `:ccm`, `:mhc`, `:quality`

Streams (`start_stream/2`): `:port`, `:bitrate`, `:fps`, `:focus`,
`:exposure`, `:gain`, `:wb`, `:gamma`, `:contrast`, `:saturation`,
`:brightness`. Subscriptions take the same minus `:port`, `:bitrate`
and `:fps`.

All three take `:args`, a list passed verbatim to the binary. The
function docs describe each option.

## Auto-exposure

Nothing in the capture path sets exposure by itself, and the two rear
parts differ enough that one desk under one lamp came out at raw green
154 on the IMX363 and 102 on the S5KGM1SP. `Fp3Camera.AutoExposure`
meters through `snap_stats/2`: take a frame, read the raw green mean,
move exposure, then add gain for whatever exposure could not reach. The
built-in profiles make it the default for stills.

Streams have no metering; binning is two stops brighter, which usually
suffices.

## Checking it works

On the device:

```elixir
Fp3Camera.selftest()
```

Runs setup, detection, a still and a stream on each fitted camera and
judges each on bytes — JPEG magic and SOF dimensions, a counted IDR and
P-frames pulled off the socket, no cam-stream left behind, and no new
venus/camss errors in dmesg.

On a host, `mix test` covers the logic that does not need hardware
(argument building, conf parsing, config layering, frame slicing,
process supervision) against fake binaries.

## Status

The changes in this revision (NV12 frame geometry and stderr handling in
`subscribe/2`, process tracking, error handling, removal of the
`set_defaults` API) are covered by host tests only and **have not yet
been re-verified on a phone**.

## Known limits

- Demosaicing is in software. The msm8953 hardware ISP is not driven.
- Colour is close to Android's on all four sensors but not calibrated
  against a known target; the built-in gains come from one scene.
- Auto-exposure runs out of range on the FP3+ front at full resolution
  in dim light.
- Streams centre-crop rather than scale, so a stream sees less field of
  view than the still from the same camera.
- Taking a still from a camera that is streaming is not supported: both
  binaries reconfigure the same pipeline for their own mode.

## License

Apache-2.0.
