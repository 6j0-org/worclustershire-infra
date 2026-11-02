# worclustershire

# Overview

`worclustershire` is a 3-node [Talos Linux](https://www.talos.dev/) Kubernetes homelab cluster. Each node is a VM on its own [ProxMox](https://www.proxmox.com/) host, and every node is a control plane that also runs workloads. Apps are deployed by Flux from `worclustershire-deploy`; this repo is the layer below that.

You create the VMs by hand. [OpenTofu](https://opentofu.org/) and the [siderolabs/talos provider](https://github.com/siderolabs/terraform-provider-talos/tree/v0.12.0) do everything else, all from `cluster/`:

- build the Talos image (an Image Factory schematic with the system extensions) and give you its ISO URL
- hold the cluster secrets, and render one machine config per node
- apply the configs, bootstrap etcd, and wait for the cluster
- upgrade Talos (change `talos_version`) and Kubernetes (change `kubernetes_version`) in place
- output `talosconfig` and `kubeconfig`, renewing their client certificates before they expire

Do not use DHCP: if a node's IP address changes, it drops out of the cluster.

Host notes: [basima](README.basima.md) (`worclustershire1`), [lorcan](README.lorcan.md) (`worclustershire2`), [ilona](README.ilona.md) (`worclustershire3`). Runbooks are in [runbooks/](runbooks/).

Based on:

- https://www.talos.dev/v1.11/introduction/getting-started/
- https://www.talos.dev/v1.11/introduction/prodnotes/
- https://github.com/siderolabs/terraform-provider-talos/tree/v0.12.0/docs

# Prerequisites

- the ProxMox hosts above
- an S3 (or S3-compatible, e.g. Wasabi) bucket for the OpenTofu state
- a wasabisys.com account for offsite backups for Longhorn
- the age key for `.sops.yaml`, to decrypt `secrets.sops.yaml` and `talosconfig.sops.yaml`
- for CI: a [self-hosted GitHub Actions runner](https://docs.github.com/en/actions/hosting-your-own-runners) on the node network (see [CI](#ci))

## Install required packages

This repo ships package manifests that install the CLI tools it uses (`tenv`, which provides `tofu`; `talosctl`; `kubectl`; `sops`; and `zizmor` for auditing the workflow):

- macOS, using [Homebrew](https://brew.sh/) and the `Brewfile`:

  ```shell
  brew bundle
  ```

- Arch Linux, using the `pkglist.txt` (`tenv-bin` is in the AUR, so use an AUR helper):

  ```shell
  grep -vE '^(#|$)' pkglist.txt | yay -S --needed -
  ```

Then install the pinned OpenTofu version. Don't install `opentofu` directly; `tenv` reads `cluster/.opentofu-version`:

```shell
tenv tofu install "$(cat cluster/.opentofu-version)"
```

On other operating systems, install the tools listed above manually. The optional virt-manager (QEMU/KVM) path below additionally needs `virt-manager`, `swtpm`, and NetworkManager — Linux-only tools listed as commented-out entries in `pkglist.txt`.

## The state passphrase

The OpenTofu state contains the cluster's PKI (the etcd, Kubernetes and Talos CA keys), so `cluster/versions.tf` encrypts the state and plan files with a passphrase, on top of the bucket's own encryption. Keep it in your password manager, and export it whenever you run `tofu`:

```shell
export TF_VAR_state_passphrase='<the passphrase>'
```

Never put it in `terraform.tfvars`. If it's lost, the state is lost too. The cluster secrets still exist in `secrets.sops.yaml`, though, and you can rebuild the state by importing them again (see the next section).

# Adopting the running cluster

The cluster was built in 2025 with `talosctl gen config`. This moves it into OpenTofu without rebuilding it, by importing its existing secrets instead of generating new ones. Do this once, locally, before turning on CI.

1. Set `bucket`/`region` (and `s3_endpoint` for Wasabi) in `cluster/terraform.tfvars`, and get credentials for the bucket into your environment.
1. Initialize, and import the secrets. The provider reads the import from a file path, so decrypt to a private temporary file and delete it straight away:
   ```shell
   cd cluster
   tofu init
   (umask 077; sops -d ../secrets.sops.yaml > /dev/shm/secrets.yaml)
   tofu import talos_machine_secrets.this /dev/shm/secrets.yaml
   shred -u /dev/shm/secrets.yaml
   ```
1. Plan:
   ```shell
   tofu plan -out=plan.file
   ```
   Expect 6 resources to add and 1 to change. `talos_machine_secrets.this` changes **in place**: only `talos_version` (`v1.3` → `v1.11`) changes, because the import always records `v1.3`. If the plan says it must be **replaced**, stop. A replacement generates new cluster CAs.
1. Apply:
   ```shell
   tofu apply -parallelism=1 plan.file
   ```
   On each node, `talos_machine` applies the generated config. It doesn't upgrade anything: the running version and schematic already match. `talos_cluster` treats "already bootstrapped" as success and doesn't run a Kubernetes upgrade, because `kubernetes_version` matches what's running.

A trial run on 2026-11-04 imported the secrets into a scratch state and compared the three generated configs with each node's live config (`talosctl get machineconfig`). They match in every field except one addition: `cluster.apiServer.certSANs` gains `worclustershire.6j0.org` next to `192.168.8.7`. The API server certificate already includes that name (Talos adds the endpoint's host itself), so nothing changes in practice. Applying the config doesn't reboot the nodes. Three settings that existed only on the nodes, and were never in a patch, are now in `cluster/` (see [History](#history)).

# Day-to-day

Run every `tofu` command from `cluster/`, with `TF_VAR_state_passphrase` exported. Always apply with `-parallelism=1`: it's what makes OS upgrades go one node at a time.

```shell
tofu plan -out=plan.file
tofu apply -parallelism=1 plan.file
```

Once CI is on, open a PR instead and let the workflow plan and apply.

## talosconfig and kubeconfig

```shell
tofu output -raw talosconfig > ~/.talos/config.worclustershire
talosctl config merge ~/.talos/config.worclustershire && rm ~/.talos/config.worclustershire
tofu output -raw kubeconfig > ~/.kube/worclustershire
```

Then merge the kubeconfig:

```shell
cp ~/.kube/config ~/.kube/config.$(date +%s) && export KUBECONFIG=$(find "${HOME}/.kube" -maxdepth 1 -type f ! -name config ! -name 'config.*' | tr "\n" ":"); kubectl config view --flatten > ~/.kube/config; chmod 600 ~/.kube/config; unset KUBECONFIG;
```

The talosconfig endpoints are the node IPs, so `talosctl` needs no `-e`. The VIP is left out on purpose: it [depends on etcd and Kubernetes](https://www.talos.dev/v1.11/talos-guides/network/vip/#caveats), so it is down exactly when you most need `talosctl`.

Both client certificates are renewed by the provider within a month of expiring, on any plan or apply. Re-export them after an apply to pick up renewed ones. Your local copies don't renew themselves; see [runbooks/updating-certs.md](runbooks/updating-certs.md).

## Break-glass access

`talosconfig.sops.yaml` is a SOPS-encrypted talosconfig that works without the OpenTofu state. Use it if the state, the bucket or the passphrase is unavailable:

```shell
talosctl --talosconfig <(sops -d talosconfig.sops.yaml) -e 192.168.8.4 -n 192.168.8.4 health
```

Its certificate doesn't renew itself (next expiry 2027-09-23; see [runbooks/updating-certs.md](runbooks/updating-certs.md)). `secrets.sops.yaml` is the backup of the cluster secrets; never delete it.

# Upgrading Talos

Based on:

- https://www.talos.dev/v1.11/talos-guides/upgrading-talos/
- https://github.com/siderolabs/terraform-provider-talos/blob/v0.12.0/docs/resources/machine.md

Schedule upgrades by [runbooks/updating.md](runbooks/updating.md). Then change `talos_version` in `cluster/terraform.tfvars`, one minor version at a time, and plan and apply with `-parallelism=1`. For each node, in turn, `talos_machine` pulls the new installer, drains the node, reboots it, and uncordons it. Changing `extensions` works the same way: it changes the schematic, and that triggers an upgrade.

Leave `talos_config_contract` alone. It is the machine-config schema the cluster was created with, not the installed version, and bumping it regenerates every config with the newer version's defaults.

The old runbook passed `--preserve` so Longhorn data survives. On Talos v1.11, `talosctl` hides that flag and the node ignores it: upgrades always keep the EPHEMERAL partition, where `/var/lib/longhorn` lives.

# Upgrading Kubernetes

Change `kubernetes_version` in `cluster/terraform.tfvars`, then plan and apply. `talos_cluster` runs Talos's [upgrade-k8s](https://www.talos.dev/v1.11/kubernetes-guides/upgrading-kubernetes/) procedure, which upgrades the control-plane components and kubelets one at a time with health checks. This restarts kubelets, so schedule it by [runbooks/updating.md](runbooks/updating.md) as well.

# Upgrading OpenTofu

```shell
cluster/update_opentofu.sh
```

This writes the latest stable version to `cluster/.opentofu-version` and `required_version` in `cluster/versions.tf`, then installs it with `tenv`.

# Replacing or adding a node

1. Add or keep the node in `nodes` in `cluster/terraform.tfvars`.
1. Get the ISO URL. On a cluster that's already applied, it's just an output:
   ```shell
   tofu output -raw iso_url
   ```
   The schematic bakes in these extensions (see `extensions` in `terraform.tfvars`):
   - `siderolabs/iscsi-tools` and `siderolabs/util-linux-tools`, for [Longhorn](https://longhorn.io/docs/1.9.0/advanced-resources/os-distro-specific/talos-linux-support/)
   - `siderolabs/qemu-guest-agent`, for [ProxMox](https://www.talos.dev/v1.11/talos-guides/install/virtualized-platforms/proxmox/#qemu-guest-agent-support-iso)
1. In ProxMox, download the ISO from that URL into your ISO storage ("Download from URL"), or follow [these instructions](https://www.talos.dev/v1.11/talos-guides/install/virtualized-platforms/proxmox/#upload-iso) to upload it.
1. Click the "Create VM" button. Use default settings except for these:
   - General:
     - Name: the node's hostname from `nodes`, e.g. `worclustershire1`.
     - Check the Advanced box
     - Enable "Start at boot"
   - OS:
     - ISO image: nocloud-amd64-secureboot.iso
   - System:
     - Graphic card: VirtIO-GPU (for a higher resolution terminal)
     - BIOS: OVMF (UEFI)
     - EFI Storage: local-lvm
     - Disable "Pre-Enroll keys"
     - Enable "QEMU Agent"
     - Enable "Add TPM"
     - TPM Storage: local-lvm
   - Disks:
     - 1st drive: 5G
     - 2nd drive: 500G
     - On every drive, enable "Discard" and "SSD emulation" (under Advanced)
     - Keep the total size of all drives *below* the thin pool's size (`pvesm status`, `local-lvm`). Longhorn schedules against the drive size, not the host's free space, so an oversized drive lets a replica rebuild fill the pool and hang the host. See [runbooks/thin-pool-full.md](runbooks/thin-pool-full.md).
   - CPU:
     - Type: Host (all the way at the bottom)
     - Cores: 2
   - Memory: as much as possible, but reserve at least 1GB for the ProxMox host.
   - Network: note the VM's MAC address (Hardware > Network Device).
   - Confirm:
     - Do **not** enable "Start after created" yet.
1. In the router, add a DHCP reservation that gives the VM's MAC address the same IP as its entry in `nodes`. The VM boots from the ISO into maintenance mode with a DHCP address, and OpenTofu has to find it there: the provider connects to the node at that IP, applies the config, and then waits for the node at the *same* address while it reboots with its static IP. Then start the VM.
1. Plan and apply with `-parallelism=1`. Only that node's `talos_machine` (and, for a new node, `talos_cluster`'s list of control-plane nodes) should change.
1. A new node also needs its IP in the `worclustershire.6j0.org` A record.

# virt-manager (QEMU/KVM)

1. Ensure that you have the swtpm package installed.
1. Create a new VM with these settings:
   - Local install media
   - Choose ISO: Use the one downloaded above
   - Uncheck "Automatically detect from installation media"
   - Choose the operating system you are installing: Generic Linux 2024
   - Memory: 6144
   - CPUs: 2
   - In Overview, change Firmware to "UEFI x86_64: /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd"
   - Click Add Hardware, and choose TPM.
1. Create a bridge:
   ```
   nmcli con add type bridge con-name br0 ifname br0
   nmcli con add type bridge-slave ifname enp0s31f6 master br0
   nmcli connection delete Wired\ connection\ 1
   # Wait a minute or two for DHCP to work.
   ```

# CI

`.github/workflows/opentofu-talos.yml` runs `tofu plan` on pull requests to `main` and comments the plan on the PR. When the PR merges to `main`, it applies that plan with `-parallelism=1`. It does nothing until the repository variable `TOFU_CI_ENABLED` is `true`. Set that only after the adoption above, and once these are in place:

1. Register a [self-hosted runner](https://docs.github.com/en/actions/hosting-your-own-runners) on the node network. GitHub-hosted runners can't reach the nodes, and both plan and apply talk to them. The workflow skips PRs from forks so their code never runs on your LAN; also keep the repo private, or require approval for outside collaborators.
1. Add the state passphrase as the repository secret `TOFU_STATE_PASSPHRASE`.
1. Give the runner credentials for the state bucket. For AWS, set `role-to-assume` and `aws-region` in the workflow to an IAM role that trusts GitHub's OIDC provider and can read and write the bucket. For a non-AWS store, replace that step with `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` repository secrets, as the comment in the workflow describes.

# History

| Date       | Event                                                                                                                                                                                                                                            |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 2025-09-22 | Cluster bootstrapped with `talosctl gen config`, endpoint `https://192.168.8.7:6443` (the VIP).                                                                                                                                                  |
| Undated    | Created an A record `worclustershire.6j0.org` for all three node IPs, and moved every node's `cluster.controlPlane.endpoint` to `https://worclustershire.6j0.org:6443` with `talosctl patch mc --mode=no-reboot`. `cluster_endpoint` keeps it.   |
| 2026-04-16 | Dual-stack: each node's IPv6 address, plus IPv6 pod and service subnets. They were applied to the rendered node configs only; they're now in `nodes` and `cluster/patches/dual-stack.yaml`. A `vip.ipv6` setting was committed but never valid. |
| 2026-11-04 | Moved to OpenTofu. The trial adoption also found kubelet image-GC thresholds (70/60) applied on every node, reason unrecorded; now in `cluster/patches/kubelet-image-gc.yaml`.                                                                   |
