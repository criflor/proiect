#!/usr/bin/env bash
# Generează perechea de chei SSH dedicată acestui proiect - nu se mai
# reutilizează cheia personală din ~/.ssh (implicită înainte în toate
# playbook-urile/Terraform). Idempotent: nu suprascrie o cheie deja
# existentă. Cheile NU intră în git (vezi ssh/.gitignore).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
key_path="${script_dir}/id_ed25519"

if [[ -f "${key_path}" ]]; then
  echo "Cheia SSH există deja: ${key_path}"
  exit 0
fi

ssh-keygen -t ed25519 -f "${key_path}" -N "" -C "adm@kube-dev"
chmod 600 "${key_path}"
echo "Cheie SSH generată: ${key_path}"
