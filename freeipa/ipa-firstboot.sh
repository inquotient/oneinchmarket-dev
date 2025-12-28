#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ipa-firstboot][ERROR] failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# ── machine-id 보정 (/etc/machine-id -> /data/etc/machine-id)
mkdir -p /data/etc
if [ ! -f /data/etc/machine-id ]; then
  echo "[ipa-firstboot] machine-id not found, creating..."
  systemd-machine-id-setup || uuidgen | tr -d '-' > /data/etc/machine-id
fi

echo "[ipa-firstboot] machine-id: $(cat /data/etc/machine-id)"


FLAG_FILE="/data/ipa-installed.flag"

echo "[ipa-firstboot] starting, FLAG_FILE=${FLAG_FILE}"

if [ -f "${FLAG_FILE}" ]; then
  echo "[ipa-firstboot] already installed, nothing to do."
  exit 0
fi

: "${IPA_REALM:?IPA_REALM is required}"
: "${IPA_DOMAIN:?IPA_DOMAIN is required}"
: "${IPA_SERVER_HOSTNAME:?IPA_SERVER_HOSTNAME is required}"
: "${IPA_SERVER_IP:?IPA_SERVER_IP is required}"
: "${IPA_ADMIN_PASSWORD:?IPA_ADMIN_PASSWORD is required}"
: "${IPA_DM_PASSWORD:?IPA_DM_PASSWORD is required}"

echo "[ipa-firstboot] env:"
echo "  IPA_REALM=${IPA_REALM}"
echo "  IPA_DOMAIN=${IPA_DOMAIN}"
echo "  IPA_SERVER_HOSTNAME=${IPA_SERVER_HOSTNAME}"
echo "  IPA_SERVER_IP=${IPA_SERVER_IP}"

# 1) /etc/hosts 패치: Pod IP의 canonical hostname을 ipa.oneinchmarket.co.kr 로 맞추기
echo "[ipa-firstboot] patching /etc/hosts for ${IPA_SERVER_IP}"

# 기존 해당 IP 라인 삭제
sed -i "/^${IPA_SERVER_IP}[[:space:]]/d" /etc/hosts || true

SHORT_HOSTNAME="$(hostname)"
FQDN_HOSTNAME="$(hostname -f 2>/dev/null || echo "${SHORT_HOSTNAME}")"

# 새 라인 추가: canonical 을 IPA_SERVER_HOSTNAME 으로
echo "${IPA_SERVER_IP} ${IPA_SERVER_HOSTNAME} ${FQDN_HOSTNAME} ${SHORT_HOSTNAME}" > /etc/hosts

echo "[ipa-firstboot] /etc/hosts now:"
cat /etc/hosts

echo "[ipa-firstboot] running ipa-server-install ..."

ipa-server-install \
  --unattended \
  --realm="${IPA_REALM}" \
  --domain="${IPA_DOMAIN}" \
  --hostname="${IPA_SERVER_HOSTNAME}" \
  --ip-address="${IPA_SERVER_IP}" \
  --ds-password="${IPA_DM_PASSWORD}" \
  --admin-password="${IPA_ADMIN_PASSWORD}" \
  --no-host-dns \
  --setup-dns \
  --auto-forwarders

touch "${FLAG_FILE}"
echo "[ipa-firstboot] install completed, flag written."

exit 0