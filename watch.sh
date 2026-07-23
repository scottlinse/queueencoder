#!/bin/bash
# queueencoder: serial watch-folder transcoder for Stash.
#   - H.264 (etc.) -> HEVC via Intel QSV (Arc), 8-bit Main, MP4 + hvc1 + AAC
#   - One file at a time; new arrivals queue in the inotify pipe
#   - State = the watch folder: source removed only after success; failures
#     stay in /watch and retry on next event or container restart
#   - Config: /config/encode.conf, re-sourced before every file so edits
#     apply to the next encode without a restart
set -uo pipefail

WATCH=/watch
OUT=/output
COPY=/copy
CONF=/config/encode.conf

log() { echo "[$(date '+%F %T')] $*"; }

# Seed default config into /config on first run so it's editable in appdata.
mkdir -p /config "$OUT"
if [ ! -f "$CONF" ]; then
  cp /defaults/encode.conf "$CONF"
  log "Wrote default config to $CONF - edit it to tune encoding."
fi

load_conf() {
  # Defaults (used if config is missing/partial)
  GLOBAL_QUALITY=24
  PRESET=veryslow
  AUDIO_BITRATE=160k
  MAX_W=1920
  MAX_H=1080
  REMUX_HEVC=true
  HANDLE_CAPTIONS=true
  DELETE_ORIGINAL=true
  VIDEO_EXTENSIONS=(mp4 mkv avi mov wmv flv webm ts m4v)
  FFMPEG_OVERRIDE_ARGS=()
  # shellcheck source=/dev/null
  [ -f "$CONF" ] && source "$CONF"
}

SUB_EXTS=(srt vtt ass ssa)

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

is_video() {
  local e="${1##*.}"; e="${e,,}"
  for x in "${VIDEO_EXTENSIONS[@]}"; do [ "$e" = "$x" ] && return 0; done
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
handle_sidecar_subs() {
  local in="$1" base="$2" dir fn ext seg lang dest ok
  dir="$(dirname "$in")"
  for s in "$dir"/*; do
    [ -f "$s" ] || continue
    fn="$(basename "$s")"
    case "$fn" in "$base".*) ;; *) continue ;; esac
    ext="${fn##*.}"
    is_sub_ext "$ext" || continue
    seg="${fn#"$base"}"; seg="${seg%.*}"; seg="${seg#.}"
    lang="$(iso2 "$seg")"
    if [ -n "$lang" ]; then dest="$OUT/$base.$lang.srt"; else dest="$OUT/$base.srt"; fi
    ok=1
    case "${ext,,}" in
      srt) cp -f "$s" "$dest" || ok=0 ;;
      *)   ffmpeg -nostdin -y -i "$s" "$dest" </dev/null >/dev/null 2>&1 || ok=0 ;;
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

# Extract embedded text subtitle streams to sidecar SRT (image subs skipped).
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

finish_success() {  # $1=in $2=base $3=verb
  local in="$1" base="$2"
  [ "$HANDLE_CAPTIONS" = true ] && { handle_sidecar_subs "$in" "$base"; handle_embedded_subs "$in" "$base"; }
  if [ "$DELETE_ORIGINAL" = true ]; then
    rm -f "$in"
    log "$3: $(basename "$in") -> $base.mp4 (source removed)"
  else
    mkdir -p "$COPY"
    mv -f "$in" "$COPY/"
    log "$3: $(basename "$in") -> $base.mp4 (source moved to /copy)"
  fi
}

# Build a collision-safe output base name. Prefixes with the file's parent
# subfolder (relative to $WATCH) so identically-named files from different
# batches/folders (e.g. video1.mp4 in two different download folders) don't
# overwrite each other. Falls back to a numeric suffix if a collision still
# somehow occurs.
unique_base() {
  local in="$1" name orig_base rel_dir prefix candidate n
  name="$(basename "$in")"
  orig_base="${name%.*}"
  rel_dir="$(dirname "$in")"
  rel_dir="${rel_dir#"$WATCH"}"
  rel_dir="${rel_dir#/}"
  if [ -n "$rel_dir" ]; then
    prefix="$(echo "$rel_dir" | tr '/' '_' | tr -cd 'A-Za-z0-9_.-')"
    candidate="${prefix}__${orig_base}"
  else
    candidate="$orig_base"
  fi
  # If that name is already taken in /output (or /copy), bump a numeric suffix.
  if [ -e "$OUT/$candidate.mp4" ]; then
    n=2
    while [ -e "$OUT/${candidate}_$n.mp4" ]; do n=$((n + 1)); done
    candidate="${candidate}_$n"
  fi
  echo "$candidate"
}

process_video() {
  local in="$1" name base out tmp
  [ -f "$in" ] || return 0
  load_conf
  is_video "$in" || return 0
  name="$(basename "$in")"
  base="$(unique_base "$in")"
  out="$OUT/$base.mp4"
  tmp="$OUT/.$base.tmp.mp4"
  rm -f "$tmp"

  # Already HEVC -> remux only (no generation loss, no bitrate inflation).
  if [ "$REMUX_HEVC" = true ] && [ "$(video_codec "$in")" = "hevc" ]; then
    local aopt
    if audio_is_aac "$in"; then aopt=(-c:a copy); else aopt=(-c:a aac -b:a "$AUDIO_BITRATE"); fi
    log "Already HEVC, remuxing (no re-encode): $name"
    if ffmpeg -nostdin -y -i "$in" -map 0:v:0 -map 0:a? \
         -c:v copy -tag:v hvc1 "${aopt[@]}" -movflags +faststart "$tmp" </dev/null; then
      mv -f "$tmp" "$out"
      finish_success "$in" "$base" "Remuxed"
    else
      rm -f "$tmp"
      log "Remux FAILED (left in /watch): $name"
    fi
    return 0
  fi

  local args
  if [ "${#FFMPEG_OVERRIDE_ARGS[@]}" -gt 0 ]; then
    args=("${FFMPEG_OVERRIDE_ARGS[@]}")
  else
    args=(-init_hw_device qsv=hw -filter_hw_device hw
      -map 0:v:0 -map 0:a?
      -vf "scale=w='if(gt(iw,ih),min(${MAX_W},iw),min(${MAX_H},iw))':h='if(gt(iw,ih),min(${MAX_H},ih),min(${MAX_W},ih))':force_original_aspect_ratio=decrease,format=nv12,hwupload=extra_hw_frames=64"
      -c:v hevc_qsv -preset "$PRESET" -global_quality "$GLOBAL_QUALITY"
      -tag:v hvc1
      -c:a aac -b:a "$AUDIO_BITRATE"
      -movflags +faststart)
  fi

  log "Encoding: $name"
  if ffmpeg -nostdin -y -i "$in" "${args[@]}" "$tmp" </dev/null; then
    mv -f "$tmp" "$out"
    finish_success "$in" "$base" "Done"
  else
    rm -f "$tmp"
    log "FAILED (left in /watch for retry): $name"
  fi
}

# 1) Catch up on whatever is already in /watch, one at a time.
load_conf
log "Startup scan of $WATCH"
while IFS= read -r -d '' f; do
  process_video "$f"
done < <(find "$WATCH" -type f -print0)

# 2) Watch for new arrivals. Events queue while an encode runs.
log "Watching $WATCH for new files"
inotifywait -m -r -e close_write -e moved_to --format '%w%f' "$WATCH" |
  while read -r f; do
    process_video "$f"
  done