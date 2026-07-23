#!/bin/bash
# Serial watch-folder transcoder for Stash.
#   - H.264 (etc.) -> HEVC via Intel Arc QSV, 8-bit Main, MP4 + hvc1 + AAC
#   - One file at a time. New arrivals queue in the inotify pipe.
#   - State = the watch folder itself: source is deleted only after a
#     successful encode lands in /output. A failed encode leaves the
#     source in /watch to retry. No sidecar dedup log.
#   - Captions: Stash reads only sidecar SRT/VTT. This copies/converts any
#     sidecar subs next to the source and extracts embedded text subs,
#     emitting <basename>[.<lang>].srt next to the output MP4.
set -uo pipefail

WATCH=/watch
OUT=/output

# Tunables ---------------------------------------------------------------
GLOBAL_QUALITY=24        # QSV ICQ quality. Lower = better/bigger. 20-26 typical.
PRESET=veryslow          # hevc_qsv preset ladder (veryfast..veryslow)
AUDIO_BITRATE=160k       # AAC stereo; 128-192k all transparent for this use
MAX_W=1920
MAX_H=1080
# ------------------------------------------------------------------------

SUB_EXTS=(srt vtt ass ssa)

log() { echo "[$(date '+%F %T')] $*"; }

# Map a language tag to a 2-letter ISO-639-1 code, or empty if unknown.
iso2() {
  case "${1,,}" in
    en|eng) echo en ;; ja|jpn) echo ja ;; zh|chi|zho) echo zh ;;
    ko|kor) echo ko ;; es|spa) echo es ;; fr|fra|fre) echo fr ;;
    de|ger|deu) echo de ;; it|ita) echo it ;; pt|por) echo pt ;;
    ru|rus) echo ru ;; nl|dut|nld) echo nl ;;
    *) [ "${#1}" -eq 2 ] && echo "${1,,}" || echo "" ;;
  esac
}

is_sub_ext() {
  local e="${1,,}"
  for x in "${SUB_EXTS[@]}"; do [ "$e" = "$x" ] && return 0; done
  return 1
}

video_codec() {
  ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
    -of csv=p=0 "$1" 2>/dev/null
}

audio_is_aac() {
  [ "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
       -of csv=p=0 "$1" 2>/dev/null)" = "aac" ]
}

# Copy/convert sidecar subtitle files that live next to the source.
# Consumes (deletes) each sidecar only after it is successfully emitted.
handle_sidecar_subs() {
  local in="$1" base="$2" dir fn ext seg lang dest ok
  dir="$(dirname "$in")"
  for s in "$dir"/*; do
    [ -f "$s" ] || continue
    fn="$(basename "$s")"
    case "$fn" in "$base".*) ;; *) continue ;; esac   # literal-prefix match
    ext="${fn##*.}"
    is_sub_ext "$ext" || continue
    seg="${fn#"$base"}"; seg="${seg%.*}"; seg="${seg#.}"  # lang segment, if any
    lang="$(iso2 "$seg")"
    if [ -n "$lang" ]; then dest="$OUT/$base.$lang.srt"; else dest="$OUT/$base.srt"; fi
    ok=1
    case "${ext,,}" in
      srt) cp -f "$s" "$dest" || ok=0 ;;
      *)   ffmpeg -nostdin -y -i "$s" "$dest" </dev/null >/dev/null 2>&1 || ok=0 ;;  # vtt/ass/ssa -> srt
    esac
    if [ "$ok" -eq 1 ]; then
      log "  caption (sidecar): $fn -> $(basename "$dest")"
      rm -f "$s"
    else
      log "  caption FAILED (kept): $fn"
      rm -f "$dest"
    fi
  done
}

# Extract embedded *text* subtitle streams to sidecar SRT. Image-based
# subs (PGS/VOBSUB) are skipped. Best-effort; never fails the job.
handle_embedded_subs() {
  local in="$1" base="$2" n=0 codec lang dest
  while IFS=',' read -r codec lang; do
    case "$codec" in
      subrip|srt|ass|ssa|mov_text|webvtt|text)
        lang="$(iso2 "${lang:-}")"
        if [ -n "$lang" ]; then dest="$OUT/$base.$lang.srt"; else dest="$OUT/$base.und${n}.srt"; fi
        [ -e "$dest" ] && dest="$OUT/$base.embed${n}.srt"
        if ffmpeg -nostdin -y -i "$in" -map 0:s:"$n" -c:s srt "$dest" </dev/null >/dev/null 2>&1; then
          log "  caption (embedded s:$n): -> $(basename "$dest")"
        else
          rm -f "$dest"
        fi
        ;;
    esac
    n=$((n + 1))
  done < <(ffprobe -v error -select_streams s \
             -show_entries stream=codec_name:stream_tags=language \
             -of csv=p=0 "$in" 2>/dev/null)
}

process_video() {
  local in="$1" name base out tmp
  [ -f "$in" ] || return 0
  name="$(basename "$in")"
  base="${name%.*}"
  out="$OUT/$base.mp4"
  tmp="$OUT/.$base.tmp.mp4"
  rm -f "$tmp"

  # Already HEVC -> remux only, never re-encode (no generation loss, no inflation).
  # Still normalizes container + hvc1 tag + faststart for Stash/iPhone.
  if [ "$(video_codec "$in")" = "hevc" ]; then
    local aopt
    if audio_is_aac "$in"; then aopt=(-c:a copy); else aopt=(-c:a aac -b:a "$AUDIO_BITRATE"); fi
    log "Already HEVC, remuxing (no re-encode): $name"
    if ffmpeg -nostdin -y -i "$in" -map 0:v:0 -map 0:a? \
         -c:v copy -tag:v hvc1 "${aopt[@]}" -movflags +faststart "$tmp" </dev/null; then
      mv -f "$tmp" "$out"
      handle_sidecar_subs "$in" "$base"
      handle_embedded_subs "$in" "$base"
      rm -f "$in"
      log "Remuxed: $name -> $base.mp4 (source removed)"
    else
      rm -f "$tmp"
      log "Remux FAILED (left in /watch): $name"
    fi
    return 0
  fi

  log "Encoding: $name"
  if ffmpeg -nostdin -y \
        -init_hw_device qsv=hw -filter_hw_device hw \
        -i "$in" \
        -map 0:v:0 -map 0:a? \
        -vf "scale='min(${MAX_W},iw)':'min(${MAX_H},ih)':force_original_aspect_ratio=decrease,format=nv12,hwupload=extra_hw_frames=64" \
        -c:v hevc_qsv -preset "$PRESET" -global_quality "$GLOBAL_QUALITY" \
        -tag:v hvc1 \
        -c:a aac -b:a "$AUDIO_BITRATE" \
        -movflags +faststart \
        "$tmp" </dev/null; then
    mv -f "$tmp" "$out"
    handle_sidecar_subs "$in" "$base"
    handle_embedded_subs "$in" "$base"
    rm -f "$in"
    log "Done: $name -> $base.mp4 (source removed)"
  else
    rm -f "$tmp"
    log "FAILED (left in /watch for retry): $name"
  fi
}

is_video() {
  case "${1,,}" in
    *.mp4|*.mkv|*.avi|*.mov|*.wmv|*.flv|*.webm|*.ts|*.m4v) return 0 ;;
    *) return 1 ;;
  esac
}

mkdir -p "$OUT"

# 1) Catch up on whatever is already sitting in /watch, one at a time.
log "Startup scan of $WATCH"
while IFS= read -r -d '' f; do
  is_video "$f" && process_video "$f"
done < <(find "$WATCH" -type f -print0)

# 2) Watch for new arrivals. Events queue here while an encode runs.
log "Watching $WATCH for new files"
inotifywait -m -e close_write -e moved_to --format '%w%f' "$WATCH" |
  while read -r f; do
    is_video "$f" && process_video "$f"
  done