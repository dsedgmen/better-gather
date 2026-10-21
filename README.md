better-gather
=============

A fork of [openshift/must-gather](https://github.com/openshift/must-gather) in
which `--since` actually bounds what is collected.

> ### ⚠️ Not a Red Hat product
>
> This is a personal, unofficial fork. It is **not built, reviewed, supported
> or endorsed by Red Hat**, and it is provided **without warranty or support
> of any kind** — use it, and anything it collects, at your own risk. See
> [`LICENSE`](LICENSE) and [`DISCLAIMER`](DISCLAIMER), a copy of which ships
> in the image and is written into every collection it produces.
>
> Because `--since` really does bound collection here, an archive from this
> tool may hold less than a stock must-gather would. If you attach one to a
> Red Hat support case, say that it came from an unofficial tool; support may
> ask for a collection from the supported must-gather image instead.

Upstream's README follows below, unchanged, from
[`openshift/must-gather`](https://github.com/openshift/must-gather).

## Why this fork exists

`oc adm must-gather --since 30m` does not bound most of a collection. It
reaches exactly two things:

| Route | Effect |
| ----- | ------ |
| `oc adm inspect --since` | trims pod logs |
| `oc adm node-logs --since` on a **journal** query | trims host service logs |

Everything else is collected whole, no matter what window you ask for. That is
not a scripting mistake. `gather_audit_logs` forwards `--since` on both of its
`oc adm node-logs` calls and documents the fifth `xargs` argument as an ISO
since — the intent was always there. The layers underneath simply drop it:

1. **`oc` does not send it.** `oc adm node-logs` attaches the `since`
   parameter only when the path is `journal`
   ([`pkg/cli/admin/node/logs.go`](https://github.com/openshift/oc/blob/master/pkg/cli/admin/node/logs.go)).
   The flag's own help says *"Only applies to node service logs."*
2. **The kubelet would not apply it anyway.** Asked directly it *validates*
   the parameter — an RFC3339 `Z` value is rejected with a format error, which
   is what makes this look like it should work — but does not time-filter
   plain file serving.

Measured on a 4.18.54 cluster, against a file rotated 11 hours earlier:

```console
$ oc adm node-logs --role=master --path=kube-apiserver              # md5 e858399c2ce24757
$ oc adm node-logs --since=-5m --role=master --path=kube-apiserver  # md5 e858399c2ce24757
$ oc adm node-logs --since=-30m ... ; --since='2026-10-16 06:00:00' # md5 e858399c2ce24757

$ oc get --raw ".../logs/kube-apiserver/audit-2026-10-15T19-30-44.933.log"
134269 lines, first event 2026-10-15T18:26:39Z
$ ... "?since=-5m"  /  "?since=-1h"  /  "?since=2026-10-16 06:00:00"
134269 lines, same first event, every time
```

So the collection scripts have to apply the window themselves. That is what
this fork does.

## What changed

Two shapes of collection needed two different fixes, in
`collection-scripts/since_common.sh`:

**Name-based.** Collection that produces a listing whose entries carry a
timestamp — `audit-2026-10-16T00-15-40.612.log`,
`insights-2026-10-16-181710.tar.gz`. `filter_names_since` drops entries that
end before the cutoff. Entries with no recognisable timestamp always pass
through, which is load-bearing: it keeps the live `audit.log`,
`termination.log`, `.lock` and `.terminating`, the files most likely to hold
recent events.

**Mtime-based.** Collection that tars or copies a whole directory and has no
notion of time at all. `gather_network_logs` runs
`find /var/log/ovnkube -type f -name "libovsdb*log*" | tar czf - -T -`; adding
`$(since_find_predicate)` to that `find` is the entire fix.
`copy_pod_dir_since` does the same for the scripts that `oc cp` a directory,
which cannot express a bound — so out-of-window files never cross the wire.

On top of that, `trim_jsonl_since` makes the audit window *exact* rather than
merely file-granular, by trimming the one rotated file that straddles the
cutoff. It is deliberately tolerant: non-JSON lines pass through verbatim
(`/var/log/etcd` is plain text), as do JSON objects without the timestamp
field. It cannot silently empty a file it did not understand.

| Script | Before | After |
| --- | --- | --- |
| `gather_audit_logs` | every rotated file, whole | files in window, events trimmed to the cutoff |
| `gather_kas_startup_termination_logs` | every rotated file | files in window |
| `gather_insights` | every archive | archives in window (its own TODO) |
| `gather_network_logs` | all `libovsdb*log*` | those modified in window |
| `gather_core_dumps` | the whole coredump directory | dumps in window |
| `gather_machineconfigdaemon_termination_logs` | all previous-logs | those in window |
| `gather_windows_node_logs` | fixed filenames | unchanged; nothing to select between |

Also fixed: `get_log_collection_args` collapsed a Go duration for `node-logs`
by keeping only its first component, so `2h30m` became `-2h` and silently
dropped the oldest 30 minutes — and `500ms` became `-500m`, a 500× overshoot.
Durations are now re-expressed exactly (`2h30m0s` → `-150m`).

**Nothing changes without a window.** Every helper is a no-op when neither
`MUST_GATHER_SINCE` nor `MUST_GATHER_SINCE_TIME` is set, so an unbounded
`oc adm must-gather` behaves exactly as upstream does.

## Measured result

The case that prompted the fork — `--since 30m`, run at 23:04, cutoff
22:34:06, three masters:

```
audit_logs/kube-apiserver       kept=8   skipped=28
audit_logs/openshift-apiserver  kept=3   skipped=30
audit_logs/oauth-apiserver      kept=3   skipped=12
audit_logs/oauth-server         kept=3   skipped=0
```

70 files down to 17, and in every collected file the oldest event is
`22:34:07` — one second after the cutoff, with zero events before it,
including in the rotated file that straddled it.

Every run writes `/must-gather/since-report.txt` accounting for what the
window did, so this is auditable rather than mysterious:

```
# better-gather --since report
# window: everything at or after 2026-10-16T22:34:06Z (epoch 1792190046)
# requested as: MUST_GATHER_SINCE='30m0s' MUST_GATHER_SINCE_TIME=''
# when	what	mechanism	kept	skipped
2026-10-16T23:04:08Z	audit_logs/kube-apiserver	filename-timestamp	kept=8	skipped=28
2026-10-16T23:04:34Z	audit_logs/monitoring/metrics-server-...	find-newermt	kept=1	skipped=0
```

## Testing a change against a cluster

`hack/try-on-cluster.sh` carries the working tree into a stock must-gather pod
and runs it from `/tmp/better-gather`, with no image build or push. Because
every collection script sources `$(dirname "$0")/common.sh`, the modified
library is picked up automatically.

```console
$ hack/try-on-cluster.sh gather_audit_logs --since 30m -- --force
$ hack/try-on-cluster.sh --dry-run gather_network_logs --since 1h
```

For a real image, overlay the scripts onto the must-gather image the cluster
already runs, so the base is version-matched and pullable without CI
credentials:

```console
$ make image-overlay BASE=$(oc adm release info --image-for=must-gather)
```

## Tests

```console
$ make test     # 87 bats tests, bootstraps its own tooling
$ make lint     # shellcheck
```

Both run offline. Upstream's `hack/tools.sh` downloads bats, shfmt and
shellcheck from GitHub releases; `hack/tools-from-packages.sh` gets them from
the distribution instead, unpacked under `tmp/` with no root and nothing
installed system-wide, and the Makefile prefers it. `bats-support` and
`bats-assert` are not packaged anywhere, so `tests/bats_assert_fallback.bash`
provides local equivalents of the four assertions the suite uses; the real
libraries are still used when present.

## Images

This image adds **only shell scripts** -- no packages, no binaries -- so
every vulnerability it reports comes from whatever it is layered on. That
makes the choice of base the whole of its security posture, and
`Dockerfile.overlay` deliberately has no default: a build without `BASE`
fails rather than silently picking something stale.

### The best base is the one your cluster already runs

It carries exactly the CVEs you have already accepted, and its tooling
matches your release:

```console
$ make image-overlay BASE=$(oc adm release info --image-for=must-gather)
```

Or build it inside the cluster, which needs no registry credentials at all:

```console
$ oc new-project better-gather-build
$ oc new-build --name mg --binary --strategy=docker
$ oc start-build mg --from-dir=. --follow
```

A scan of that image is identical to a scan of the must-gather you are
already running. No prebuilt image can do better.

### The published images

For when you do not have the cluster to hand, CI publishes images built on a
base this repo produces from `registry.access.redhat.com/ubi9/ubi-minimal`,
which Red Hat rebuilds continuously and which needs no pull credentials:

```console
$ make image-base                                  # the UBI9 base
$ make image-overlay BASE=better-gather-base:latest
```

These used to be layered onto `quay.io/openshift/origin-must-gather:latest`.
There is no fresh public must-gather image to use -- `latest` is the newest
tag any of them publishes, and at the time of writing:

| base | last rebuilt |
| ---- | ------------ |
| `quay.io/openshift/origin-must-gather:latest` | 2026-02-13 |
| `quay.io/kubevirt/must-gather:latest` | 2026-07-06 |
| `quay.io/ocs-dev/ocs-must-gather:latest` | 2025-07-02 |
| `registry.access.redhat.com/ubi9/ubi-minimal:latest` | rebuilt continuously |

`hack/check-base.sh` reports how old a base is and fails past 60 days, and
CI runs it before publishing, so this cannot quietly rot again. Every image
carries `better-gather.base` and `better-gather.base-built` labels recording
what it was built on.

The UBI9 base is smaller too -- 296 MB against 495 MB -- because it carries
only what the collection scripts use: `oc`, `jq`, `rsync`, `tar`, `gzip`,
`findutils`, `util-linux`, `procps-ng` and the usual text tools.

### Tags

| ref | tags |
| --- | --- |
| `main` | `:latest`, `:main-<sha>` |
| `release-4.18` | `:4.18`, `:release-4.18` |
| any other branch | `:branch-<name>` |
| `v1.2.3` | `:v1.2.3`, `:latest` |

A release branch deliberately does not move `:latest`.

**The packages are private**, inheriting the repository's visibility, so a
cluster needs a pull secret -- or use the in-cluster build above, which
avoids the question entirely.

## Release branches

`release-4.18` through `release-4.23`, each branched from upstream's own
release branch and the --since work re-applied on top — not cherry-picked, since
4.18 is 93 commits and 41 collection scripts behind main. `hack/backport.sh`
regenerates them and reports every edit that did not apply, so a branch where
upstream has moved fails loudly rather than quietly collecting everything.

Each branch runs the same bats suite: 94 tests on 4.23, 82 on 4.22, and 37 on
4.21 and older, which predate upstream's own suite and so test only this fork's
code. Upstream's `common.bats` is deliberately *not* copied onto those
branches: it asserts REDUCE_LOGS and rotated-pod-log behaviour that the
4.18-era `common.sh` does not have.

## Staying current with upstream

```console
$ git fetch upstream && git rebase upstream/main
```

The changes are deliberately small and separable, each in its own commit, so
they stay rebasable — and so the ones that are genuinely upstream bugs (the
duration truncation, the shellcheck failures) could be sent as PRs.

---

must-gather
===========

`openshift-must-gather` is a tool for collecting cluster data.
It dumps `clusteroperator` data, and associated namespace data, into a specified `--base-dir` location.
The directory structure, as well as specific details behind this tool can be found [in this enhancement](https://github.com/openshift/enhancements/blob/master/enhancements/oc/must-gather.md).

## Collection Scripts
Data collection scripts are kept in `./collection-scripts`.  The content of that folder is placed in `/usr/bin` in the image.
The data collection scripts should only include collection logic for components that are included as part of the OpenShift
CVO payload.  Outside components are encouraged to produce a similar "must-gather" image, but this is not the spot to be
included.

## How to run
You can run `must-gather` on a cluster with `oc adm must-gather`. 
Use `-h` flag to see available options.

## How to test
Build a new must-gather image with your changes using the Makefile. There are two options in the Makefile, `make` will use imagebuilder to build the image while `make BUILDER=podman` will use podman to build the image.

If using `make BUILDER=podman`, please set the `AUTH_FILE` parameter pointing to an authentication file that has credentials for the `registry.ci.openshift.org` registry. Ensure that you are connected to the VPN before building the image.
```
make BUILDER=podman AUTH_FILE=/path/to/authfile
```

Once the image is built, push it to a registry where it can be accessed from. 
```
podman push [built-image] [registry/username/your-built-image]
``` 

To test your new changes with a cluster, run the following:
```
oc adm must-gather --image=registry/username/your-built-image
```

## Obfuscate confidential information
There is a dedicated effort to obfuscate and omit confidential information. Head over to [openshift/must-gather-clean](https://github.com/openshift/must-gather-clean) for more information.
