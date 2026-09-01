#!/bin/zsh
# Shell-gate v3 (#1699 slice 1): direct AX paths discovered by live inspection 2026-09-01.
# Inner graph split (identical to legacy chrome's inner tree):
#   inner       = splitter group 1 of group 2 of splitter group 1 of group 1 of window 1
#   search      = text field 1 of group 2 of inner
#   node        = button 1 of group 2 of inner            (unique after "Hcard" filter; count checked)
#   open file   = button 1 of scroll area 1 of group 3 of inner
# Mount check  = static text 1 of content column == "Hcard.astro"
# All interactions are AX presses — no coordinates, no visibility requirement.
set -u
APP="/Users/dwk/Library/Developer/Xcode/DerivedData/Anglesite-hjtawrjcjcxmxaglckvzwofbbtnh/Build/Products/Debug/Anglesite.app"
RUNS="${1:-5}"

for RUN in $(seq 1 "$RUNS"); do
  echo "flag=$(defaults read io.dwk.anglesite experimental.appKitShell 2>/dev/null || echo MISSING)"
  open "$APP"; sleep 6
  osascript -e 'tell application "System Events" to tell process "Anglesite" to click button "Reopen" of window 1' >/dev/null 2>&1
  READY=""
  for i in $(seq 1 80); do
    T=$(osascript -e 'tell application "System Events" to tell process "Anglesite" to get name of window 1' 2>/dev/null)
    case "$T" in *http*) READY=1; break;; esac
    pgrep -x Anglesite >/dev/null || { echo "RUN$RUN: died before repro"; break; }
    sleep 3
  done
  [ -z "$READY" ] && { echo "RUN$RUN: never ready; skipping"; pkill -x Anglesite 2>/dev/null; sleep 2; continue; }
  echo "RUN$RUN site: $T"
  osascript -e 'tell application "System Events" to tell process "Anglesite" to click menu item "Graph…" of menu "Website" of menu bar item "Website" of menu bar 1' >/dev/null 2>&1
  sleep 5
  STEP=$(osascript 2>&1 <<'EOF'
tell application "System Events" to tell process "Anglesite"
  set inner to splitter group 1 of group 2 of splitter group 1 of group 1 of window 1
  set canvasGroup to group 2 of inner
  set tf to text field 1 of canvasGroup
  set focused of tf to true
  set value of tf to "Hcard"
  delay 2
  set nodeCount to count of buttons of canvasGroup
  if nodeCount is not 1 then return "FILTER FAILED: " & nodeCount & " nodes"
  click button 1 of canvasGroup
  delay 2
  click button 1 of scroll area 1 of group 3 of inner
  return "TRIGGER FIRED"
end tell
EOF
)
  echo "RUN$RUN trigger: $STEP"
  if [ "$STEP" != "TRIGGER FIRED" ]; then
    echo "RUN$RUN: DOES NOT COUNT"
    osascript -e 'tell application "Anglesite" to quit' >/dev/null 2>&1; sleep 3; pkill -x Anglesite 2>/dev/null; sleep 2
    continue
  fi
  VERDICT="ALIVE"
  for i in 1 2 3 4 5 6 7 8; do sleep 2; pgrep -x Anglesite >/dev/null || { VERDICT="DEAD after $((i*2))s"; break; }; done
  if [ "$VERDICT" = "ALIVE" ]; then
    sleep 4
    MOUNT=$(osascript -e 'tell application "System Events" to tell process "Anglesite" to get value of static text 1 of group 2 of splitter group 1 of group 1 of window 1' 2>&1)
    echo "RUN$RUN: ALIVE, mount header = [$MOUNT]"
  else
    echo "RUN$RUN: $VERDICT"
  fi
  osascript -e 'tell application "Anglesite" to quit' >/dev/null 2>&1; sleep 3; pkill -x Anglesite 2>/dev/null; sleep 2
done
echo "=== new crash reports:"
ls -t ~/Library/Logs/DiagnosticReports/Anglesite-*.ips 2>/dev/null || echo none
