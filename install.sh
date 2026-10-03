#!/data/data/com.termux/files/usr/bin/bash
# install.sh - check prerequisites, then install gosync/gosane into Termux.
#
# Shared storage (/sdcard) can't hold executable files, so this copies the
# scripts to where Termux runs them:
#   gosane.sh, gosync.js  -> ~/.local/bin
#   shortcuts/*           -> ~/.shortcuts        (Termux:Widget buttons)
#   shortcuts/icons/*     -> ~/.shortcuts/icons
# It also installs any missing packages and puts ~/.local/bin on your PATH.
#
# Usage: bash install.sh      (rerun after every git pull)

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
README=$PWD/README.md
BIN=$HOME/.local/bin
SHORTCUTS=$HOME/.shortcuts

fails=0 warns=0
ok()   { echo "  ok    $*"; }
warn() { echo "  WARN  $*"; warns=$((warns + 1)); }
fail() { echo "  FAIL  $*"; fails=$((fails + 1)); }
more() { echo "        $*"; }

echo "Checking prerequisites..."

# Termux itself. Add-ons must come from the same source as Termux.
if [ -z "${TERMUX_VERSION:-}" ] || [ ! -d /data/data/com.termux ]; then
    echo "  FAIL  not running inside the Termux app. See Requirements in $README"
    exit 1
fi
source_name=${TERMUX_APK_RELEASE:-unknown}
case $source_name in
    F_DROID) ok "Termux $TERMUX_VERSION (F-Droid)" ;;
    *) warn "Termux $TERMUX_VERSION from $source_name, not F-Droid"
       more "Termux:Widget must come from the same source as Termux. See Requirements in README.md." ;;
esac

# Termux:Widget, for the home-screen buttons.
packages=$(cmd package list packages 2>/dev/null)
if [ -z "$packages" ]; then
    warn "couldn't check whether Termux:Widget is installed"
elif grep -qx 'package:com.termux.widget' <<<"$packages"; then
    ok "Termux:Widget installed"
else
    warn "Termux:Widget not installed (needed only for home-screen buttons)"
    more "Get it from F-Droid: https://f-droid.org/packages/com.termux.widget/"
    more "It must come from the same source as Termux. See Requirements in README.md."
fi

# Shared storage access.
if [ ! -w /storage/emulated/0/DCIM ]; then
    echo "  ...   requesting storage access; allow it in the Android prompt"
    termux-setup-storage
    sleep 5
fi
if [ -w /storage/emulated/0/DCIM ]; then
    ok "storage access"
else
    fail "no access to shared storage"
    more "Allow the prompt, or turn on Files/Storage in Android Settings > Apps > Termux > Permissions."
fi

# Packages: install whichever are missing.
need=()
command -v ffmpeg >/dev/null || need+=(ffmpeg)
command -v curl   >/dev/null || need+=(curl)
command -v node   >/dev/null || need+=(nodejs)
command -v flock  >/dev/null || need+=(util-linux)
if [ ${#need[@]} -gt 0 ]; then
    echo "  ...   installing ${need[*]}"
    pkg install -y "${need[@]}" || fail "pkg install ${need[*]} failed (try: pkg update)"
fi
for cmd in ffmpeg ffprobe curl node flock; do
    command -v $cmd >/dev/null || fail "$cmd missing"
done

# ffmpeg needs both encoders gosane.sh uses.
if command -v ffmpeg >/dev/null; then
    encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null)
    for enc in h264_mediacodec libx264; do
        if grep -qw $enc <<<"$encoders"; then ok "ffmpeg has $enc"
        else fail "ffmpeg lacks $enc (Termux's own build has it: pkg install --reinstall ffmpeg)"
        fi
    done
fi

# gosync.js uses fs.statfsSync (Node 18.15+).
if command -v node >/dev/null; then
    if node -e 'process.exit(typeof require("fs").statfsSync === "function" ? 0 : 1)'; then
        ok "Node $(node -v)"
    else
        fail "Node $(node -v) is too old; need 18.15 or newer (pkg upgrade nodejs)"
    fi
fi

if [ $fails -gt 0 ]; then
    echo
    echo "$fails problem(s) above; nothing installed. Fix them and rerun. Details: $README"
    exit 1
fi

# --- Install -----------------------------------------------------------------

echo "Installing..."
install -d -m 700 "$BIN" "$SHORTCUTS" "$SHORTCUTS/icons" &&
install -m 755 gosane.sh gosync.js "$BIN/" &&
install -m 700 shortcuts/gosane shortcuts/gosync "$SHORTCUTS/" &&
install -m 600 shortcuts/icons/*.png "$SHORTCUTS/icons/" ||
    { echo "  FAIL  copying files failed"; exit 1; }
ok "scripts in $BIN"
ok "buttons and icons in $SHORTCUTS"

if grep -qs '\.local/bin' "$HOME/.bashrc"; then
    ok "~/.local/bin is on PATH"
else
    echo 'export PATH="$PATH:$HOME/.local/bin"' >> "$HOME/.bashrc"
    ok "added ~/.local/bin to PATH in ~/.bashrc (open a new Termux session to use it)"
fi

# The camera is optional here: just report whether one is plugged in.
if node -e 'const n=require("os").networkInterfaces();
        process.exit(Object.values(n).flat().some(a=>/^172\.2\d\.1\d\d\./.test(a.address))?0:1)'; then
    ok "GoPro found on USB (try: gosync.js -n)"
else
    echo "  --    no GoPro on USB right now. When you plug it in, set its USB Connection"
    more "to GoPro Connect, turn it on, and try: gosync.js -n"
fi

echo
[ $warns -gt 0 ] && echo "Installed, with $warns warning(s) above. Details: $README" ||
    echo "Installed."
cat <<'EOF'

Last step, by hand (Android won't let an app do it): long-press the
Termux:Widget app icon and drag "gosync" (and "gosane") to the home screen.
See "Install" in README.md for details.
EOF
