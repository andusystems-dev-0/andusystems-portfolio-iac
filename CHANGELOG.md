# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- Portfolio image bumped to latest build (automated via CI pipeline)

## [2025-04] — Cluster status and reverse proxy

### Added
- `cluster-status` nginx reverse proxy deployment and IngressRoute for aggregating
  health endpoints from all clusters under `/api/status/*` on the portfolio host
- `cluster-status` Service and Certificate resources in the `cluster-status` namespace
- IngressRoute PathPrefix rule so Traefik prefers the status route over the catch-all
  portfolio IngressRoute

### Fixed
- Portfolio deployment stabilised after namespace and registry pull secret prerequisites
  were moved to the Ansible `portfolio` role

## [2025-03] — Management cluster integration and security hardening

### Added
- Traefik role added to portfolio playbook to provide in-cluster ingress
- Registry pull secret (`nexus-registry-credentials`) bootstrapped by Ansible so
  ArgoCD never needs access to the Nexus credentials
- Pod security hardening: `runAsNonRoot`, `readOnlyRootFilesystem`, dropped capabilities,
  `seccompProfile: RuntimeDefault` applied to portfolio and cluster-status workloads
- NetworkPolicy resources restricting pod-to-pod traffic

### Changed
- Deployment model migrated: workload reconciliation handed off to hub ArgoCD
  (andusystems-management); this repo now owns only bootstrap Ansible and Helm values
- `portfolio` role trimmed to namespace + image-pull secret only — all workload
  resources moved to ArgoCD-managed manifests

### Fixed
- Kubernetes role corrected to handle kubeadm node mode flag bug
- VPS firewall rules updated for Docker + Pangolin gerbil compatibility

## [2025-02] — Refactor and rename

### Changed
- Repository and all configurations renamed from `slimerio` to `portfolio`
- Ansible configuration structure refactored for improved readability and separation
  of concerns; unused files removed

### Added
- `alloy` role and Helm values for Grafana Alloy (replaces ad-hoc scrape configs)
- `cert-manager` values updated with DNS-01 recursive nameserver configuration

## [2025-01] — LGTM observability stack

### Added
- kube-prometheus-stack (Prometheus + Alertmanager) deployed as spoke instance;
  Grafana disabled — hub cluster provides the UI
- Loki deployed in SingleBinary mode with S3 storage backend (MinIO on storage cluster)
- Tempo deployed for distributed tracing (OTLP ingest)
- Alloy collector configured to ship metrics, logs, and traces to the three backends
- Prometheus LoadBalancer service for direct query from hub Grafana
- Loki LoadBalancer service for cross-cluster access
- Cluster identified by `cluster: portfolio` external label in Prometheus

### Fixed
- Loki values corrected for SingleBinary mode (removed invalid replica settings)
- Networking values updated to expose LoadBalancer IPs for Prometheus, Loki, and Tempo

## [2024-12] — Initial cluster setup

### Added
- Ansible playbook structure: `portfolio.yml` (full bootstrap) and `apps.yml`
  (post-bootstrap secrets)
- `vms` role: Terraform-based VM provisioning on Proxmox
- `kubernetes` role: kubeadm cluster init with Flannel CNI, worker node join,
  containerd configuration with SystemdCgroup, static registry hostname pinning
- `metallb` role: MetalLB Helm install + IPAddressPool + L2Advertisement
- `longhorn` role: Longhorn distributed block storage (3-replica default)
- `cert-manager` role: Let's Encrypt ClusterIssuer with Cloudflare DNS-01
- `pangolin-newt` role: Newt tunnel client credentials secret
- `portfolio` role: portfolio namespace + Nexus image-pull secret
- Ansible inventory with control-plane and four workers
- Vault example file documenting all required secret keys
- `apps/` directory with Helm values for all cluster components
