# AGENTS.md

Guidance for AI coding agents working in this repository. `CLAUDE.md` is a
symlink to this file — edit `AGENTS.md`, and do not replace the symlink with a
real file.

## What this repo is

Infrastructure for `worclustershire`, a 3-node Talos Linux Kubernetes homelab
cluster running as Proxmox VMs. It's managed with OpenTofu and the
`siderolabs/talos` provider (pinned to 0.12.0) in `cluster/`. The VMs are
created by hand (`README.md` → Replacing or adding a node). Apps are deployed
by Flux from the separate `worclustershire-deploy` repo.
`.github/workflows/opentofu-talos.yml` plans on PRs and applies on merge to
`main`, but only once the `TOFU_CI_ENABLED` repository variable is `true`.

Consequences for agents:

- Use `tofu`, never `terraform`. The version is pinned in
  `cluster/.opentofu-version` (read by tenv and by `setup-opentofu` in CI) and
  in `required_version` in `cluster/versions.tf`. `cluster/update_opentofu.sh`
  keeps the two in sync.
- Local checks: `tofu fmt -recursive -check` and `tofu validate` (after
  `tofu init -backend=false`). `talosctl validate --config <file> --mode metal`
  works on a rendered machine config, not on the patch fragments.
- **This is a live cluster.** Never run `tofu apply` against the real backend
  unless asked: an apply can reboot or upgrade nodes. A plan is safe; it only
  reads from the nodes.
- A change to `cluster/` and the `README.md` step or runbook that describes it
  is one unit.

## Cluster facts

|            |                                                                                                                  |
| ---------- | ---------------------------------------------------------------------------------------------------------------- |
| Nodes      | `worclustershire1` 192.168.8.4, `worclustershire2` 192.168.8.5, `worclustershire3` 192.168.8.6 (plus `…::4/5/6`) |
| VIP        | 192.168.8.7 (IPv4 only); gateway 192.168.8.1                                                                     |
| Endpoint   | `https://worclustershire.6j0.org:6443` (A record points at all three node IPs) — `cluster_endpoint`              |
| Topology   | All three nodes are control planes that also run workloads (`allowSchedulingOnControlPlanes`)                    |
| Networking | Static only. Dual-stack: IPv6 pod/service subnets in `cluster/patches/dual-stack.yaml`                           |
| Storage    | Longhorn (iSCSI + hugepages + bind mount, `cluster/patches/longhorn.yaml`), MetalLB for LoadBalancers            |
| Versions   | Talos v1.11.5, Kubernetes 1.34.0, schematic `88d1f7a5…` (all in `cluster/terraform.tfvars`)                      |

## How `cluster/` fits together

```
image.tf    extensions -> talos_image_factory_schematic -> urls (iso_url, installer_secureboot)
main.tf     talos_machine_secrets (imported from secrets.sops.yaml)
              -> data.talos_machine_configuration.node[each]   (common patches + certSANs + install + network)
              -> talos_machine.node[each]                      (apply config, OS upgrades, drain)
              -> talos_cluster.this                            (bootstrap etcd, upgrade-k8s)
              -> talos_cluster_kubeconfig.this / data.talos_client_configuration.this -> outputs
```

Things that are easy to get wrong:

- The generated config must match what the nodes run. Several settings once
  lived only in the hand-edited rendered configs (endpoint, dual-stack, image-GC
  thresholds, the VIP SAN). They were found by diffing the rendered configs
  against `talosctl get machineconfig v1alpha1 -o jsonpath='{.spec}'` from each
  node. Do the same before any change that could drop a setting, and never
  print the configs themselves: they contain the cluster secrets.
- Talos config patches don't merge lists consistently. `cluster.network`
  subnets are **replaced** by a patch (hence both families in
  `dual-stack.yaml`). `apiServer.certSANs` is **appended to**. Check the
  rendered result, not the patch.
- `cluster_endpoint` is the DNS name, not the VIP. Deriving it from `vip` would
  move every node back to the VIP endpoint.
- Talos's `vip` block takes a single address. There is no `ipv6:` key; one was
  committed here once and never worked.
- Patch order lives in `local.common_patches` (`patches/*.yaml`), followed by
  the generated certSANs, install and network patches. A cluster-wide setting is
  a new file in `patches/`, added to that list. A per-node or parameterized
  setting goes in the `yamlencode` patches in `main.tf`.
- The VIP and each node's addresses are in **one** interface entry
  (`deviceSelector.busPath: "0*"`). Do not split them into separate patches.
- `talos_machine` uses `for_each`, so nodes can't be chained with `depends_on`.
  Rolling upgrades depend on `apply -parallelism=1`, which the README and the
  workflow both use. Keep it in both places.
- `ignore_kubernetes_upgrade_drift = true` on `talos_machine` makes
  `talos_cluster` the only thing that upgrades Kubernetes. `kubernetes_version`
  must be what the cluster runs, or the next apply upgrades it.
- `talos_config_contract` (`v1.11`) is deliberately separate from
  `talos_version` (the installed OS). Never bump the contract as part of an OS
  upgrade.
- `talos_machine_secrets` was imported. The import records `talos_version = v1.3`, so the first plan shows an in-place change to `v1.11`. A plan that
  *replaces* `talos_machine_secrets` would mint new CAs and break the cluster:
  never accept one.
- `talos_machine` reaches a freshly booted node at its static IP and waits at
  the same address after the reboot, hence the DHCP reservation in the README.
  Don't point `endpoint` at a DHCP address instead.
- Talosconfig endpoints are the node IPs, not the VIP, on purpose.

## Secrets

- The OpenTofu state holds the cluster PKI. It is encrypted by OpenTofu
  (`encryption` block, pbkdf2 + AES-GCM, `enforced = true`) with
  `TF_VAR_state_passphrase`, which is the `TOFU_STATE_PASSPHRASE` secret in CI.
  Never weaken `enforced`, never add a fallback, and never put the passphrase
  in a file.
- `secrets.sops.yaml` (the cluster secrets: the backup and the import source)
  and `talosconfig.sops.yaml` (break-glass `talosctl` access, independent of the
  state) stay SOPS-encrypted to the age recipient in `.sops.yaml`. Read them
  with `sops -d` piped or through process substitution. Never decrypt them in
  place, never write plaintext into the repo, and never commit a decrypted
  file. `talosctl --talosconfig <(sops -d talosconfig.sops.yaml) -e <ip> -n <ip>`
  is the way to query nodes.
- Never print the `talosconfig`/`kubeconfig` outputs, `machine_configuration`
  values or live machine configs into an issue, PR, commit, or chat. Don't use
  `nonsensitive()` on them in committed code.
- `.gitignore` covers `.terraform/`, state and plan files, and the plaintext
  names the old workflow produced. Commit `cluster/.terraform.lock.hcl`.
- The first rule in `.sops.yaml` (Kubernetes Secrets) matches nothing here.
  The leading TODO about `YOUR_AGE_PUBLIC_KEY` is stale.

## Conventions

- Every file in `cluster/patches/`, and every inline patch in `main.tf`, opens
  with a comment linking the upstream doc that justifies it, plus any history a
  reader needs (why a value is what it is). Preserve this, and add it to new
  patches.
- The docs target **Talos v1.11**. `patches/metallb.yaml` links a v1.12 page;
  that's the page the setting came from.
- Provider and OpenTofu versions are exact pins. Dependabot bumps the provider
  (`terraform`, `/cluster`) and the actions, with a 7-day cooldown.
- GitHub Actions are pinned to full commit SHAs with a trailing `# v4`-style
  comment. The workflow runs on a self-hosted runner on the LAN. Keep the
  fork-PR guard and the `TOFU_CI_ENABLED` gate in its `if:`.

## Host notes

Each node is VM 100 on its own single-disk Proxmox host:

| Host     | IP          | VM                 | Notes                                                                                                                          |
| -------- | ----------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| `basima` | 192.168.8.3 | `worclustershire1` | `README.basima.md`                                                                                                             |
| `lorcan` | 192.168.8.9 | `worclustershire2` | `README.lorcan.md` - also an e1000e NIC hang worked around with `ethtool -K nic0 tso off gso off` in `/etc/network/interfaces` |
| `ilona`  | 192.168.8.8 | `worclustershire3` | `README.ilona.md` - the full write-up                                                                                          |

On all three, the `local-lvm` thin pool must stay larger than the 800G VM disk, and `scsi0` has `discard=on,ssd=1`
(applied on all three as of 2026-11-01). TRIM still doesn't pass through Talos's LUKS volumes on v1.11
(`encryption.allowDiscards` needs a newer Talos). Recovery procedure for a full pool is in
`runbooks/thin-pool-full.md`. Planned VM restarts (drain, single-instance CloudNativePG `nodeMaintenanceWindow`,
`qm shutdown; qm start`) are in `runbooks/node-restart.md`. Schedule updates (Proxmox packages, Talos, Kubernetes)
by `runbooks/updating.md`: Saturday after the weekly Longhorn snapshot checksum, so replica rebuilds take seconds
rather than an hour. Client certificate expiry is in `runbooks/updating-certs.md`.

## Package manifests

This repo ships a `Brewfile` (macOS: `brew bundle`) and a `pkglist.txt` (Arch Linux) that install the CLI tools the repo uses. Keep them in sync with the docs:

- When the docs start instructing readers to run a new local tool, add the package to BOTH files, with a comment noting what uses it. Commands run on the Proxmox hosts (`qm`, `pvesm`, `lvs`, `ethtool`) don't belong here.
- When a tool stops being used, remove it from both files.
- Linux-only tools for the optional virt-manager (QEMU/KVM) path belong in pkglist.txt as commented-out optional entries (Homebrew can't provide them); mirror that pattern for similar additions.
- Verify package names before adding them: `brew info <formula>` for Homebrew, and the official repos/AUR for Arch (e.g. kubectl is Homebrew `kubernetes-cli` but Arch `kubectl`). If a package is AUR-only, note that in pkglist.txt's header instructions.
- Update the "Install required packages" section in README.md if the tool list changes.
