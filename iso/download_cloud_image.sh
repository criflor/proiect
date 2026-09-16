#!/usr/bin/env bash
# Descarcă imaginea cloud Ubuntu 24.04 ("noble") folosită ca sursă pentru
# discurile de sistem ale tuturor VM-urilor (kubernetes_cluster/terraform,
# suport_vm/terraform) - build fixat explicit (serial 20260911), nu
# "current" (care se schimbă tăcut la fiecare build nou publicat de
# Canonical) - reproductibil, verificat prin hash SHA256 oficial.
#
# Idempotent: dacă fișierul există deja și hash-ul se potrivește, nu
# descarcă nimic.
set -euo pipefail

SERIAL="20260911"
IMAGE_NAME="noble-server-cloudimg-amd64.img"
BASE_URL="https://cloud-images.ubuntu.com/noble/${SERIAL}"
EXPECTED_SHA256="612b2c0cc1bc413a6cb8c38fd611794caf0f2b436c50013d8b3794db12ad7354"

DEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_FILE="${DEST_DIR}/${IMAGE_NAME}"

verify_hash() {
  local file="$1"
  local actual
  actual="$(sha256sum "${file}" | awk '{print $1}')"
  [[ "${actual}" == "${EXPECTED_SHA256}" ]]
}

if [[ -f "${DEST_FILE}" ]] && verify_hash "${DEST_FILE}"; then
  echo "Imaginea există deja și hash-ul e corect - nimic de descărcat: ${DEST_FILE}"
  exit 0
fi

echo "Descărcare ${IMAGE_NAME} (serial ${SERIAL})..."
curl -fSL "${BASE_URL}/${IMAGE_NAME}" -o "${DEST_FILE}.tmp"

echo "Verificare hash SHA256..."
if ! verify_hash "${DEST_FILE}.tmp"; then
  echo "EROARE: hash-ul descărcat nu se potrivește cu cel așteptat." >&2
  echo "Așteptat: ${EXPECTED_SHA256}" >&2
  echo "Obținut:  $(sha256sum "${DEST_FILE}.tmp" | awk '{print $1}')" >&2
  rm -f "${DEST_FILE}.tmp"
  exit 1
fi

mv "${DEST_FILE}.tmp" "${DEST_FILE}"
echo "OK - imagine descărcată și verificată: ${DEST_FILE}"
