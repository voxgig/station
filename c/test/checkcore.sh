#!/bin/sh
# RUN: make check-core
#
# What the station core links, read off the built artifacts rather than
# asserted: the core archives and every binary built from them alone
# reach no crypto and no plugin, the minivault link reaches libcrypto
# and not libssl, and the env-only build carries no sekreto at all.
# Symbols are matched by EXACT name, and every read has a control that
# fails it when it parsed nothing.

set -e

BUILD=${1:-build}
SEKRETO=${2:-vendor/sekreto}

fail() {
  echo "station: $1" >&2
  exit 1
}

command -v ldd >/dev/null || {
  echo "check-core: SKIPPED - it reads ldd, which this platform does not have"
  exit 0
}

undefined() {
  nm -u "$@" | sed -n 's/^ *U //p' | sed 's/@.*//' | sort -u
}

symbols() {
  nm "$1" | awk '{print $NF}' | sed 's/@.*//' | sort -u
}

has() {
  printf '%s\n' "$2" | grep -qx "$1"
}

CORE="$BUILD/libvxstn.a $BUILD/libsekreto.a $BUILD/libvoxgigplugin.a $BUILD/libvoxgigstruct.a"

CRYPTO="EVP_CIPHER_CTX_new EVP_EncryptInit_ex EVP_DecryptInit_ex EVP_aes_256_gcm
EVP_sha256 EVP_DigestInit_ex HMAC PKCS5_PBKDF2_HMAC RAND_bytes SHA256
SSL_new SSL_connect SSL_CTX_new SSL_read SSL_write OPENSSL_init_ssl"

NETWORK="socket connect getaddrinfo gethostbyname fork vfork execve execvp
posix_spawn popen system dlopen"

PLUGINSIDE="sek_plugin_minivault sek_allplugins sek_vault_open sek_vault_create
sek_vault_get sek_unbase64 sek_uriescape sek_http sek_fetch sek_tls_open sek_runcmd
sek_sha256 sek_sigv4"

# ------------------------------------------------- the core archives

needs=$(undefined $CORE)
control=""
for name in malloc free memcpy strlen; do
  if has "$name" "$needs"; then control="$control $name"; fi
done
test -n "$control" || fail "nm read no libc name from the core archives - the read has no teeth"

reached=""
for name in $CRYPTO $NETWORK $PLUGINSIDE; do
  if has "$name" "$needs"; then reached="$reached $name"; fi
done
test -z "$reached" || fail "the core archives need$reached"
echo "core: the archives need$control from libc and none of $(echo $CRYPTO $NETWORK $PLUGINSIDE | wc -w) forbidden names"

want=$(cd "$SEKRETO/src" && ls *.c | sed 's/\.c$/.o/' | sort | tr '\n' ' ')
members=$(ar t "$BUILD/libsekreto.a" | sort | tr '\n' ' ')
test "$want" = "$members" || fail "libsekreto.a holds '$members', not sekreto's src/ alone ('$want')"
echo "core: libsekreto.a holds sekreto's src/ and no plugin"

# ------------------------------------------ binaries built on the core

for bin in "$BUILD/unit" "$BUILD/conform"; do
  libs=$(ldd "$bin")
  printf '%s\n' "$libs" | grep -q 'libc\.so' || fail "ldd named no libc for $bin - the read has no teeth"
  if printf '%s\n' "$libs" | grep -qE 'libssl|libcrypto'; then
    fail "$bin is linked against OpenSSL"
  fi
done
echo "core: unit and conform link and load with no plugin and no OpenSSL"

# --------------------------------------------------- the minivault link

libs=$(ldd "$BUILD/secrets")
printf '%s\n' "$libs" | grep -q 'libcrypto' || fail "the minivault link has no libcrypto - the read has no teeth"
if printf '%s\n' "$libs" | grep -q 'libssl'; then
  fail "the minivault link pulls libssl, and nothing in it speaks TLS"
fi
got=$(symbols "$BUILD/secrets")
has EVP_EncryptInit_ex "$got" || fail "the minivault link has no AEAD - the read has no teeth"
has PKCS5_PBKDF2_HMAC "$got" || fail "the minivault link has no PBKDF2 - the read has no teeth"
for name in SSL_new SSL_connect socket connect getaddrinfo sek_http sek_tls_open; do
  if has "$name" "$got"; then fail "the minivault link reaches the network ($name)"; fi
done
echo "minivault: libcrypto for an AEAD and a KDF, and no libssl, socket or TLS"

# ------------------------------------------------------ the env-only build

got=$(symbols "$BUILD/unit-envonly")
has vxstn_station_new "$got" || fail "nm found no vxstn_station_new in unit-envonly - the read has no teeth"
for name in sek_new sek_try host_load; do
  if has "$name" "$got"; then fail "the env-only build carries sekreto ($name)"; fi
done
echo "env-only: the payload's build carries no sekreto and no plugin host"
