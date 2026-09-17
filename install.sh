#!/usr/bin/env bash
# Instalare completă a infrastructurii "kube-dev", de la zero, într-un singur
# pas: cheie SSH -> imagine cloud -> suport_vm (Terraform + Ansible) ->
# kubernetes_cluster (Terraform + bootstrap Ansible + k3s). Ordinea e fixă și
# obligatorie - suport_vm întotdeauna înainte de kubernetes_cluster (registry
# de imagini, Vault pentru secrete/certificate, NFS - vezi decizii.md).
#
# Precondiție - rulează o singură dată, cu sudo, ÎNAINTE de acest script:
#   sudo ./setup_hosts.sh
# (înregistrează în /etc/hosts hostname-urile UI-urilor expuse - argocd,
# keycloak, hubble, demo, gitlab, vault, signoz). Acest script (install.sh)
# NU cere niciodată sudo - rulează integral ca user normal.
#
# Fiecare pas Terraform/Ansible e idempotent - dacă scriptul eșuează la
# jumătate (ex. o VM pornește mai greu), rulează-l din nou; pașii deja
# finalizați nu vor face nimic în plus la a doua rulare.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="${PROJECT_ROOT}/ssh/id_ed25519"

# Adrese statice ale proiectului (aceleași peste tot în cod - vezi
# variables.tf, group_vars/all.yml) - nu se schimbă între rulări.
SUPORT_IP="10.10.10.20"
K3S_IPS=("10.10.10.10" "10.10.10.11" "10.10.10.12")

step() {
  echo
  echo "==> $*"
  echo
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "EROARE: unealta necesară '$1' nu e instalată." >&2
    exit 1
  }
}

# Adresele IP sunt fixe, dar host key-ul SSH al fiecărei VM se schimbă la
# fiecare recreare (terraform destroy + apply) - fără curățarea lui,
# ssh/ansible ar refuza conexiunea cu "REMOTE HOST IDENTIFICATION HAS
# CHANGED" (întâlnit repetat, la fiecare rebuild, în timpul dezvoltării
# acestui proiect).
wait_for_ssh() {
  local ip="$1"
  ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "${ip}" >/dev/null 2>&1 || true

  echo "Aștept SSH pe ${ip}..."
  for _ in $(seq 1 60); do
    if ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new \
           -o ConnectTimeout=3 -o BatchMode=yes \
           "admin@${ip}" "echo ok" >/dev/null 2>&1; then
      echo "  ${ip} - disponibil"
      return 0
    fi
    sleep 5
  done

  echo "EROARE: ${ip} nu a răspuns prin SSH după 5 minute." >&2
  return 1
}

for tool in terraform ansible-playbook ssh ssh-keygen curl virsh; do
  require_tool "${tool}"
done

step "1/9 - Cheie SSH dedicată proiectului"
"${PROJECT_ROOT}/ssh/generate_ssh_key.sh"

step "2/9 - Imagine cloud Ubuntu (fixată, verificată prin hash)"
"${PROJECT_ROOT}/iso/download_cloud_image.sh"

step "3/9 - Terraform: suport_vm"
(
  cd "${PROJECT_ROOT}/suport_vm/terraform"
  terraform init -input=false
  terraform apply -auto-approve
)

step "4/9 - Așteptare SSH pe suport-vm"
wait_for_ssh "${SUPORT_IP}"

step "5/9 - Ansible: suport_vm (Vault, GitLab, NFS, SigNoz)"
(
  cd "${PROJECT_ROOT}/suport_vm/ansible"
  ansible-playbook -i inventory.ini site.yml
)

step "6/9 - Terraform: kubernetes_cluster"
(
  cd "${PROJECT_ROOT}/kubernetes_cluster/terraform"
  terraform init -input=false
  terraform apply -auto-approve
)

step "7/9 - Așteptare SSH pe nodurile k3s"
for ip in "${K3S_IPS[@]}"; do
  wait_for_ssh "${ip}"
done

step "8/9 - Ansible: kubernetes_cluster (bootstrap sistem, userul adm, NFS client)"
(
  cd "${PROJECT_ROOT}/kubernetes_cluster/ansible"
  ansible-playbook site.yml
)

step "9/9 - Ansible: k3s (cluster HA + toate componentele)"
(
  cd "${PROJECT_ROOT}/kubernetes_cluster/k3s"
  ansible-playbook site.yml
)

step "Instalare completă. Vezi documentatie.md §14/§15 pentru comenzi de verificare și inventarul de endpoint-uri."
