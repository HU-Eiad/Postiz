#!/usr/bin/env sh
# Generate a JWT_SECRET for Postiz.
# Usage: sh scripts/gen-secret.sh
if command -v openssl >/dev/null 2>&1; then
  openssl rand -hex 48
elif command -v node >/dev/null 2>&1; then
  node -e "console.log(require('crypto').randomBytes(48).toString('hex'))"
else
  echo "Need openssl or node to generate a secret." >&2
  exit 1
fi
