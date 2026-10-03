#!/data/data/com.termux/files/usr/bin/bash
# gosane.sh - convert GoPro HEVC clips into H.264 the phone can play.
#
# Finds GoPro .mp4 files with no _1080/_4k suffix, and for each one that is
# HEVC, writes <name>_1080.mp4 (or _4k) into DCIM/Camera, then moves the HEVC
# original into DCIM/GoPro-HEVC (hidden from the gallery by .nomedia).
#
# Usage: gosane.sh [-4] [-hw] [-n] [file|dir ...]
#   -4    4K output (fits in 3840x2160) instead of 1080p (fits in 1920x1080)
#   -hw   encode with the hardware encoder (faster, but this phone's puts only
#         one keyframe in the whole clip, which Google Photos can't edit)
#   -n    dry run: list what would be converted
#   With no file/dir arguments, scans DCIM/Camera and Movies/GoPro-Exports.

set -u

STORAGE=/storage/emulated/0
OUT_DIR=$STORAGE/DCIM/Camera
ARCHIVE=$STORAGE/DCIM/GoPro-HEVC
DEFAULT_SOURCES=("$STORAGE/DCIM/Camera" "$STORAGE/Movies/GoPro-Exports")
LOG=$HOME/gosane.log
SETTLE_SECS=${GOSANE_SETTLE_SECS:-60}  # skip files modified this recently (sync still writing)

res=1080 enc=sw dry=0 sources=()
for arg in "$@"; do
    case $arg in
        -4)  res=4k ;;
        -hw) enc=hw ;;
        -n)  dry=1 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)  echo "unknown option: $arg" >&2; exit 2 ;;
        *)   sources+=("$arg") ;;
    esac
done
[ ${#sources[@]} -eq 0 ] && sources=("${DEFAULT_SOURCES[@]}")

if [ $res = 4k ]; then long=3840 short=2160 rate=45M
else                   long=1920 short=1080 rate=16M
fi
# Fit inside long x short (either orientation), keeping aspect ratio.
scale="scale=w='if(gte(iw,ih),$long,$short)':h='if(gte(iw,ih),$short,$long)'"
scale+=":force_original_aspect_ratio=decrease:force_divisible_by=2"
if [ $enc = hw ]; then
    encoder=h264_mediacodec
    vcodec=(-vf "$scale,format=nv12" -c:v $encoder -b:v $rate -g 30)
else
    encoder=libx264
    vcodec=(-vf "$scale,format=yuv420p" -c:v $encoder -preset faster -crf 20 -g 30)
fi

die() { echo "gosane.sh: $*" >&2; exit 1; }

# Preflight: shared storage access, and an ffmpeg with the needed encoder.
[ -r "$STORAGE" ] && [ -w "$OUT_DIR" ] ||
    die "can't read/write $OUT_DIR.
  Run termux-setup-storage and allow file access, or turn on Termux's
  Files/Storage permission in Android Settings > Apps > Termux > Permissions."
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null ||
    die "ffmpeg not found. Install it with: pkg install ffmpeg"
ffmpeg -hide_banner -encoders 2>/dev/null | grep -qw "$encoder" ||
    die "this ffmpeg has no $encoder encoder.
  Reinstall Termux's build with: pkg install --reinstall ffmpeg$(
    [ $enc = hw ] && printf '\n  Or drop -hw to encode in software.')"

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

probe() {  # probe <file> <entry> -> value from first video stream / format
    ffprobe -v error -select_streams v:0 -show_entries "$2" \
        -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1
}

is_gopro_name() {  # GX010079.MP4, GH01..., GOPR1234, GP011234, GS..., Quik's GX..._ALTA...
    [[ ${1^^} =~ ^(G[HXS][0-9]{6}|GOPR[0-9]{4}|GP[0-9]{6}) ]]
}

tmp=
trap '[ -n "$tmp" ] && rm -f "$tmp"; exit 130' INT TERM

exec 9>"$HOME/.gosane.lock"
flock -n 9 || { echo "gosane.sh is already running" >&2; exit 1; }

# Collect candidates.
files=()
for src in "${sources[@]}"; do
    if [ -d "$src" ]; then
        while IFS= read -r -d '' f; do files+=("$f"); done < <(
            find "$src" -maxdepth 1 -type f -iname '*.mp4' -print0 | sort -z)
    elif [ -f "$src" ]; then
        files+=("$src")
    else
        echo "no such file or directory: $src" >&2
    fi
done

now=$(date +%s) done_n=0 fail_n=0
for f in "${files[@]}"; do
    name=$(basename "$f")
    stem=${name%.*}
    shopt -s nocasematch
    [[ $stem =~ _(1080|4k)$ ]] && { shopt -u nocasematch; continue; }
    shopt -u nocasematch
    is_gopro_name "$name" || continue
    [ "$(probe "$f" stream=codec_name)" = hevc ] || continue

    if (( now - $(stat -c %Y "$f") < SETTLE_SECS )); then
        log "SKIP $name: modified in the last ${SETTLE_SECS}s, may still be syncing"
        continue
    fi
    out=$OUT_DIR/${stem}_$res.mp4
    if [ -e "$out" ]; then
        log "SKIP $name: $(basename "$out") already exists (delete it to redo)"
        continue
    fi
    if [ $dry = 1 ]; then
        echo "would convert $f -> $out"
        continue
    fi

    # A GoPro with a reset clock stamps clips 2016; use the file time instead.
    date_fix=()
    ctime=$(probe "$f" format_tags=creation_time)
    if [[ ! $ctime =~ ^20[2-9][0-9] ]]; then
        ctime=$(date -u -d "@$(stat -c %Y "$f")" +%FT%T.000000Z)
        date_fix=(-metadata creation_time=$ctime -metadata:s creation_time=$ctime)
        log "DATE $name: bad creation time, using file time $ctime"
    fi

    log "CONVERT $name -> $(basename "$out") ($enc)"
    tmp=$OUT_DIR/.${stem}_$res.tmp.mp4
    start=$(date +%s)
    if ! ffmpeg -nostdin -hide_banner -loglevel error -y -i "$f" \
            -map 0:v:0 -map '0:a?' "${vcodec[@]}" -c:a copy \
            -map_metadata 0 -map_chapters -1 "${date_fix[@]}" -write_tmcd 0 -movflags +faststart "$tmp"; then
        log "FAIL $name: ffmpeg error"
        rm -f "$tmp"; tmp=; fail_n=$((fail_n + 1)); continue
    fi

    # Verify: H.264 and the same duration as the source (within half a second).
    in_dur=$(probe "$f" format=duration) out_dur=$(probe "$tmp" format=duration)
    if [ "$(probe "$tmp" stream=codec_name)" != h264 ] ||
       ! awk -v a="$in_dur" -v b="$out_dur" 'BEGIN { d = a - b; exit !(d < 0.5 && d > -0.5) }'; then
        log "FAIL $name: output did not verify (duration $in_dur vs $out_dur)"
        rm -f "$tmp"; tmp=; fail_n=$((fail_n + 1)); continue
    fi
    mv "$tmp" "$out"; tmp=
    touch -r "$f" "$out"

    # Archive the original, unless it's already there.
    if [ "$(cd "$(dirname "$f")" && pwd -P)" != "$(mkdir -p "$ARCHIVE" && cd "$ARCHIVE" && pwd -P)" ]; then
        touch "$ARCHIVE/.nomedia"
        if [ -e "$ARCHIVE/$name" ]; then
            log "WARN $name: already in $ARCHIVE, original left in place"
        else
            mv "$f" "$ARCHIVE/"
        fi
    fi
    log "DONE $name in $(( $(date +%s) - start ))s, $(du -h "$out" | cut -f1)"
    done_n=$((done_n + 1))
done

[ $dry = 0 ] && log "converted $done_n, failed $fail_n"
[ $fail_n -eq 0 ]
