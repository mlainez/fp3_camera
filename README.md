# fp3_camera

> ### ⚠️ Very early work — built for a workshop, not for production
>
> Written for the **Goatmire Elixir workshop** on running Nerves on
> Fairphone 3 hardware. It exists for tinkering and teaching.
>
> **Not an actively maintained project** (yet) — no stability
> guarantees, no test coverage, APIs will change without notice.

Stills and live video from the Fairphone 3+ rear and front cameras,
under Nerves.

## Cameras

| Camera | Sensor | Resolution | Format |
|---|---|---|---|
| `:rear` | Samsung S5KGM1SP | 48 MP, 4000×3000 | SGRBG10 |
| `:front` | Samsung S5K3P9SP | 16 MP, 4608×3456 | SGRBG10 |

## Install

```elixir
defp deps do
  [{:fp3_camera, github: "mlainez/fp3_camera"}]
end
```

Requires a Nerves system with the msm8953 CAMSS driver — see
[`nerves_system_fp3`](https://github.com/mlainez/nerves_system_fp3).

## Usage

```elixir
# Single frame to JPEG
{:ok, path} = Fp3Camera.snap(:rear, "/tmp/photo.jpg")

# MJPEG stream over HTTP
{:ok, _stream} = Fp3Camera.start_stream(:rear, port: 8080)
# open http://nerves.local:8080/ in a browser

# Sensor metadata
Fp3Camera.info(:rear)
```

## About image quality

Set expectations before you point this at anything important.

The msm8953 CAMSS subsystem hands you **raw 10-bit packed Bayer** from a
`/dev/videoN` node. The proprietary ISP that a normal phone camera app
relies on — auto-exposure, auto-white-balance, autofocus, noise
reduction, tone mapping — runs as Hexagon DSP firmware that isn't
shipped here.

So frames go straight from the sensor through a NEON-accelerated Bayer
demosaic. The result is a real, viewable, shareable image. It is *not*
tuned the way a phone-app capture is: expect flat colour, no AE/AWB
convergence, and fixed focus.

That's a fair trade for a workshop — you get pixels off real phone camera
hardware from Elixir, which is the interesting part.

## License

Apache-2.0
