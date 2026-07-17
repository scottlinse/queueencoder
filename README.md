# queueencoder

Serial watch-folder transcoder for [Stash](https://stashapp.cc), built for
Intel Arc (QSV) hardware encoding on Unraid.

Drop videos (plus any sidecar subtitle files) into `/watch`. They come out of
`/output` as iPhone/Safari direct-play friendly **MP4 + HEVC (`hvc1`) + AAC**,
with Stash-compatible sidecar `.srt` captions. Sources are removed from
`/watch` only after a successful encode; failures stay put and retry.

## Behavior

- One file at a time (serial queue via inotify; events buffer during encodes)
- Sources already in HEVC are **remuxed** (stream-copy + `hvc1` + faststart),
  never re-encoded - no generation loss, no bitrate inflation
- Everything else is encoded with `hevc_qsv` (8-bit Main, capped at 1080p,
  never upscaled)
- Sidecar `srt/vtt/ass/ssa` next to the source are copied/converted to
  `.srt` beside the output; embedded *text* subs are extracted too
  (image-based PGS/VOBSUB are skipped - MP4 can't hold them and Stash
  can't read embedded subs anyway)
- Atomic output: encodes go to a hidden temp file and are moved into place
  only on success

## Configuration

On first run the container writes `encode.conf` into `/config` (map this to
appdata). It is **re-read before every file**, so edits apply to the next
encode without restarting the container.

Knobs: `GLOBAL_QUALITY` (ICQ, CRF-like, lower = better), `PRESET`,
`AUDIO_BITRATE`, `MAX_W`/`MAX_H`, `REMUX_HEVC`, `HANDLE_CAPTIONS`,
`DELETE_ORIGINAL` (false moves sources to `/copy` instead), and
`VIDEO_EXTENSIONS`. For full control, `FFMPEG_OVERRIDE_ARGS` replaces the
entire generated argument list.

## Usage

See `docker-compose.yml`. Requirements:

- `/dev/dri/renderD128` passed through (Intel iGPU or Arc)
- `group_add` with the GID that owns the render device

Sanity check after first start:

```bash
docker exec queueencoder vainfo | grep -i hevc     # HEVC encode entrypoints
docker exec queueencoder ffmpeg -hide_banner -encoders | grep hevc_qsv
```

## Stash caption notes

Stash only reads **sidecar** SRT/VTT files named like the scene
(`scene.mp4` -> `scene.srt` or `scene.en.srt`) in the same folder it scans.
Captions added after a scene was first scanned need a **Selective scan** to
be picked up.

## Image

Built by GitHub Actions and published to GHCR on every push to `main`,
plus a weekly rebuild to pick up `linuxserver/ffmpeg` base updates.
