# R Binaries Local Builder

Builds Bioconductor R package binaries on a single machine with Docker.

This is a stripped-down version of
[r-container-binaries-k8s-builder](https://github.com/Bioconductor/r-container-binaries-k8s-builder).
It builds packages the same way, but has no Kubernetes, GitHub Actions or
upload steps:

| k8s-builder | local-builder |
| --- | --- |
| GitHub Actions run the loop every 5 minutes | `bin/bioc-build run` loops on the server |
| State lives in a `build/*` git branch | State lives in a cycle directory |
| One Kubernetes Job per package | One Docker container per package |
| Scheduler limits concurrency by CPU requests | `MAX_JOBS` build slots |
| `backoffLimit`, `activeDeadlineSeconds` | `BUILD_ATTEMPTS`, `BUILD_TIMEOUT_SECONDS` |
| 500Gi NFS volume per cycle | A directory on local disk, bind-mounted at `/mnt` |
| Index, merge old binaries from GCS, `rclone` upload | Index only; binaries stay on disk |
| README status table, Slack notification | `bin/bioc-build status` |

## Requirements

- Linux with Docker (the user must be able to run `docker` without `sudo`,
  or set `DOCKER="sudo docker"`)
- `bash`, `python3` (standard library only), `flock`, GNU coreutils
- Internet access to pull the image and download package sources from CRAN
  and Bioconductor
- Disk space: k8s-builder allocates a 500 GiB volume per cycle for the
  shared library and tarballs, and the Bioconductor images are 5–8 GB each

## Quick start

```bash
export BIOC_BUILD_ROOT=/data/bioc-builds   # a large disk

# Smoke test: one package and its Bioconductor dependencies
bin/bioc-build start --only S4Vectors ghcr.io/bioconductor/bioconductor_docker:devel

# Full cycle; run it in tmux or screen (or see "Running unattended")
bin/bioc-build start ghcr.io/bioconductor/bioconductor_docker:RELEASE_3_22
```

`start` pulls the image, computes the dependency graph with `deps_json.R`,
then runs the build loop until every package has been built, has failed, or
is blocked by a failed dependency. It then writes the `PACKAGES` index.

The results are in `$BIOC_BUILD_ROOT/<cycle>/data/tarballs/`. That folder
is the `src/contrib` level of a repository, so give it to R as a
`contriburl`, inside a container from the same image:

```r
install.packages("S4Vectors", contriburl = "file:///data/bioc-builds/<cycle>/data/tarballs")
```

To serve it as a full repository (`repos = ...`), copy or link it to
`<repo>/src/contrib/`.

## Commands

```
bioc-build start [--only PKG,...] [--no-pull] [--no-run] IMAGE
bioc-build run CYCLE_DIR          # run or resume until finished, then index
bioc-build status CYCLE_DIR       # progress and running builds
bioc-build stop CYCLE_DIR         # stop the driver and remove running builds
bioc-build index CYCLE_DIR        # (re)write the PACKAGES index
bioc-build clean [--all] CYCLE_DIR
bioc-build list
```

- `--only` limits a cycle to the named packages plus their Bioconductor
  dependencies (useful for testing). The full graph is kept as
  `biocdeps.full.json`.
- `--no-pull` uses a local image as is.
- `stop` then `run` resumes a cycle. Builds that were interrupted are
  started again. The same happens after a reboot.
- `clean` deletes the shared library and staging files (the bulk of the disk
  use) but keeps tarballs and logs. `clean --all` deletes the cycle directory.
  The builds run as root inside the container, so their files are owned by
  root; `clean` deletes them from inside a container, so you don't need
  `sudo`.

## Settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `BIOC_BUILD_ROOT` | `~/bioc-builds` | Where cycle directories are created |
| `MAX_JOBS` | min(2/3 of CPUs, RAM GiB / 4) | Concurrent builds |
| `BUILD_TIMEOUT_SECONDS` | 3600 | A build running longer is killed (BBS `INSTALL` timeout) |
| `BUILD_ATTEMPTS` | 2 | Attempts per package before it is marked failed |
| `BUILD_MEMORY_LIMIT` | `16g` | `docker run --memory` for each build; a build that exceeds it is recorded as out of memory. Set to an empty string for no limit |
| `BUILD_CPU_LIMIT` | none | `docker run --cpus` for each build |
| `BUILD_NICE` | none | Run each build under `nice -n` (e.g. `19`) |
| `BUILD_CPU_SHARES` | none | `docker run --cpu-shares` for each build; `2` gives the lowest CPU weight |
| `POLL_SECONDS` | 30 | How often the driver checks builds |
| `DOCKER` | `docker` | Container CLI command |

To run builds at low priority, set both `BUILD_NICE=19` and
`BUILD_CPU_SHARES=2`. Under cgroup v2 every container is its own cgroup, and
niceness only orders processes within a cgroup; against other users'
processes, the kernel goes by the container's CPU weight, which
`--cpu-shares` sets. Containers sit under `system.slice`, which has the same
weight as `user.slice` by default, so when other users keep the machine busy
the builds can still get up to half of the CPU time. Lowering that further
needs root (for example, a low `CPUWeight` on a slice passed with
`--cgroup-parent`).

`MAX_JOBS` and the limits are read when `run` starts, so you can change them
by stopping the cycle and running it again.

## Cycle directory

```
<cycle>/
├── cycle.env                 # cycle ID, image, pinned image ID
├── biocdeps.json             # dependency graph (Bioconductor software only)
├── uniquedeps.json
├── bioc_version  r_version  container_name
├── ready_packages.txt        # ready to build on the last poll
├── remaining-packages.json   # unbuilt packages and their unbuilt deps
├── logs/
│   ├── dispatched-packages.txt
│   ├── successful-packages.txt
│   ├── failed-packages.txt
│   └── <Package>/
│       ├── build-success.log | build-fail.log
│       ├── attempt-<n>.log    # logs of earlier failed attempts
│       └── attempts
├── PACKAGES  indexed_packages_count  cycle_complete_time   # after index
│   (logs/index.log has the indexing output)
└── data/                     # mounted at /mnt in every container
    ├── .scripts/             # copy of pod/ taken when the cycle started
    ├── library/              # shared library of built packages
    ├── tarballs/             # the binaries and PACKAGES index
    └── .staging/
```

The image is pinned by ID when the cycle starts, so every build in a cycle
uses the same image even if its tag is updated during the cycle.

## How a build is judged

A package succeeds when its container exits 0 and its log shows that the
binary tarball was produced (`packaged installation of '<pkg>' as
<pkg>_<version>_....tar.gz`). Otherwise it is retried until
`BUILD_ATTEMPTS` is reached and then recorded in `failed-packages.txt`. The
first line of `build-fail.log` gives the reason (exit code, out of memory,
timeout, or no tarball). Packages that depend on a failed package are never
started and are reported as blocked.

Packages are published to the shared library by an atomic rename (see ADR
0001 in r-container-binaries-k8s-builder), so builds running at the same time
never see a partly written package.

## Running unattended

`bin/bioc-tmux` runs `start` or `run` in a detached tmux session, so the
cycle keeps going after you log out, and also appends the output to
`$BIOC_BUILD_ROOT/tmux-logs/<session>-<time>.log`:

```bash
ssh -t supermicro
cd ~/r-container-binaries-local-builder
bin/bioc-tmux start ghcr.io/bioconductor/bioconductor_docker:devel
# detach with Ctrl-b d; reattach later with:
tmux attach -t bioc-bioconductor-docker-devel
```

- The session is named after the image (`start`) or the cycle directory
  (`run`); use `--session NAME` to choose another. If that session already
  exists, nothing is started.
- `--detach` starts the session without attaching to it.
- Settings such as `MAX_JOBS` or `BUILD_MEMORY_LIMIT` are taken from your
  current shell, even if a tmux server is already running.
- When `bioc-build` finishes, the window shows its exit status and waits for
  Enter before closing.
- After a reboot, resume with `bin/bioc-tmux run ~/bioc-builds/<cycle>`.

Alternatively, run it as a transient systemd user service, with its output
in the journal. Transient units don't survive a reboot either, so resume
with `run` after one:

```bash
systemd-run --user --unit=bioc-build-devel \
  -E BIOC_BUILD_ROOT=/data/bioc-builds \
  ~/r-container-binaries-local-builder/bin/bioc-build run /data/bioc-builds/<cycle>
journalctl --user -fu bioc-build-devel
```

For the service to keep running after you log out, enable lingering once
with `loginctl enable-linger`.

## Layout

```
bin/bioc-build             # the driver (all commands)
bin/bioc-tmux              # runs start/run in a detached tmux session
lib/find_ready_pkgs.py     # picks packages whose deps are built (unchanged from k8s-builder)
lib/cycle_status.py        # progress and completion check
pod/deps_json.R            # dependency graph (unchanged from k8s-builder)
pod/build_pkg.sh           # runs in each build container
pod/index.sh               # writes PACKAGES
```
