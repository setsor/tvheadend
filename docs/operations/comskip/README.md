# Restore TVHeadend + Comskip after a fresh DSM installation

**Purpose:** apply the same Comskip settings and recording-removal integration that were configured on DS3RO on **7 November 2026**, without patching or rebuilding TVHeadend. This is an operational **configuration patch/runbook**, not an upstream TVHeadend source patch.

- TVHeadend: 4.3-2891 (tested environment).
- Comskip: 0.83.001, Donator build with FFmpeg, at /usr/bin/comskip.
- Docker container: tvheadend.
- TVHeadend configuration: /config (persistent).
- Comskip INI: /config/comskip/comskip.ini.
- Recording path **inside** container: /recordings.
- Runtime recording/process user: abc (do not assume its numerical UID/GID).
- Original report and withdrawn core PR: https://github.com/tvheadend/tvheadend/pull/2381

**Scope:** restore.sh sets four specific INI keys and installs /config/comskip/post-remove.sh. It does **not** install Comskip, invent a new full comskip.ini, change the container image or volume mounts, edit DVR profiles through the API, modify running recordings, or terminate running jobs at installation time.

## 0. Preserve the prerequisites before reinstalling

The configuration patch alone cannot reproduce a container image or Comskip's full custom detection configuration. Before deleting the old installation, record the image and mounts, and copy the existing INI to a safe location **outside the container**.

Run on the DSM host as root (after sudo -i):

~~~sh
docker inspect tvheadend --format 'Image: {{.Config.Image}}'
docker inspect tvheadend --format '{{range .Mounts}}{{println .Source " -> " .Destination}}{{end}}'
docker exec tvheadend /usr/bin/comskip --help | head -n 5
docker exec tvheadend id abc
docker exec tvheadend ls -ldn /config /config/comskip /recordings
docker cp tvheadend:/config/comskip/comskip.ini ./comskip.ini.ds3ro.backup
~~~

Store the INI backup and the image/mount information somewhere persistent. Do not post private Docker environment variables or full docker inspect JSON publicly. If a replacement image does not include the same Comskip build, arrange that separately before applying this configuration.

The /config/comskip folder must be persistent; /recordings must refer to the recording storage. Verify ownership and read/write permissions after any image migration or volume remapping.

## 1. Apply the configuration patch

First start the replacement TVHeadend container, restore the full existing comskip.ini to /config/comskip/comskip.ini, and check that /usr/bin/comskip and /recordings exist.

Download the exact script snapshot (pin it rather than executing a mutable branch tip):

~~~sh
curl -fL --output /tmp/tvh-comskip-restore.sh \
  https://raw.githubusercontent.com/setsor/tvheadend/1a1c3f952b025c1a7c38c0a39f74360c9c67f016/docs/operations/comskip/restore.sh

# Inspect before executing.
sed -n '1,240p' /tmp/tvh-comskip-restore.sh

# Runs inside the existing TVHeadend container, as root.
docker exec -i -u 0 tvheadend sh -s < /tmp/tvh-comskip-restore.sh
~~~

The script backs up the INI (and any different pre-existing hook), retains the INI's numerical UID/GID and mode, and applies exactly these values:

~~~ini
verbose=0
delete_logo_file=1
output_vdr=1
output_edl=0
~~~

It does not replace other recording-detection settings. In particular it does not assume a value for output_default, which was not part of the verified adjustment.

The installed executable is /config/comskip/post-remove.sh, mode 755. It must remain readable/executable by the user under which TVHeadend invokes hooks (abc in this deployment).

The installer is repeatable: it restores the same effective settings on each run; it makes a timestamped backup of comskip.ini, and only replaces the hook if its content changed.

## 2. Restore the DVR profile hooks in TVHeadend

Open **Configuration → Recording → Digital Video Recorder Profiles**, select each DVR profile actually used for recordings (the profile named jellyfin was observed in this deployment), and enable the **Expert** UI level if Post-remove is not visible.

Set these two fields **exactly**:

**Post-processor command**

~~~text
/usr/bin/comskip --ini=/config/comskip/comskip.ini "%f"
~~~

**Post-remove command**

~~~text
/config/comskip/post-remove.sh "%f"
~~~

Save the profile. TVHeadend substitutes %f with the original recording path and executes the command as a process, not through an implicit shell. Do not omit the quotes around "%f"; recording titles contain spaces, apostrophes and other punctuation.

The profile's storage path must resolve to /recordings within the container. Apply the same hooks to other DVR profiles only if those profiles should also run Comskip. No TVHeadend restart or source compilation is necessary for these changes.

**Independent performance note:** for a separately observed DVR writeback/API-stall issue, setting the affected DVR profile's cache scheme to **System** correlated with faster Stop Recording responses compared with Don't keep. This is not a Comskip setting and was not changed by restore.sh.

## 3. Validate access and settings

On the DSM host:

~~~sh
docker exec tvheadend sh -c '
grep -E "^[[:space:]]*(verbose|delete_logo_file|output_vdr|output_edl)[[:space:]]*=" /config/comskip/comskip.ini
ls -ln /config/comskip/comskip.ini /config/comskip/post-remove.sh
'

docker exec -u abc tvheadend sh -c '
test -x /usr/bin/comskip &&
test -r /config/comskip/comskip.ini &&
test -x /config/comskip/post-remove.sh &&
test -w /recordings &&
echo "Runtime user abc: access OK"
'
~~~

Read access to the INI and executable access to the cleanup hook are necessary; the service must be able to create/remove its own recording files and sidecars. Do not recursively chown the entire recording collection without first inspecting the actual PUID/PGID.

### Safe smoke test: no real recording is touched

The following creates only a uniquely named dummy directory and fake sidecars, invokes Post-remove for a **nonexistent** fake transport stream, and checks cleanup:

~~~sh
docker exec -u abc tvheadend sh -ec '
d="/recordings/.comskip-postremove-smoke-$$"
mkdir "$d"
video="$d/smoke.ts"
printf "test\n" > "$d/smoke.log"
printf "test\n" > "$d/smoke.vdr"
printf "test\n" > "$d/._smoke.ts"
/config/comskip/post-remove.sh "$video"
if [ -e "$d" ]; then
  echo "FAIL: test directory remains: $d"
  ls -la "$d"
  exit 1
fi
echo "PASS: exact-name sidecars and empty directory removed"
'
~~~

This tests file cleanup, NOT signal handling of a live Comskip process. For full validation, record a short programme, allow Comskip to finish, then delete the DVR entry **with file removal**. Repeat with another short recording deleted while Comskip is still processing, checking that the matching process exits, sidecars disappear, and unrelated jobs survive. These live concurrent tests were not yet confirmed in the documented session.

## 4. How Post-remove behaves

The script is intentionally narrow:

1. Accepts an absolute path under /recordings ending in .ts, .mkv, .mpg, .mp4 or .m2ts.
2. Refuses cleanup if the video still exists at that original filename.
3. Looks through /proc and matches a Comskip process by the precise executable name and its **last argument**, which must be exactly the input filename specified by %f.
4. Sends SIGTERM only to that matching process; waits for up to about 10 seconds. If it remains running, exits with an error and **does not delete its sidecars**. No killall and no unconditional SIGKILL.
5. Removes only the same-basename .log, .logo.txt, .vdr, .txt and .edl, their corresponding AppleDouble ._ forms, and ._video.ts metadata.
6. Attempts rmdir, which succeeds only for an empty directory.

An AppleDouble file of the form ._recording.ts is created by macOS/SMB metadata handling and is not a Comskip detection result.

Assumptions/limits: the Comskip command must remain a single-file invocation with the filename as its last argument. The script is shell-level process matching, not the kernel generation-safe process tracking proposed in PR #2381; there is a narrow PID-reuse race. Its waiting time is finite. It does not remove arbitrary unknown outputs or retry failed cleanup after a restart. Deferred .removing file deletion can delay final directory removal. File names containing newlines are unsupported by the /proc text conversion.

## 5. What was actually observed

- Before remediation, a Comskip job launched for a now-deleted recording remained active, consuming almost one CPU core; its .log file was still being updated.
- Initial INI values were verbose=10, delete_logo_file=0, output_vdr=1 and output_edl=0.
- The first two values were changed to verbose=0 and delete_logo_file=1.
- A running Comskip instance had already loaded the old INI; editing the file does not retroactively change an existing process.
- PID 1207 was manually verified against the exact deleted video pathname and stopped with SIGTERM.
- /config/comskip/post-remove.sh was installed and executed manually for that deleted recording. The user confirmed the expected cleanup of the remaining files/directory.
- The **automatic** Post-remove path for deletion while Comskip runs has not been independently end-to-end validated in this log.

## 6. Lessons learned

- Check the application's already-supported lifecycle hooks before proposing an invasive server-core patch. TVHeadend already exposes Post-processor and Post-remove for this scenario.
- Separate **Comskip's own output policy** (verbose, output_vdr, delete_logo_file) from **lifecycle cleanup** (stop matching analysis on DVR removal) and from unrelated DVR cache issues.
- Deleting a video's pathname does not terminate a process that has an open file descriptor. Cleaning sidecars before stopping that process can produce new orphan files.
- Scope process termination and deletion to the exact recording; never match only a channel name or remove an entire directory recursively.
- Preserve persistent /config data, the complete original INI, image provenance and container UID/GID. A setting patch alone is not a full backup or reinstall recipe.
- Document precisely what was verified. A working manual cleanup is not proof that every simultaneous-delete race is solved.

This integration makes PR #2381 unnecessary **for the local deployment**; it does not claim that upstream process lifecycle management could never be improved.
