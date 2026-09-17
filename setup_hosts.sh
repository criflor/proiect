#!/usr/bin/env bash
# Adaugă în /etc/hosts (mașina de control) intrările necesare pentru accesul
# din browser la toate UI-urile expuse de proiect. Rulează SEPARAT, cu sudo,
# ÎNAINTE de install.sh - install.sh rulează integral ca user normal, fără
# nicio nevoie de privilegii de root (vezi playbook-urile 13_install_argocd.yml,
# 14_install_extra_components.yml, install_signoz.yml - task-urile care
# scriau aceste linii sunt comentate acolo, înlocuite cu o validare care nu
# necesită sudo).
#
# Idempotent: nu duplică o linie deja prezentă.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "EROARE: rulează cu sudo (scrie în /etc/hosts)." >&2
  echo "  sudo ${0}" >&2
  exit 1
fi

ENTRIES=(
  "10.10.10.192 hubble.kube-dev.local"
  "10.10.10.192 demo.kube-dev.local"
  "10.10.10.20  gitlab.kube-dev.local"
  "10.10.10.192 argocd.kube-dev.local"
  "10.10.10.192 keycloak.kube-dev.local"
  "10.10.10.20  vault.kube-dev.local"
  "10.10.10.20  signoz.kube-dev.local"
)

for entry in "${ENTRIES[@]}"; do
  hostname="${entry##* }"
  if grep -qE "[[:space:]]${hostname}\$" /etc/hosts; then
    echo "deja prezent: ${hostname}"
  else
    echo "${entry}" >> /etc/hosts
    echo "adăugat:      ${hostname}"
  fi
done

echo
echo "Gata. Rulează acum ./install.sh ca user normal (fără sudo)."
