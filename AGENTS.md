# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this repo is

Machine configuration for `worclustershire`, a 3-node Talos Linux Kubernetes homelab cluster running as
VMs (Proxmox, and virt-manager/QEMU). There is no application code, no build, and no test suite — every
file is either a Talos config patch (plaintext YAML) or a rendered Talos config (SOPS-encrypted YAML).
`README.md` is the operational runbook and is the authoritative source for the full bootstrap sequence.

## Cluster facts

| | |
|---|---|
| Nodes | `worclustershire1` 192.168.8.4, `worclustershire2` 192.168.8.5, `worclustershire3` 192.168.8.6 |
| VIP | 192.168.8.7 / `2603:8001:5800:8cf::7`; gateway 192.168.8.1 |
| Endpoint | `https://worclustershire.6j0.org:6443` (A record points at all three node IPs) |
| Topology | All three nodes are control planes that also run workloads (`allowSchedulingOnControlPlanes`) |
| Networking | Static only — DHCP will break cluster membership when an IP changes |
| Storage | Longhorn (needs iSCSI + hugepages + bind mount, see `longhorn-patch.yaml`), MetalLB for LoadBalancers |
| Kubeconfig | `~/.kube/worclustershire`, merged into `~/.kube/config` |

## Config layering

Node configs are *rendered artifacts*, produced by stacking patches onto a base. Each step reads a config,
applies one patch, and writes the config back out:

```
talosctl gen secrets -o secrets.yaml
talosctl gen config --with-secrets secrets.yaml worclustershire https://192.168.8.7:6443 \
  --install-image=factory.talos.dev/nocloud-installer-secureboot/88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b:v1.11.5 \
  --install-disk=/dev/sda --config-patch @tpm-disk-encryption.yaml
# → controlplane.yaml, worker.yaml, talosconfig

talosctl machineconfig patch controlplane.yaml --patch @<patch> --output controlplane.yaml
#   applied in this order: controlplane-patch-allowSchedulingOnControlPlanes.yaml,
#   controlplane-patch-metallb.yaml, controlplane-patch-vip.yaml, metrics-server.yaml

talosctl machineconfig patch controlplane.yaml --patch @controlplane-patch-worclustershireN.yaml \
  --output worclustershireN.yaml            # per-node hostname + static IP
talosctl machineconfig patch worclustershireN.yaml --patch @longhorn-patch.yaml \
  --output worclustershireN.yaml            # Longhorn prerequisites
```

Patch files, and what each exists for:

- `tpm-disk-encryption.yaml` — LUKS2 with TPM keys for `ephemeral` and `state`; passed at `gen config` time, so it is baked into every derived config.
- `controlplane-patch-allowSchedulingOnControlPlanes.yaml` — workers on control planes.
- `controlplane-patch-metallb.yaml` — deletes the `node.kubernetes.io/exclude-from-external-load-balancers` label; without this MetalLB will not use control-plane nodes.
- `controlplane-patch-vip.yaml` — shared VIP (v4 + v6) on the selected interface.
- `metrics-server.yaml` — enables kubelet serving-cert rotation and adds two `extraManifests` (kubelet-serving-cert-approver pinned by commit SHA, metrics-server pinned by release tag).
- `controlplane-patch-worclustershire{1,2,3}.yaml` — the only per-node deltas: hostname and static address.
- `longhorn-patch.yaml` — `/var/lib/longhorn` rshared bind mount, 1024 hugepages, `nvme_tcp` + `vfio_pci`.

Interfaces are selected by `deviceSelector.busPath: "0*"` rather than by name, so the patches work on any
single-NIC node.

**When changing cluster-wide behavior, edit the patch — not the rendered node config.** The rendered
`worclustershireN.sops.yaml` files are the thing that actually ships, so a change only reaches the nodes
after the layering above is re-run (or the equivalent edit is made in the rendered file). Anything applied
only to a rendered file is lost the next time configs are regenerated.

## SOPS

Everything matching `*.sops.yaml` is fully encrypted (all values, including comments) to a single age
recipient defined in `.sops.yaml`. Encrypted in the repo: `secrets.sops.yaml` (cluster CAs and tokens),
`talosconfig.sops.yaml`, `controlplane.sops.yaml`, `worker.sops.yaml`, `worclustershire{1,2,3}.sops.yaml`.

Prefer process substitution so plaintext never lands on disk or in git:

```
talosctl apply-config --talosconfig <(sops -d talosconfig.sops.yaml) \
  -n 192.168.8.4 -e 192.168.8.4 -f <(sops -d worclustershire1.sops.yaml)
```

Bulk in-place round trip (from `README.md`) — **never commit while decrypted**, and re-encrypt immediately:

```
for f in *.sops.yaml; do sops -d -i "$f"; done   # decrypt all, in place
for f in *.sops.yaml; do sops -e -i "$f"; done   # encrypt all, in place
```

For a single file, `sops <file>` edits it in place without ever writing plaintext.

Gotchas:

- `.gitignore` is empty and nothing filters plaintext, so a decrypted working tree is one `git add .` away from leaking cluster CAs and private keys. Check `git status` and file contents before staging.
- The committed `talosconfig.sops.yaml` has `endpoints: []`, so `talosctl` invocations must pass `-e`/`--endpoints` explicitly.
- The first rule in `.sops.yaml` (Kubernetes Secrets, `data`/`stringData` only) matches nothing currently in the repo; its `path_regex` requires a directory component and a literal `secrets.yaml` filename.
- `.sops.yaml`'s leading TODO comment about `YOUR_AGE_PUBLIC_KEY` is stale — a real recipient is configured.

## Common operations

Apply configs to all nodes (post-bootstrap):

```
talosctl apply-config --talosconfig <(sops -d talosconfig.sops.yaml) -n 192.168.8.4 -e 192.168.8.4 -f <(sops -d worclustershire1.sops.yaml) && \
talosctl apply-config --talosconfig <(sops -d talosconfig.sops.yaml) -n 192.168.8.5 -e 192.168.8.5 -f <(sops -d worclustershire2.sops.yaml) && \
talosctl apply-config --talosconfig <(sops -d talosconfig.sops.yaml) -n 192.168.8.6 -e 192.168.8.6 -f <(sops -d worclustershire3.sops.yaml)
```

First apply to a freshly-booted node uses `--insecure` and the node's DHCP-assigned address.

Upgrade Talos (one node at a time; `--preserve` is required so Longhorn data survives):

```
talosctl upgrade --image factory.talos.dev/nocloud-installer-secureboot/88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b:v1.11.5 --nodes "${node_ip}" --preserve
```

The installer image is a factory schematic (SecureBoot + nocloud) whose extensions are load-bearing:
`iscsi-tools` and `util-linux-tools` for Longhorn, `qemu-guest-agent` for Proxmox. Changing the schematic
hash changes which extensions the node has, so keep the image string identical in `gen config` and `upgrade`.

There is no lint or test step. The only offline check available is
`talosctl validate --config <decrypted-config> --mode metal`; everything else is verified by applying to a node.

## CI

`.github/workflows/claude.yml` (`@claude` mentions) and `.github/workflows/claude-code-review.yml`
(automatic PR review) both pin action SHAs and pass `--model claude-opus-5 --effort xhigh`. Each file
carries long comments explaining its permission scope and, for the review workflow, why an explicit
`--allowed-tools` list is mandatory in agent mode and why the code-review plugin is deliberately not used.
Read those comments before editing either workflow — the settings are intentional, not boilerplate.

## Host notes

`README.lorcan.md` documents an e1000e NIC hardware hang on the `lorcan` host, worked around with an
`ethtool -K nic0 tso off gso off` post-up line in `/etc/network/interfaces`.
