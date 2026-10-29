# Read-only SSH metadata audit. Sourcing this file defines functions only.
# Call audit_ssh_configuration after the access review and before sshd -t.
# Inputs: SP_SSHCONFIG, SP_SSHDIR, SP_CRYPTO, sp_user, fail(), native().
# Output: sp_crypto_leaf, passed to the native algorithm-only content audit.
screenpunk_ssh_require_directory() {
  [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -f '%u' "$1")" = 0 ] || fail "SSH configuration directory must be an actual root-owned directory: $1"
  sp_audit_mode=$(stat -f '%Lp' "$1") || fail "Cannot inspect SSH configuration directory permissions: $1"
  case "$sp_audit_mode" in ''|*[!0-7]*) fail "Unexpected SSH configuration directory permissions: $1";; esac
  [ "$((0$sp_audit_mode & 022))" -eq 0 ] || fail "SSH configuration directory is writable by another account: $1"
}

screenpunk_ssh_require_regular_file() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -f '%u' "$1")" = 0 ] || fail "SSH configuration must be a regular root-owned file: $1"
  sp_audit_mode=$(stat -f '%Lp' "$1") || fail "Cannot inspect SSH configuration file permissions: $1"
  case "$sp_audit_mode" in ''|*[!0-7]*) fail "Unexpected SSH configuration file permissions: $1";; esac
  [ "$((0$sp_audit_mode & 022))" -eq 0 ] || fail "SSH configuration file is writable by another account: $1"
}

audit_ssh_configuration() {
  case "$SP_SSHCONFIG" in /*) ;; *) fail 'The SSH main configuration path must be absolute.';; esac
  case "$SP_SSHDIR" in /*) ;; *) fail 'The SSH include directory path must be absolute.';; esac
  case "$SP_CRYPTO" in /*) ;; *) fail 'The SSH crypto policy path must be absolute.';; esac

  screenpunk_ssh_require_directory "${SP_SSHCONFIG%/*}"
  screenpunk_ssh_require_directory "$SP_SSHDIR"
  screenpunk_ssh_require_regular_file "$SP_SSHCONFIG"
  for sp_audit_config in "$SP_SSHDIR"/*; do
    if [ ! -e "$sp_audit_config" ] && [ ! -L "$sp_audit_config" ]; then continue; fi
    screenpunk_ssh_require_regular_file "$sp_audit_config"
  done

  sp_crypto_parent=${SP_CRYPTO%/*}
  screenpunk_ssh_require_directory "$sp_crypto_parent"
  sp_crypto_leaf=$SP_CRYPTO
  if [ -L "$SP_CRYPTO" ]; then
    # Link permissions are not access controls. Trust its owner and containing
    # directories, and accept only Apple's exact one-hop relative target.
    [ "$(stat -f '%u' "$SP_CRYPTO")" = 0 ] || fail 'The macOS SSH crypto policy link must be root-owned.'
    # Read raw target bytes without readlink's display newline, then retain them
    # with a sentinel so command substitution cannot strip a target's newlines.
    sp_crypto_target=$(readlink -n "$SP_CRYPTO" && printf '.') || fail 'Cannot read the macOS SSH crypto policy link.'
    sp_crypto_expected='crypto/apple.conf.'
    [ "$sp_crypto_target" = "$sp_crypto_expected" ] || fail 'The macOS SSH crypto policy link has a custom target; only crypto/apple.conf is supported without manual review.'
    screenpunk_ssh_require_directory "$sp_crypto_parent/crypto"
    sp_crypto_leaf="$sp_crypto_parent/crypto/apple.conf"
  fi
  screenpunk_ssh_require_regular_file "$sp_crypto_leaf"

  native audit-ssh "$SP_SSHCONFIG" "$SP_SSHDIR" "$sp_user" "$SP_CRYPTO" "$sp_crypto_leaf"
}
