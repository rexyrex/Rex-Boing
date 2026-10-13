#!/usr/bin/env bash
# Renders every moving picture in docs/ from the app's own drawing code:
#
#   docs/menubar.gif           the status item, idle to flat out and back
#   docs/rexes.gif             all sixteen rexes, calm then flat out
#   docs/site/load-*.mp4       the website's menu bar item at four loads
#   docs/site/rex/<name>.mp4   one clip per rex for the website's gallery,
#   docs/site/rex/<name>.jpg   with its first frame as the poster
#
# Frames come from Tools/render-frames.swift (the real Visualizer and readout
# renderer); ffmpeg does the encoding. Run from the repository root:
#
#   Tools/render-animations.sh
#
# Needs ffmpeg (brew install ffmpeg).
set -euo pipefail
cd "$(dirname "$0")/.."

command -v ffmpeg >/dev/null || { echo "ffmpeg is required: brew install ffmpeg" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
R="$WORK/render-frames"
F="$WORK/frames"
mkdir -p "$F" docs/site/rex

swiftc -O -o "$R" Tools/render-frames.swift \
  RexBoing/StatusBar/Visualizer.swift RexBoing/StatusBar/StatusBarRenderer.swift \
  RexBoing/App/Preferences.swift RexBoing/App/LoginItem.swift RexBoing/Metrics/Format.swift

# Every rex, in the order the app lists them; display names are the raw
# values capitalised, as Visualizer.name has them.
RAMP=($("$R" --list))
NAMES=()
for c in "${RAMP[@]}"; do NAMES+=("$(tr '[:lower:]' '[:upper:]' <<<"${c:0:1}")${c:1}"); done
COUNT=${#RAMP[@]}
ROWS=$(( (COUNT + 3) / 4 ))
GROUND=0x1d1d21

# --- docs/menubar.gif ------------------------------------------------------
"$R" --char rex --item --out "$F/hero" --scale 8 --fps 30 --dur 9 \
  --loads "0:0.08,2:0.08,6:1.0,8:1.0,9:0.08" >/dev/null
ffmpeg -y -loglevel error -f lavfi -i "color=c=$GROUND:s=1008x256:r=30:d=9" \
  -framerate 30 -i "$F/hero/f%05d.png" \
  -filter_complex "[0][1]overlay=40:40:shortest=1,format=rgb24,split[a][b];[a]palettegen=max_colors=96:stats_mode=full[p];[b][p]paletteuse=dither=none" \
  -loop 0 docs/menubar.gif
echo "wrote docs/menubar.gif"

# --- docs/rexes.gif --------------------------------------------------------
# A grid four tiles wide of 220 × 150 tiles, each name drawn under its rex.
cat > "$WORK/labels.swift" <<'SWIFT'
import AppKit
let names = CommandLine.arguments.dropFirst(3)
let height = CGFloat(Int(CommandLine.arguments[2])!)
let img = NSImage(size: NSSize(width: 880, height: height))
img.lockFocus()
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 17, weight: .medium),
    .foregroundColor: NSColor(white: 0.62, alpha: 1)]
for (i, n) in names.enumerated() {
    let s = NSAttributedString(string: n, attributes: attrs)
    let x = CGFloat(i % 4 * 220) + (220 - s.size().width) / 2
    s.draw(at: NSPoint(x: x, y: height - CGFloat(i / 4 * 150) - 116 - s.size().height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT
swift "$WORK/labels.swift" "$WORK/labels.png" $(( ROWS * 150 )) "${NAMES[@]}"

inputs=(); graph=""; stack=""; layout=""
for i in "${!RAMP[@]}"; do
  "$R" --char "${RAMP[$i]}" --out "$F/g-${RAMP[$i]}" --scale 4 --fps 25 --dur 6 \
    --loads "0:0.3,2:0.3,4.2:1.0,6:1.0" >/dev/null
  inputs+=(-framerate 25 -i "$F/g-${RAMP[$i]}/f%05d.png")
  graph+="color=c=$GROUND:s=220x150:r=25:d=6[bg$i];[bg$i][$i:v]overlay=38:18:shortest=1,format=yuv444p[c$i];"
  stack+="[c$i]"
  layout+="$(( i % 4 * 220 ))_$(( i / 4 * 150 ))|"
done
# Empty tiles fill out a short last row.
for (( i = COUNT; i < ROWS * 4; i++ )); do
  graph+="color=c=$GROUND:s=220x150:r=25:d=6,format=yuv444p[c$i];"
  stack+="[c$i]"
  layout+="$(( i % 4 * 220 ))_$(( i / 4 * 150 ))|"
done
inputs+=(-loop 1 -framerate 25 -i "$WORK/labels.png")
graph+="${stack}xstack=inputs=$(( ROWS * 4 )):layout=${layout%|}[g];[$COUNT:v]scale=880:$(( ROWS * 150 )),format=rgba[l];[g][l]overlay=0:0:shortest=1,format=yuv420p[v]"
ffmpeg -y -loglevel error "${inputs[@]}" -filter_complex "$graph" -map "[v]" -t 6 \
  -c:v libx264 -crf 22 "$WORK/gallery.mp4"
ffmpeg -y -loglevel error -i "$WORK/gallery.mp4" \
  -vf "fps=15,split[a][b];[a]palettegen=max_colors=48[p];[b][p]paletteuse=dither=none" \
  -loop 0 docs/rexes.gif
echo "wrote docs/rexes.gif"

# --- docs/site/load-*.mp4 --------------------------------------------------
# Each loop lasts a whole number of the rex's cycles at that load (rate is
# 0.5 + 2.2 × load cycles a second), so it repeats without a seam. The clips
# are drawn over black: the page lays them over the menu bar with
# mix-blend-mode: lighten, which leaves the black behind and keeps the colours
# exact on any opaque ground.
for spec in idle:0.08:222 working:0.45:141 busy:0.78:149 flat:1.0:100; do
  IFS=: read -r name load frames <<<"$spec"
  "$R" --char rex --item --out "$F/l-$name" --scale 6 --fps 30 \
    --dur "$(echo "scale=6; $frames / 30" | bc)" --loads "0:$load" >/dev/null
  ffmpeg -y -loglevel error -f lavfi -i "color=c=black:s=696x132:r=30" \
    -framerate 30 -i "$F/l-$name/f%05d.png" \
    -filter_complex "[0][1]overlay=0:0:shortest=1,format=yuv420p" -frames:v "$frames" \
    -c:v libx264 -crf 20 -preset slow -movflags +faststart -an "docs/site/load-$name.mp4"
done
echo "wrote docs/site/load-{idle,working,busy,flat}.mp4"

# --- docs/site/rex/ --------------------------------------------------------
for c in "${RAMP[@]}"; do
  "$R" --char "$c" --out "$F/w-$c" --scale 6 --fps 30 --dur 7 \
    --loads "0:0.25,1.8:0.25,3.6:1.0,5.6:1.0,7:0.25" >/dev/null
  ffmpeg -y -loglevel error -f lavfi -i "color=c=black:s=216x132:r=30" \
    -framerate 30 -i "$F/w-$c/f%05d.png" \
    -filter_complex "[0][1]overlay=0:0:shortest=1,format=yuv420p" -frames:v 210 \
    -c:v libx264 -crf 22 -preset slow -movflags +faststart -an "docs/site/rex/$c.mp4"
  ffmpeg -y -loglevel error -f lavfi -i "color=c=black:s=216x132" -i "$F/w-$c/f00000.png" \
    -filter_complex "[0][1]overlay=0:0" -frames:v 1 -q:v 3 "docs/site/rex/$c.jpg"
done
echo "wrote docs/site/rex/ ($COUNT clips and posters)"
