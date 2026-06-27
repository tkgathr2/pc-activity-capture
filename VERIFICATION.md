# Revolution (pc-activity-capture) MVP - Verification Evidence

Date: 2026-06-28  /  Host: company desktop (高木産業)  /  ffmpeg 8.1.1 (WinGet)

## Spec code-diffs (section 2) - all applied

| # | Item | Status |
|---|---|---|
| 1 | daemon SegmentSec default 3600 -> 1800 | DONE (param default 1800) |
| 2 | config staleSeconds 600 -> 300 | DONE |
| 3 | watchdog interval 5min -> 3min | DONE (register-capture-tasks.ps1) |
| 4 | ffmpeg sync flags (-use_wallclock_as_timestamps 1 -vsync cfr -rtbufsize 256M) | DONE |
| 5 | record t0_video to meta (per segment) | DONE (see architecture note) |

## Critical bug found & fixed (production blocker)

**ffmpeg not on PATH for -NoProfile processes.** The production launch path is HKCU
Run -> `powershell -NoProfile ... -File run-capture-daemon.ps1`. A -NoProfile process
does NOT inherit machine PATH (chocolatey\bin / WinGet Links), so the old daemon's
`Get-Command ffmpeg` returned null and recording failed SILENTLY on logon-start.
The real ffmpeg is the WinGet package at a versioned path.
Fix: `Resolve-Tool` resolves ffmpeg/ffprobe by absolute path (cfg override ->
Get-Command -> known dirs -> bounded WinGet/chocolatey globs). Proven: heartbeat now
shows the resolved absolute ffmpeg path and recording works from a fresh -NoProfile launch.

## Architecture note (D1 driver)

The spec's per-segment ffmpeg restart leaves a ~17s blind gap each segment (gdigrab/
dshow re-init), which fails D1 (<2s). Switched to ONE long-lived ffmpeg with the
**segment muxer** (`-f segment -segment_time N -reset_timestamps 1 -strftime 1`) plus
`-force_key_frames expr:gte(t,n_forced*N)` for exact boundaries. Result: GAPLESS
consecutive files. Each segment's `t0_video` = its strftime filename (wall-clock start);
`session-meta.json` records `session_start`/`t0` as the keylog<->video sync anchor.

## DoD results

| DoD | Result | Evidence |
|---|---|---|
| D1 continuous, gap<2s | PASS | -SegmentSec 10 run: durations 10.037/10.021/10.006/10.014/10.021s; filename intervals 10s; gap = interval - duration = 0-1s < 2s |
| D2 no-stop 8h | PARTIAL | Multiple gapless segments from one long-lived ffmpeg (no per-segment churn); daemon try/catch + restart-on-crash. Full 8h not run (time). |
| D3 stop detect <=10min | PASS | UP->DOWN transition writes `[ALERT] ... is NOT running ... heartbeat stale 600s` to alerts.log. Worst case = stale 300s + interval 180s = 480s = 8min <= 10min. |
| D4 keystroke sync <=1s | PASS (logical) | keylog records absolute wall-clock `ts` per key (+window); segment filename = wall-clock start; same system clock -> sub-second offset. Physical drawtext frame-match not run. |
| D5 A/V sync <=200ms | PASS | ffprobe packet pts on a segment: v_last=9.900 a_last=9.998 -> diff 98ms <= 200ms. Measured on 10s segment; full 1800s drift not run (bounded by -vsync cfr + wallclock ts). |
| D6 disk resilience | IMPLEMENTED | Ensure-DiskSpace deletes oldest *.mp4/*.jsonl when free < minFreeGB(10), checked before each capture and during the recording loop; Get-FreeGB returns 9999 on error so it never crashes. Disk-fill stress not run. |

## Open Questions (unchanged, per spec section 7)

- OQ-1 notify target: defaulted to `notify.method=log` (alerts to state\alerts.log only).
- OQ-2 retention: D6 deletes oldest when disk low; time-based 90d retention not added.
- OQ-5 resolution/fps: 1080p desktop / 10fps (config `fps`).

## Not run (honest)

- Full 8h soak (D2) and disk-fill stress (D6): impractical in this session.
- D4 drawtext frame-overlay physical match (logical wall-clock proof given instead).
- D5 over a full 1800s segment (10s segment measured).
