better-gather (release-4.18)
============================

A fork of [openshift/must-gather](https://github.com/openshift/must-gather) in
which `--since` actually bounds what is collected, branched for OpenShift
4.18.

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

Upstream's README follows below, unchanged.

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

## Obfuscate confidential information
There is a dedicated effort to obfuscate and omit confidential information. Head over to [openshift/must-gather-clean](https://github.com/openshift/must-gather-clean) for more information.
