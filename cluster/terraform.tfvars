# worclustershire. state_passphrase is deliberately absent; see variables.tf.

# Backend
bucket = "worclustershire-tofu-state"
region = "us-west-1"
# For a non-AWS S3-compatible store, set its endpoint, e.g. Wasabi:
# s3_endpoint = "https://s3.us-west-1.wasabisys.com"

# Cluster
cluster_name     = "worclustershire"
cluster_endpoint = "https://worclustershire.6j0.org:6443"

nodes = {
  worclustershire1 = { ip = "192.168.8.4", ipv6 = "2603:8001:5800:8cf::4" } # VM 100 on basima
  worclustershire2 = { ip = "192.168.8.5", ipv6 = "2603:8001:5800:8cf::5" } # VM 100 on lorcan
  worclustershire3 = { ip = "192.168.8.6", ipv6 = "2603:8001:5800:8cf::6" } # VM 100 on ilona
}

vip                = "192.168.8.7"
gateway            = "192.168.8.1"
prefix_length      = 24
ipv6_prefix_length = 64
install_disk       = "/dev/sda"

# Versions
talos_version         = "v1.11.5"
talos_config_contract = "v1.11"
# What the cluster runs (kubectl version, 2026-11-04). Changing it runs
# upgrade-k8s.
kubernetes_version = "1.34.0"

extensions = [
  # https://longhorn.io/docs/1.9.0/advanced-resources/os-distro-specific/talos-linux-support/
  "siderolabs/iscsi-tools",
  "siderolabs/util-linux-tools",
  # https://www.talos.dev/v1.11/talos-guides/install/virtualized-platforms/proxmox/#qemu-guest-agent-support-iso
  "siderolabs/qemu-guest-agent",
]
