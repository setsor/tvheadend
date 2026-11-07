#!/bin/sh
# Restore the tested TVHeadend + Comskip post-remove integration.
# Run INSIDE the tvheadend container as root:
#   docker exec -i -u 0 tvheadend sh -s < restore.sh
#
# Only patches four Comskip INI keys, installs the removal hook, and prints
# the two DVR profile commands. Does not alter Docker or existing DVR jobs.
set -eu

INI=/config/comskip/comskip.ini
HOOK=/config/comskip/post-remove.sh

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[ "$(id -u)" = 0 ] || fail "run as root inside the container (-u 0)"
[ -x /usr/bin/comskip ] || fail "/usr/bin/comskip is missing or not executable"
[ -d /recordings ] || fail "/recordings mount is missing"
[ -f "$INI" ] || fail "restore the original $INI before running this script"
[ -w "$INI" ] || fail "cannot write $INI"
[ -d /config/comskip ] || fail "/config/comskip is missing"

timestamp=$(date +%Y%m%d-%H%M%S)
cp -p "$INI" "$INI.bak-$timestamp"
echo "INI backup: $INI.bak-$timestamp"

# Preserve UID/GID and mode; ownership matters on DSM bind mounts.
owner=$(stat -c '%u:%g' "$INI")
mode=$(stat -c '%a' "$INI")

set_ini_value() {
    key=$1
    value=$2
    count=$(grep -Ec "^[[:space:]]*${key}[[:space:]]*=" "$INI" || true)
    [ "$count" -le 1 ] || fail "multiple active $key entries in $INI"
    if [ "$count" -eq 1 ]; then
        # Preserve explanatory comments and whitespace.
        sed -i "s/^\([[:space:]]*${key}[[:space:]]*=[[:space:]]*\)[0-9][0-9]*/\1${value}/" "$INI"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$INI"
    fi
}

# Values actually used on DS3RO after the 2026-11-07 correction.
set_ini_value verbose 0
set_ini_value delete_logo_file 1
set_ini_value output_vdr 1
set_ini_value output_edl 0

chown "$owner" "$INI"
chmod "$mode" "$INI"

tmp="$HOOK.new.$$"
trap 'rm -f "$tmp"' 0
cat > "$tmp" <<'POST_REMOVE'
#!/bin/sh
# Invoked by TVHeadend Post-remove command with "%f" as sole argument.
# Stop only the matching Comskip process, then delete its known sidecars.
set -u

recording=${1:-}

case "$recording" in
    /recordings/*.ts|/recordings/*.mkv|/recordings/*.mpg|/recordings/*.mp4|/recordings/*.m2ts) ;;
    *) echo "post-remove: invalid recording path" >&2; exit 2 ;;
esac

case "$recording" in
    *'/../'*|*'/./'*|*'//'*) echo "post-remove: unsafe path" >&2; exit 2 ;;
esac

# Never touch sidecars while the video still exists at its original path.
if [ -e "$recording" ]; then
    echo "post-remove: recording still exists" >&2
    exit 1
fi

comskip_matches() (
    proc="/proc/$1/cmdline"
    [ -r "$proc" ] || exit 1

    exe=$(tr '\000' '\n' < "$proc" 2>/dev/null | sed -n '1p')
    case "$exe" in
        /usr/bin/comskip|*/comskip) ;;
        *) exit 1 ;;
    esac

    # Relies on the configured single-input invocation:
    # /usr/bin/comskip --ini=/config/comskip/comskip.ini "%f"
    input=$(tr '\000' '\n' < "$proc" 2>/dev/null | tail -n 1)
    [ "$input" = "$recording" ]
)

# Never use killall, pkill -f or channel-name matches.
for proc in /proc/[0-9]*; do
    pid=${proc##*/}
    comskip_matches "$pid" || continue

    echo "post-remove: stopping Comskip PID $pid"
    if ! kill -TERM "$pid" 2>/dev/null; then
        comskip_matches "$pid" || continue
        echo "post-remove: cannot stop PID $pid" >&2
        exit 1
    fi

    count=0
    while comskip_matches "$pid"; do
        if [ "$count" -ge 20 ]; then
            echo "post-remove: Comskip PID $pid still running" >&2
            exit 1
        fi
        sleep 0.5
        count=$((count + 1))
    done
done

dir=${recording%/*}
base=${recording%.*}
shortbase=${base##*/}
shortvideo=${recording##*/}

# Comskip sidecars with the exact input basename only.
for suffix in .log .logo.txt .vdr .txt .edl; do
    rm -f -- "$base$suffix" "$dir/._$shortbase$suffix" || exit 1
done

# Finder/SMB AppleDouble metadata for this deleted video.
rm -f -- "$dir/._$shortvideo" || exit 1

# Only remove the folder if it is truly empty.
rmdir -- "$dir" 2>/dev/null || true
POST_REMOVE

chmod 755 "$tmp"
if [ -f "$HOOK" ] && cmp -s "$HOOK" "$tmp"; then
    rm -f "$tmp"
    echo "Post-remove script: already current"
else
    if [ -f "$HOOK" ]; then
        cp -p "$HOOK" "$HOOK.bak-$timestamp"
        echo "Script backup: $HOOK.bak-$timestamp"
    fi
    mv -f "$tmp" "$HOOK"
    echo "Installed: $HOOK"
fi

echo
echo "=== COMSKIP SETTINGS ==="
grep -E '^[[:space:]]*(verbose|delete_logo_file|output_vdr|output_edl)[[:space:]]*=' "$INI"
echo
echo "=== FILE PERMISSIONS ==="
ls -ln "$INI" "$HOOK"
echo
echo "=== TVHEADEND DVR PROFILE SETTINGS (MANUAL) ==="
echo 'Post-processor command: /usr/bin/comskip --ini=/config/comskip/comskip.ini "%f"'
echo 'Post-remove command: /config/comskip/post-remove.sh "%f"'
echo
echo "Next: save these two commands in every applicable TVHeadend DVR profile."
echo "Verify runtime access: docker exec -u abc tvheadend test -r /config/comskip/comskip.ini"
