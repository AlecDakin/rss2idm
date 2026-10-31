#!/usr/bin/env bash
# rss2idm.sh - fetch RSS/Atom headlines, render a two-line 32x32 scrolling GIF, send to an iDotMatrix display.
#
# Requires: curl, xmllint (libxml2), imagemagick, gifsicle, python3, Unifont (Arch: otf-unifont from the AUR; Debian: fonts-unifont),
#           and python3-idotmatrix-client (https://github.com/derkalle4/python3-idotmatrix-client)
#
# Usage: ./rss2idm.sh [-f] [feed_url]
#   no arguments : rotate through the FEEDS list, one feed per run
#   feed_url     : use just that feed (no rotation)
#   -f           : force a rebuild and upload even if the headlines have not changed

set -euo pipefail

# ImageMagick 6 (e.g. Debian 12) has no "magick" command; fall back to "convert" if so.
if ! command -v magick >/dev/null 2>&1; then
    if command -v convert >/dev/null 2>&1; then
        magick() { convert "$@"; }
    else
        echo "ImageMagick not found - please install it." >&2; exit 1
    fi
fi

# ---- Configuration ---------------------------------------------------------
FORCE=0
if [[ "${1:-}" == "-f" ]]; then FORCE=1; shift; fi

FEEDS=(                                       # one feed is shown per run, in this order
    "https://feeds.bbci.co.uk/news/rss.xml"
    "https://www.theverge.com/rss/index.xml"
    "https://feeds.arstechnica.com/arstechnica/index"
    "https://www.skysports.com/rss/12433"
    "https://techcrunch.com/feed/"
    "https://feeds.feedburner.com/TheHackersNews"
)
ROTATE=1
if [[ -n "${1:-}" ]]; then FEEDS=("$1"); ROTATE=0; fi

UPLOAD_TRIES=3                                # Bluetooth uploads occasionally fail; try again
RETRY_DELAY=5                                 # seconds between upload attempts
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/rss2idm"
MAX_ITEMS=6                                   # split across the two lines (3 per line)
SEPARATOR_CHAR="◆"                            # dim diamond glyph between headlines (U+25C6)
SEPARATOR_COLOR="gray35"
LINE1_COLOR="white"
LINE2_COLOR_DEFAULT="orange"                  # used if no icon, or colour detection fails
ICON_FALLBACK_BG="orange"                     # background colour of the generic "RSS" icon used when a feed has none
ICON_FALLBACK_FG="black"                      # text colour of that icon
SHOW_CLOCK=1                                  # 1 = append time (line 1) and date (line 2) after the headlines
FONT=$(fc-match -f '%{file}' "Unifont")        # GNU Unifont: 8x16 bitmap font (yay -S otf-unifont)
case "${FONT,,}" in *unifont*) ;; *) echo "Unifont not found - Arch: yay -S otf-unifont | Debian: sudo apt install fonts-unifont (then fc-cache -f)" >&2; exit 1 ;; esac
USE_ICON=1                                    # 1 = prepend the feed's own icon, 0 = text only
ICON_MAX_WIDTH=160                            # icon is scaled to 32px high; any width up to this is kept
POINTSIZE=16                                  # Unifont's native size: pixel-perfect 8x16 glyphs
LINE_HEIGHT=16                                # two lines x 16px = 32px display height
STEP=2                                        # pixels per frame
DELAY=8                                       # 1/100ths of a second per frame (higher = slower)
IDM_DIR="$HOME/python3-idotmatrix-client"
IDM_ADDRESS="auto"                            # or e.g. 00:11:22:33:44:ff
OUT_GIF="$HOME/rss_scroll.gif"
# ----------------------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT                    # always leaves no stale frames behind

# Only one run at a time (a slow Bluetooth upload must not overlap the next cron run)
mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || { echo "Another run is already in progress; exiting."; exit 0; }

retry() {   # retry <tries> <delay> <command...>
    local tries=$1 delay=$2 n=1; shift 2
    until "$@"; do
        if (( n >= tries )); then echo "Failed after $tries attempts: $1" >&2; return 1; fi
        echo "Attempt $n failed; retrying in ${delay}s..." >&2
        n=$((n + 1)); sleep "$delay"
    done
}

# 1. Choose the next feed and pull out its headlines (RSS <item> or Atom <entry>).
#    An unreachable or empty feed is skipped in favour of the next one in the list.
NFEEDS=${#FEEDS[@]}
IDX=0
if (( ROTATE )) && [[ -r "$STATE_DIR/next_index" ]]; then IDX=$(<"$STATE_DIR/next_index"); fi
[[ "$IDX" =~ ^[0-9]+$ ]] || IDX=0

XPATH_TITLES="//item/title | //*[local-name()='entry']/*[local-name()='title']"
FEED_URL=""; COUNT=0; FEED_INDEX=0
for ((a = 0; a < NFEEDS; a++)); do
    CAND=$(( (IDX + a) % NFEEDS ))
    if curl -fsSL --retry 2 --max-time 20 "${FEEDS[CAND]}" -o "$WORK/feed.xml" 2>/dev/null; then
        COUNT=$(xmllint --xpath "count($XPATH_TITLES)" "$WORK/feed.xml" 2>/dev/null || echo 0)
        if (( COUNT > 0 )); then FEED_URL="${FEEDS[CAND]}"; FEED_INDEX=$CAND; break; fi
    fi
    echo "Skipping unusable feed: ${FEEDS[CAND]}" >&2
done
[[ -n "$FEED_URL" ]] || { echo "No usable feed found." >&2; exit 1; }
echo "Feed: $FEED_URL"
(( COUNT > MAX_ITEMS )) && COUNT=$MAX_ITEMS

# Odd-numbered headlines go on the top line, even-numbered on the bottom line
tidy() { printf '%s' "$1" | python3 -c "import sys,html; sys.stdout.write(html.unescape(sys.stdin.read()))" | tr -s '[:space:]' ' ' | sed 's/%/%%/g'; }
LINE1_ITEMS=(); LINE2_ITEMS=()
for ((n = 1; n <= COUNT; n++)); do
    TITLE=$(tidy "$(xmllint --xpath "string(($XPATH_TITLES)[$n])" "$WORK/feed.xml")")
    if (( n % 2 )); then LINE1_ITEMS+=("$TITLE"); else LINE2_ITEMS+=("$TITLE"); fi
done
(( ${#LINE2_ITEMS[@]} )) || LINE2_ITEMS=(" ")
echo "Top:    ${LINE1_ITEMS[*]}"
echo "Bottom: ${LINE2_ITEMS[*]}"

# Skip the slow render and upload if this exact content is already on the display
FINGERPRINT=$(printf '%s\n%s\n%s' "$FEED_URL" "${LINE1_ITEMS[*]}" "${LINE2_ITEMS[*]}" | sha256sum | cut -d' ' -f1)
save_rotation() { if (( ROTATE )); then echo $(( (FEED_INDEX + 1) % NFEEDS )) > "$STATE_DIR/next_index"; fi; }
if (( ! FORCE )) && [[ -r "$STATE_DIR/last_hash" && "$(<"$STATE_DIR/last_hash")" == "$FINGERPRINT" ]]; then
    echo "Headlines unchanged since the last upload; nothing to do."
    save_rotation
    exit 0
fi

# 3. Determine the second line's colour from the feed icon's dominant colour (set after the
#    icon is fetched below); render each headline separately with a dim diamond between them,
#    pad both lines to the same width, then stack into one 32px-high block.
LINE2_COLOR="$LINE2_COLOR_DEFAULT"

render_glyph() {   # render_glyph <text> <colour> <out.png>
    magick -background black -fill "$2" -font "$FONT" -pointsize "$POINTSIZE" +antialias \
        label:"$1" -gravity center -extent "x${LINE_HEIGHT}" "$3"
}

build_line() {   # build_line <out.png> <colour> <item...>
    local out="$1" colour="$2"; shift 2
    local parts=() first=1
    for item in "$@"; do
        [[ -n "$item" ]] || continue
        if (( ! first )); then
            render_glyph "$SEPARATOR_CHAR" "$SEPARATOR_COLOR" "$WORK/sep_$$.png"
            parts+=("$WORK/sep_$$.png")
        fi
        render_glyph "$item" "$colour" "$WORK/part_${#parts[@]}_$$.png"
        parts+=("$WORK/part_${#parts[@]}_$$.png")
        first=0
    done
    magick "${parts[@]}" +append "$out"
}

ICON_LIMIT=0                                  # frames starting before this x offset contain the icon
# Optional: fetch the feed's own icon (RSS <image><url>, or Atom <icon>/<logo>) and prepend it.
# Its dominant colour, if found, is used for the second line of text.
if (( USE_ICON )); then
    ICON_URL=$(xmllint --xpath "string(//channel/image/url)" "$WORK/feed.xml" 2>/dev/null || true)
    [[ -n "$ICON_URL" ]] || ICON_URL=$(xmllint --xpath "string(//*[local-name()='icon'])" "$WORK/feed.xml" 2>/dev/null || true)
    [[ -n "$ICON_URL" ]] || ICON_URL=$(xmllint --xpath "string(//*[local-name()='logo'])" "$WORK/feed.xml" 2>/dev/null || true)

    ICON_OK=0
    if [[ -n "$ICON_URL" ]] && curl -fsSL --max-time 15 "$ICON_URL" -o "$WORK/icon_raw" 2>/dev/null \
       && magick "$WORK/icon_raw[0]" -background black -alpha remove -alpha off \
              -resize x32 -gravity west -crop "${ICON_MAX_WIDTH}x32+0+0" +repage -strip "$WORK/icon.png" 2>/dev/null; then
        ICON_OK=1
        echo "Icon: $ICON_URL"

        # Dominant colour: quantise to a handful of colours and take the most frequent one that
        # is not near-black or near-white (those are usually background, not the icon's subject).
        DOM=$(magick "$WORK/icon.png" -colors 8 -depth 8 -format %c histogram:info: 2>/dev/null \
              | sort -n -r \
              | grep -Eiv '#(00){3}|#(ff){3}|#0[0-2]0[0-2]0[0-2]|#f[de]f[de]f[de]' \
              | head -1 | grep -oE '#[0-9A-Fa-f]{6}' || true)
        [[ -n "$DOM" ]] && LINE2_COLOR="$DOM"
        echo "Line 2 colour: $LINE2_COLOR"
    fi

    # No real icon: fall back to a generated "RSS" wordmark instead of leaving the display bare
    if (( ! ICON_OK )); then
        echo "No usable icon found; using a generic RSS icon."
        magick -background "$ICON_FALLBACK_BG" -fill "$ICON_FALLBACK_FG" -font "$FONT" -pointsize 32 +antialias \
            label:"RSS" -gravity center -extent x32 "$WORK/icon.png"
        IW=$(identify -format "%w" "$WORK/icon.png")
        if (( IW > ICON_MAX_WIDTH )); then
            magick "$WORK/icon.png" -gravity center -crop "${ICON_MAX_WIDTH}x32+0+0" +repage "$WORK/icon.png"
        fi
    fi
    ICON_LIMIT=$(( 32 + $(identify -format '%w' "$WORK/icon.png") ))   # 32px lead-in + icon width
fi

build_line "$WORK/l1.png" "$LINE1_COLOR" "${LINE1_ITEMS[@]}"
build_line "$WORK/l2.png" "$LINE2_COLOR" "${LINE2_ITEMS[@]}"

W1=$(identify -format "%w" "$WORK/l1.png"); W2=$(identify -format "%w" "$WORK/l2.png")
MAXW=$(( W1 > W2 ? W1 : W2 ))
for f in l1 l2; do
    magick "$WORK/$f.png" -background black -gravity west -extent "${MAXW}x${LINE_HEIGHT}" "$WORK/${f}p.png"
done

# Clock: appended after the headlines at the same x-offset on both lines, so the date sits
# directly below the time as the display scrolls past.
if (( SHOW_CLOCK )); then
    # Prefer the feed's own timestamp over the local clock: channel-level first
    # (RSS lastBuildDate/pubDate, Atom updated), then the newest item's date, as a fallback.
    FEED_DATE_RAW=$(xmllint --xpath "string(//channel/lastBuildDate)" "$WORK/feed.xml" 2>/dev/null || true)
    [[ -n "$FEED_DATE_RAW" ]] || FEED_DATE_RAW=$(xmllint --xpath "string(//channel/pubDate)" "$WORK/feed.xml" 2>/dev/null || true)
    [[ -n "$FEED_DATE_RAW" ]] || FEED_DATE_RAW=$(xmllint --xpath "string(//*[local-name()='feed']/*[local-name()='updated'])" "$WORK/feed.xml" 2>/dev/null || true)
    [[ -n "$FEED_DATE_RAW" ]] || FEED_DATE_RAW=$(xmllint --xpath "string((//item/pubDate | //*[local-name()='entry']/*[local-name()='updated'])[1])" "$WORK/feed.xml" 2>/dev/null || true)

    if [[ -n "$FEED_DATE_RAW" ]] && FEED_EPOCH=$(date -d "$FEED_DATE_RAW" +%s 2>/dev/null); then
        TIME_STR=$(date -d "@$FEED_EPOCH" +%H:%M)
        DATE_STR=$(date -d "@$FEED_EPOCH" +"%-d %b")
    else
        echo "No usable date found in the feed; showing the local time instead." >&2
        TIME_STR=$(date +%H:%M)
        DATE_STR=$(date +"%-d %b")
    fi

    render_glyph "$SEPARATOR_CHAR" "$SEPARATOR_COLOR" "$WORK/csep.png"
    render_glyph "$TIME_STR" "$LINE1_COLOR" "$WORK/time.png"
    render_glyph "$DATE_STR" "$LINE2_COLOR" "$WORK/date.png"
    magick "$WORK/l1p.png" "$WORK/csep.png" "$WORK/time.png" +append "$WORK/l1p.png"
    magick "$WORK/l2p.png" "$WORK/csep.png" "$WORK/date.png" +append "$WORK/l2p.png"
fi

magick "$WORK/l1p.png" "$WORK/l2p.png" -append "$WORK/strip.png"

if [[ -s "$WORK/icon.png" ]]; then
    magick "$WORK/icon.png" -background black -size 8x32 xc:black "$WORK/strip.png" +append "$WORK/strip.png"
fi

WIDTH=$(identify -format "%w" "$WORK/strip.png")
magick -size $((WIDTH + 64))x32 xc:black "$WORK/strip.png" -geometry +32+0 -composite "$WORK/padded.png"

FULL_WIDTH=$((WIDTH + 64))
mkdir -p "$WORK/frames_icon" "$WORK/frames_text"
i=0
for ((x = 0; x <= FULL_WIDTH - 32; x += STEP)); do
    if (( x < ICON_LIMIT )); then DIR="frames_icon"; else DIR="frames_text"; fi
    magick "$WORK/padded.png" -crop 32x32+${x}+0 +repage "$WORK/$DIR/f_$(printf '%05d' $i).png"
    i=$((i + 1))
done
echo "Frames: $i"

# 5. Reduce colours on the text frames only, then put the full-colour icon frames in front
magick -delay "$DELAY" -loop 0 "$WORK/frames_text"/*.png "$WORK/text.gif"
gifsicle --colors 8 "$WORK/text.gif" -o "$WORK/text4.gif"

PARTS=("$WORK/text4.gif")
if compgen -G "$WORK/frames_icon/*.png" > /dev/null; then
    magick -delay "$DELAY" -loop 0 "$WORK/frames_icon"/*.png "$WORK/icon_part.gif"
    PARTS=("$WORK/icon_part.gif" "$WORK/text4.gif")
fi
gifsicle -O3 --loopcount=forever "${PARTS[@]}" -o "$OUT_GIF"
ls -lh "$OUT_GIF"

# 6. Send to the display, retrying if the Bluetooth connection drops.
#    State is only saved after a successful upload, so a failed run is retried next time.
retry "$UPLOAD_TRIES" "$RETRY_DELAY" "$IDM_DIR/run_in_venv.sh" --address "$IDM_ADDRESS" --set-gif "$OUT_GIF"
echo "$FINGERPRINT" > "$STATE_DIR/last_hash"
save_rotation
