# Development

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Ansible | ≥ 2.15 | `pip install ansible` |
| `kubernetes.core` collection | latest | `ansible-galaxy collection install kubernetes.core` |
| `community.general` collection | latest | `ansible-galaxy collection install community.general` |
| Terraform | ≥ 1.5 | [terraform.io/downloads](https://developer.hashicorp.com/terraform/downloads) |
| `helm` | ≥ 3.14 | `snap install helm --classic` or package manager |
| `kubectl` | ≥ 1.31 | `snap install kubectl --classic` or package manager |
| `ansible-vault` | bundled with Ansible | — |

Install all Ansible collection dependencies at once:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

## Vault setup

All secrets are stored in `ansible/inventory/portfolio/group_vars/all/vault.yml`.
This file is encrypted with Ansible Vault and must never be committed unencrypted.

```bash
# First-time setup: copy the example and populate it
cp ansible/inventory/portfolio/group_vars/all/vault.example \
   ansible/inventory/portfolio/group_vars/all/vault.yml

# Encrypt the file
ansible-vault encrypt ansible/inventory/portfolio/group_vars/all/vault.yml

# Edit later
ansible-vault edit ansible/inventory/portfolio/group_vars/all/vault.yml

# View without editing
ansible-vault view ansible/inventory/portfolio/group_vars/all/vault.yml
```

See `vault.example` for the full list of required keys and their expected formats.

## Environment variables

No environment variables are required at runtime. All configuration is driven through
Ansible Vault variables. The `KUBECONFIG` path is set per-task from `vault_kubeconfig`
(defaults to `{{ repo_root }}/kubeconfig` after the `kubernetes` role fetches it).

## Full cluster bootstrap

Run when provisioning a cluster from scratch or rebuilding after a teardown.
Order matters — each playbook imports roles in the correct dependency sequence.

```bash
# Complete bootstrap: VMs → Kubernetes → MetalLB → Longhorn → cert-manager → apps
ansible-playbook -i ansible/inventory/portfolio \
  ansible/configurations/portfolio.yml --ask-vault-pass
```

The `portfolio.yml` playbook runs these roles in order:

| Order | Role | What it does |
|---|---|---|
| 1 | `vms` | Provisions VMs on Proxmox via Terraform |
| 2 | `kubernetes` | Installs containerd + kubeadm, inits control-plane, joins workers, installs Flannel CNI |
| 3 | `metallb` | Applies MetalLB Helm chart and IPAddressPool |
| 4 | `longhorn` | Installs Longhorn Helm chart |
| 5 | `cert-manager` | Applies Cloudflare token secret + ClusterIssuer |
| 6 | `pangolin-newt` | Creates Newt credentials secret |
| 7 | `portfolio` | Creates portfolio namespace + Nexus image-pull secret |

After the full bootstrap, ArgoCD (running on the management cluster) syncs the remaining
workloads (Traefik, kube-prometheus-stack, Loki, Tempo, Alloy, portfolio Deployment,
cluster-status) from this repository.

## Post-bootstrap secrets playbook

Run `apps.yml` after ArgoCD has synced workloads and whenever a secret needs to be
rotated. This playbook only applies resources that ArgoCD cannot own (Kubernetes Secrets
containing Vault-sourced credentials, and any CRDs that must precede Helm chart installs).

```bash
ansible-playbook -i ansible/inventory/portfolio \
  ansible/configurations/apps.yml --ask-vault-pass
```

`apps.yml` runs:

| Role | What it does |
|---|---|
| `cert-manager` | Rotates the Cloudflare token secret and re-applies the ClusterIssuer |
| `pangolin-newt` | Rotates the Newt credentials secret |
| `portfolio` | Rotates the Nexus image-pull secret |

## Targeting individual roles

Use Ansible tags to run a single role without executing the full playbook. Every role
is tagged with its component name and `install`.

```bash
# Re-run only the cert-manager role
ansible-playbook -i ansible/inventory/portfolio \
  ansible/configurations/portfolio.yml --ask-vault-pass \
  --tags cert-manager

# Re-run only the kubernetes role
ansible-playbook -i ansible/inventory/portfolio \
  ansible/configurations/portfolio.yml --ask-vault-pass \
  --tags kubernetes

# Re-run only the portfolio namespace + pull secret
ansible-playbook -i ansible/inventory/portfolio \
  ansible/configurations/apps.yml --ask-vault-pass \
  --tags portfolio
```

Available tags: `vms`, `kubernetes`, `metallb`, `longhorn`, `cert-manager`,
`pangolin-newt`, `portfolio`, `alloy`, `loki`, `tempo`, `kube-prometheus-stack`,
`install`.

The `kubernetes` role also exposes a `registry-hosts` tag for re-pinning the
registry hostname in `/etc/hosts` on all nodes without running the destructive
kubeadm reset/init tasks:

```bash
ansible-playbook -i ansible/inventory/portfolio \
  ansible/configurations/portfolio.yml --ask-vault-pass \
  --tags registry-hosts
```

## Day-2 operations

### Rotating secrets

Edit the vault, then re-run `apps.yml` (or the relevant role with `--tags`). ArgoCD
will pick up the new secret on the next sync if the workload references it by name.

### Updating Helm values

Edit the relevant file in `apps/<component>/values.yml`, commit, and push. ArgoCD
detects the change and syncs the Helm release automatically (no manual step required).

### Updating the portfolio image

The portfolio app repo's CI pipeline bumps `apps/portfolio/manifest.yml` in this repo
after a successful build and push to the Nexus registry. ArgoCD then reconciles the
new image tag. No manual action is needed for routine image updates.

### Checking cluster state

```bash
# Set KUBECONFIG to the fetched config (created by the kubernetes role)
export KUBECONFIG=<repo_root>/kubeconfig

# All nodes
kubectl get nodes -o wide

# All pods across namespaces
kubectl get pods -A

# Alloy collector status
kubectl get pods -n alloy

# Loki storage
kubectl get pvc -n loki

# cert-manager certificate status
kubectl get certificates -A
```

### Re-provisioning a single worker

```bash
# Drain the node (replace <node-name> with the actual node name)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Remove the node from the cluster
kubectl delete node <node-name>

# Re-run the kubernetes role on that host only
ansible-playbook -i ansible/inventory/portfolio \
  ansible/configurations/portfolio.yml --ask-vault-pass \
  --tags kubernetes --limit <node-name>
```

## Repository conventions

- `apps/` contains only Helm values files and Kubernetes manifests. No shell scripts.
- Every manifest in `apps/` that references a secret uses Ansible template variables
  (`{{ variable_name }}`) so it can be rendered by the Ansible `template` lookup.
  These files are applied via `kubernetes.core.k8s` with `from_yaml_all | list`.
- Secrets are never committed to the repository. The `vault.example` file documents
  the shape of the vault without any real values.
- Ansible roles follow the `main.yml` → `import_tasks: install.yml` pattern so that
  tags on the `main.yml` import propagate to all tasks in `install.yml`.
