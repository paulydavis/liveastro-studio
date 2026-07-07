# [Bug report draft — for gitlab.com/free-astro/siril/-/issues]

## Title
Live stacking rejects every file with "File not supported for live stacking" when process CWD differs from the working directory (stat by relative basename)

## Environment
- Siril 1.4.4 (macOS, arm64, aarch64 build)
- macOS 26.4, Apple Silicon
- Live stacking a folder of FITS subs (16-bit ushort, BAYERPAT GRBG, `.fit` extension) written by a relay script from a ZWO Seestar S30 Pro

## Summary
After restarting Siril, live stacking rejected **every** incoming FITS file with:

```
File not supported for live stacking: Light_NGC 7000_20.0s_LP_20260706-225633.fit
```

The same files had been accepted and stacked normally in the previous Siril session. Nothing about the files, folder, or delivery changed — only Siril was restarted. The message is misleading: the files are perfectly ordinary FITS; they are rejected because a `stat` on a **relative path** fails.

## Root cause (from source inspection, `src/livestacking/livestacking.c`, master and 1.4 branches)

`file_changed()` receives the monitor event and extracts **only the basename**:

```c
gchar *filename = g_file_get_basename(file);
...
image_type type;
if (stat_file(filename, &type, NULL)) {
    siril_debug_print("Filename is not canonical\n");
}
if (type != TYPEFITS) {
    ...
    siril_log_message(_("File not supported for live stacking: %s\n"), filename);
```

`stat_file()` initializes `*type = TYPEUNDEF`, then:

```c
const char *extension = get_filename_ext(filename);
if (extension) {
    if (!is_readable_file(filename)) return 1;   // <-- relative path!
    *type = get_type_for_extension(extension);
```

`is_readable_file()` calls `g_lstat(filename, ...)` with the bare basename — a
**relative path resolved against the process CWD**, not against the directory
being monitored (`com.wd`). When the process CWD differs from `com.wd`,
`g_lstat` fails with ENOENT, `stat_file` returns early, `*type` remains
`TYPEUNDEF`, and the file is reported as "not supported".

## Why a restart triggers it
On startup Siril restores `com.wd` from preferences (the header bar shows the
correct working directory, and the GFileMonitor is aimed at the correct
folder), but the **process** CWD is not necessarily chdir'ed to match —
`g_chdir` only happens inside `siril_change_dir()`, i.e. when the user
navigates via the file browser or runs `cd` in the console. A Siril launched
from Finder starts with process CWD `/` (or the bundle dir); live stacking
then monitors the right folder while stat'ing basenames against the wrong one.

Verified on our machine: `lsof -p <siril pid> | grep cwd` showed a CWD
different from the header-bar working directory in the failing session; a
session where the folder had been selected via the file browser (process CWD
matching) accepted the same files.

## Steps to reproduce
1. In Siril, set the working directory to a folder F via the file browser; start live stacking; drop a FITS sub into F → accepted. Quit Siril.
2. Relaunch Siril from Finder (do **not** navigate anywhere — the header bar already shows F restored from preferences).
3. Start live stacking; drop the same FITS file into F.
4. Console prints `File not supported for live stacking: <name>.fit`.

## Expected
The file is stacked, or at minimum the error message identifies the real
failure (file not found at the stat'ed path) instead of "not supported".

## Suggested fix
In `file_changed()` / `stat_file()`, resolve the file relative to the
monitored directory rather than the process CWD, e.g.:

```c
gchar *fullpath = g_build_filename(com.wd, filename, NULL);
```

and stat `fullpath` (or use `g_file_get_path(file)` directly from the
GFileMonitor callback, which already carries the full path). Alternatively,
have live stacking start (or `com.wd` restoration at startup) perform the
same `g_chdir` that `siril_change_dir()` does.

A secondary papercut: when `stat_file` fails, the "not supported" message is
emitted for what is actually a stat failure — distinguishing the two would
have made this diagnosable from the console.

## Workaround (for anyone else hitting this)
Before starting live stacking, run `cd /full/path/to/folder` in Siril's
command line (or click into the folder via the file browser) so the process
CWD matches the working directory.
