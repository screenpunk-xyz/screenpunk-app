#!/bin/sh
# Screenpunk Mac setup v5. User reviewed, optional per-user background startup. No network upload or installer.
# Generated self-contained macos.sh; audit source tools/local-agent-setup/macos/.
set -eu
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
SP_CODEX='/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'
SP_OSASCRIPT=/usr/bin/osascript
SP_LAUNCHCTL=/bin/launchctl
SP_SUDO=/usr/bin/sudo
SP_SSHD=/usr/sbin/sshd
SP_POLICY=/etc/ssh/sshd_config.d/090-screenpunk-local.conf
SP_HOSTKEY=/etc/ssh/ssh_host_ed25519_key.pub
SP_SSHCONFIG=/etc/ssh/sshd_config
SP_SSHDIR=/etc/ssh/sshd_config.d
SP_CRYPTO=/etc/ssh/crypto.conf
SP_SHA=a04752e4d46a4d89e53e6f61c59c5349a638c8ce172ffbf391fd482b4d902a4e
SP_VERSION=0.164.0-alpha.11.1
fail() { printf '%s\n' "$1" >&2; exit 1; }
# BEGIN SCREENPUNK READ-ONLY SSH AUDIT
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
# END SCREENPUNK READ-ONLY SSH AUDIT
# Optional user-consented LaunchAgent lifecycle. Functions only when embedded.
service_paths() {
  sp_service_dir="$CODEX_HOME/setup-service"
  sp_service_manifest="$sp_service_dir/install.json"
  sp_service_plist="$HOME/Library/LaunchAgents/xyz.screenpunk.local-agent.plist"
  sp_service_label='xyz.screenpunk.local-agent'
  sp_service_domain="gui/$sp_uid"
  sp_service_target="$sp_service_domain/$sp_service_label"
}
service_parent() {
  [ -d "$1" ] && [ ! -L "$1" ] || fail "Review the background-service directory: $1"
  sp_service_owner=$(stat -f '%u' "$1")
  [ "$sp_service_owner" = "$sp_uid" ] || [ "$sp_service_owner" = 0 ] || fail "Unknown background-service directory owner: $1"
  sp_service_mode=$(stat -f '%Lp' "$1")
  [ "$((0$sp_service_mode & 022))" -eq 0 ] || fail "Background-service directory is writable by another account: $1"
}
service_hash() { shasum -a 256 "$1" | awk '{print $1}'; }
service_private_control() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -f '%u:%Lp:%l' "$1")" = "$sp_uid:700:1" ] || fail 'Background management script must be an owned private regular file.'; }
service_validate_files() {
  service_paths
  private_dir "$sp_service_dir"; private_file "$sp_service_manifest"
  service_parent "$HOME/Library"; service_parent "$HOME/Library/LaunchAgents"
  service_private_control "$sp_service_dir/manage-v4.sh"; private_file "$sp_service_dir/native-v4.js"; private_file "$sp_service_dir/agent-v4.plist"; private_file "$sp_token"
  # Verify the installed parser before executing it. plutil reads only this
  # private no-secret manifest; no unverified helper is invoked for validation.
  sp_service_expected_native=$(plutil -extract nativeSHA256 raw -o - "$sp_service_manifest") || fail 'Cannot read background-service native-file ownership.'
  [ "$(service_hash "$sp_service_dir/native-v4.js")" = "$sp_service_expected_native" ] || fail 'Background-service native helper changed; no job was stopped.'
  native service-validate "$sp_service_manifest" "$HOME" "$sp_uid" "$(stat -f '%u:%Lp:%i' "$sp_token")" "$(service_hash "$sp_token")" "$(service_hash "$sp_service_dir/manage-v4.sh")" "$(service_hash "$sp_service_dir/native-v4.js")" "$(service_hash "$sp_service_dir/agent-v4.plist")" || fail 'Background-service file or credential ownership could not be verified.'
  if [ -e "$sp_service_plist" ] || [ -L "$sp_service_plist" ]; then
    private_file "$sp_service_plist"; cmp -s "$sp_service_plist" "$sp_service_dir/agent-v4.plist" || fail 'The LaunchAgent plist changed; it was not replaced or stopped.'
  fi
}
service_query_job() {
  # `launchctl print` explicitly has no stable API. `list label` returns a plist;
  # reject unavailable/unknown fields instead of guessing a job's ownership.
  if "$SP_LAUNCHCTL" list "$sp_service_label" > "$sp_session/service-job.plist" 2>/dev/null; then
    native service-job "$sp_service_manifest" "$sp_session/service-job.plist" "$sp_session" || return 1
    sp_service_job_pid=$(cat "$sp_session/service-job-pid")
    return 0
  fi
  sp_service_job_pid=0
  return 2
}
service_verify_job_process() {
  [ "$sp_service_job_pid" -gt 0 ] || return 0
  private_file "$sp_server_receipt"
  sp_service_job_start=$(process_start "$sp_service_job_pid")
  [ -n "$sp_service_job_start" ] || fail 'The background process changed during ownership review.'
  native service-ready "$sp_service_manifest" "$sp_server_receipt" "$sp_service_job_pid" "$sp_service_job_start"
}
service_wait_ready() {
  sp_service_attempt=0
  while [ "$sp_service_attempt" -lt 20 ]; do
    if service_query_job && [ "$sp_service_job_pid" -gt 0 ] && [ -f "$sp_server_receipt" ]; then
      sp_service_job_start=$(process_start "$sp_service_job_pid")
      if [ -n "$sp_service_job_start" ] && native service-ready "$sp_service_manifest" "$sp_server_receipt" "$sp_service_job_pid" "$sp_service_job_start" 2>/dev/null; then
        sp_service_listener=$(lsof -nP -a -p "$sp_service_job_pid" -iTCP:4500 -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p' || :)
        sp_service_all=$(lsof -nP -a -iTCP:4500 -sTCP:LISTEN -t 2>/dev/null | sort -u || :)
        if [ "$sp_service_listener" = '127.0.0.1:4500' ] && [ "$sp_service_all" = "$sp_service_job_pid" ]; then
          sp_pid=$sp_service_job_pid; sp_start=$sp_service_job_start; sp_server_lifecycle=background
          native service-state "$sp_service_manifest" enabled
          native service-status "$sp_service_manifest" ready
          return 0
        fi
      fi
    fi
    sleep 1; sp_service_attempt=$((sp_service_attempt + 1))
  done
  return 1
}
service_prepare_install() {
  service_paths
  [ -e "$HOME/Library" ] || mkdir "$HOME/Library"
  service_parent "$HOME/Library"
  [ -e "$HOME/Library/LaunchAgents" ] || mkdir "$HOME/Library/LaunchAgents"
  service_parent "$HOME/Library/LaunchAgents"
  if "$SP_LAUNCHCTL" list "$sp_service_label" > /dev/null 2>&1; then
    [ -f "$sp_service_manifest" ] && [ ! -L "$sp_service_manifest" ] || fail 'An unknown job already uses the Screenpunk LaunchAgent label. It was not stopped.'
  fi
  private_dir "$sp_service_dir"
  if [ -e "$sp_service_manifest" ] || [ -L "$sp_service_manifest" ]; then private_file "$sp_service_manifest"; fi
  native service-plist "$sp_session/service.plist" "$HOME" "$sp_uid"
  native service-prepare "$sp_service_manifest" "$sp_session" "$HOME" "$sp_uid" "$(stat -f '%u:%Lp:%i' "$sp_token")" "$(service_hash "$sp_token")" "$SP_SHA" "$(service_hash "$sp_session/service-control.sh")" "$(service_hash "$sp_session/native.js")" "$(service_hash "$sp_session/service.plist")"
  # The persistent service journal references this exact token even on a failed
  # first attempt. Retain it for resumption; never rotate credentials on retry.
  sp_token_created=0
  # Existing files are verified before native code fills only missing paths.
  for sp_service_pair in 'manage-v4.sh:700' 'native-v4.js:600' 'agent-v4.plist:600'; do
    sp_service_name=${sp_service_pair%:*}; sp_service_permission=${sp_service_pair#*:}
    if [ -e "$sp_service_dir/$sp_service_name" ] || [ -L "$sp_service_dir/$sp_service_name" ]; then
      if [ "$sp_service_permission" = 700 ]; then service_private_control "$sp_service_dir/$sp_service_name"; else private_file "$sp_service_dir/$sp_service_name"; fi
      case "$sp_service_name" in manage-v4.sh) sp_service_source="$sp_session/service-control.sh";; native-v4.js) sp_service_source="$sp_session/native.js";; *) sp_service_source="$sp_session/service.plist";; esac
      cmp -s "$sp_service_dir/$sp_service_name" "$sp_service_source" || fail 'Existing background-service source changed. Review it; no file was overwritten.'
    fi
  done
  if [ -e "$sp_service_plist" ] || [ -L "$sp_service_plist" ]; then private_file "$sp_service_plist"; cmp -s "$sp_service_plist" "$sp_session/service.plist" || fail 'An unknown LaunchAgent plist was not overwritten.'; fi
  native service-files "$sp_service_manifest" "$sp_session"
  service_validate_files
}
service_bootout_owned() {
  service_validate_files
  if service_query_job; then
    service_verify_job_process || return 1
    "$SP_LAUNCHCTL" bootout "$sp_service_target" || return 1
    if "$SP_LAUNCHCTL" list "$sp_service_label" >/dev/null 2>&1; then return 1; fi
  else
    sp_service_query_status=$?
    [ "$sp_service_query_status" -eq 2 ] || return 1
  fi
}
service_start_background() {
  service_prepare_install
  sp_service_loaded_before=0
  if service_query_job; then
    service_verify_job_process; sp_service_loaded_before=1
    if service_wait_ready; then return 0; fi
    fail 'The existing background job is not ready. Review status; it was not restarted automatically.'
  else
    [ "$?" -eq 2 ] || fail 'The existing LaunchAgent job could not be verified.'
  fi
  if [ -n "$sp_pid" ]; then
    native consent "Move the verified Screenpunk foreground server (PID $sp_pid) to background startup? Continue briefly disconnects this iPad, stops only that exact owned server, and starts the same pinned server with the unchanged credential. If background startup fails, setup will try to restore it in this Terminal. Cancel leaves the running connection unchanged."
    private_file "$sp_token"; private_file "$sp_server_receipt"
    native server-read "$sp_server_receipt" "$sp_session" || fail 'Cannot recheck the foreground ownership receipt.'
    [ "$(cat "$sp_session/server-pid")" = "$sp_pid" ] && [ "$(cat "$sp_session/server-start")" = "$sp_start" ] && [ "$(cat "$sp_session/server-tokenIdentity")" = "$(stat -f '%u:%Lp:%i' "$sp_token")" ] && [ "$(cat "$sp_session/server-tokenSHA256")" = "$(service_hash "$sp_token")" ] || fail 'Foreground credential ownership changed during review; nothing was stopped.'
    sp_migration_token_identity=$(stat -f '%u:%Lp:%i' "$sp_token"); sp_migration_token_hash=$(service_hash "$sp_token")
    [ "$(process_start "$sp_pid")" = "$sp_start" ] || fail 'The foreground process changed during review; nothing was stopped.'
    [ "$(lsof -nP -a -p "$sp_pid" -iTCP:4500 -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p')" = '127.0.0.1:4500' ] || fail 'The foreground listener changed during review; nothing was stopped.'
    sp_service_migrated=1
    kill "$sp_pid" || fail 'Could not stop the exact foreground server after approval.'
    sp_service_stop_attempt=0
    while [ -n "$(process_start "$sp_pid")" ] && [ "$sp_service_stop_attempt" -lt 20 ]; do sleep 0.1; sp_service_stop_attempt=$((sp_service_stop_attempt + 1)); done
    [ -z "$(process_start "$sp_pid")" ] || fail 'The approved foreground server did not stop; background startup was not attempted.'
    sp_pid=''; sp_start=''
  fi
  if [ -f "$sp_server_receipt" ]; then cp "$sp_server_receipt" "$sp_session/server-original.json"; native sync "$sp_session/server-original.json"; fi
  # A declined migration must never leave an autoload plist behind.
  if "$SP_LAUNCHCTL" list "$sp_service_label" >/dev/null 2>&1; then fail 'A job appeared during background review. It was not stopped; setup will restore the approved foreground connection if safe.'; fi
  sp_service_publication=$(native service-copy-plist "$sp_service_manifest") || fail 'Cannot safely publish the LaunchAgent plist.'
  if [ "$sp_service_publication" = created ]; then sp_service_plist_published=1; fi
  native service-status "$sp_service_manifest" starting
  sp_service_bootstrapped=0
  if "$SP_LAUNCHCTL" bootstrap "$sp_service_domain" "$sp_service_plist"; then sp_service_bootstrapped=1; sp_service_started_by_setup=1; fi
  if [ "$sp_service_bootstrapped" -eq 1 ] && service_wait_ready; then return 0; fi
  printf '%s\n' 'Background startup failed. Preserving the saved credential and restoring foreground operation.' >&2
  if ! service_bootout_owned; then fail 'Background job cleanup could not be verified. Saved credentials remain intact; review the service before starting another server.'; fi
  if [ "$sp_service_plist_published" -eq 1 ] && [ -e "$sp_service_plist" ]; then private_file "$sp_service_plist"; cmp -s "$sp_service_plist" "$sp_service_dir/agent-v4.plist" || fail 'Service plist changed during recovery.'; rm -f "$sp_service_plist"; fi
  native service-state "$sp_service_manifest" failed
  native service-status "$sp_service_manifest" startup-failed
  sp_server_lifecycle=foreground; sp_service_started_by_setup=0; sp_pid=''; sp_start=''
  return 0
}
service_run() {
  service_validate_files
  native service-status "$sp_service_manifest" preflight
  if ! { [ -x "$SP_CODEX" ] && [ "$(service_hash "$SP_CODEX")" = "$SP_SHA" ] && [ "$("$SP_CODEX" --version | awk '{print $NF}')" = "$SP_VERSION" ]; }; then
    native service-status "$sp_service_manifest" pinned-build-changed
    fail 'The pinned Codex build changed; background startup stopped for review.'
  fi
  [ "$(wc -c < "$sp_token" | tr -d '[:space:]')" -eq 65 ] && LC_ALL=C grep -Eq '^[0-9a-f]{64}$' "$sp_token" || fail 'The private saved credential changed.'
  [ ! -e "$sp_service_dir/instance.lock" ] || private_file "$sp_service_dir/instance.lock"
  exec 7<> "$sp_service_dir/instance.lock"
  /usr/bin/lockf -t 0 7 || fail 'Another background server instance owns the service lock.'
  [ -z "$(lsof -nP -a -iTCP:4500 -sTCP:LISTEN -t 2>/dev/null || :)" ] || fail 'Port 4500 already has a listener; background startup did not stop it.'
  native service-status "$sp_service_manifest" launching
  sp_start=$(process_start "$$"); [ -n "$sp_start" ] || fail 'Cannot record the background process start identity.'
  native service-server-write "$sp_service_manifest" "$sp_server_receipt" "$$" "$sp_start"
  cd "$CODEX_HOME/workspace"
  exec "$SP_CODEX" -c features.shell_tool=false -c features.unified_exec=false -c features.apps=false -c features.plugins=false -c features.hooks=false -c features.browser_use=false -c features.browser_use_external=false -c features.computer_use=false -c features.in_app_browser=false -c features.image_generation=false -c features.view_image=false -c features.multi_agent=false -c features.skill_search=false -c features.skill_mcp_dependency_install=false -c features.workspace_dependencies=false -c 'web_search="disabled"' -c project_doc_max_bytes=0 app-server --listen ws://127.0.0.1:4500 --ws-auth capability-token --ws-token-file "$sp_token"
}
service_manage() {
  service_validate_files
  case "$1" in
    status) if service_query_job; then service_verify_job_process; printf 'Screenpunk background job is loaded (PID %s). Mac must be logged in, awake and reachable.\n' "$sp_service_job_pid"; else [ "$?" -eq 2 ] || fail 'Unknown LaunchAgent job.'; printf '%s\n' 'Screenpunk background job is not loaded.'; fi;;
    start) if service_query_job; then service_verify_job_process; "$SP_LAUNCHCTL" kickstart "$sp_service_target"; else [ "$?" -eq 2 ] || fail 'Unknown LaunchAgent job.'; if [ ! -e "$sp_service_plist" ]; then native service-copy-plist "$sp_service_manifest"; fi; "$SP_LAUNCHCTL" bootstrap "$sp_service_domain" "$sp_service_plist"; fi; service_wait_ready || fail 'Background start failed; inspect local status and client connection diagnostics.';;
    restart) service_bootout_owned || fail 'Cannot verify the owned job for restart.'; if [ ! -e "$sp_service_plist" ]; then native service-copy-plist "$sp_service_manifest"; fi; "$SP_LAUNCHCTL" bootstrap "$sp_service_domain" "$sp_service_plist"; service_wait_ready || fail 'Background restart failed; saved credentials remain unchanged.';;
    uninstall) service_bootout_owned || fail 'Cannot verify the owned job for uninstall.'; native service-state "$sp_service_manifest" uninstalled; native service-status "$sp_service_manifest" uninstalled; rm -f "$sp_service_plist" "$sp_service_dir/manage-v4.sh" "$sp_service_dir/native-v4.js" "$sp_service_dir/agent-v4.plist"; printf '%s\n' 'Background startup removed. SSH grants, saved credential, Codex home and paired iPad settings were retained.';;
    *) fail 'Usage: manage-v4.sh status|start|restart|uninstall';;
  esac
}

# Reusable gated foreground launch, including restoration after an approved migration.
# Does not create/rotate credentials, stop listeners, or invoke a model request.
service_start_foreground() {
  [ -x "$SP_CODEX" ] && [ "$(service_hash "$SP_CODEX")" = "$SP_SHA" ] && [ "$("$SP_CODEX" --version | awk '{print $NF}')" = "$SP_VERSION" ] || return 1
  private_file "$sp_token"
  [ -z "$(lsof -nP -a -iTCP:4500 -sTCP:LISTEN -t 2>/dev/null || :)" ] || return 1
  if [ "$sp_service_migrated" -eq 1 ]; then
    [ "$(stat -f '%u:%Lp:%i' "$sp_token")" = "$sp_migration_token_identity" ] && [ "$(service_hash "$sp_token")" = "$sp_migration_token_hash" ] || return 1
  fi
  rm -f "$sp_session/start-server"
  (
    sp_gate_count=0
    while [ ! -f "$sp_session/start-server" ]; do [ "$sp_gate_count" -lt 100 ] || exit 1; sleep 0.1; sp_gate_count=$((sp_gate_count + 1)); done
    cd "$CODEX_HOME/workspace"
    exec "$SP_CODEX" -c features.shell_tool=false -c features.unified_exec=false -c features.apps=false -c features.plugins=false -c features.hooks=false -c features.browser_use=false -c features.browser_use_external=false -c features.computer_use=false -c features.in_app_browser=false -c features.image_generation=false -c features.view_image=false -c features.multi_agent=false -c features.skill_search=false -c features.skill_mcp_dependency_install=false -c features.workspace_dependencies=false -c 'web_search="disabled"' -c project_doc_max_bytes=0 app-server --listen ws://127.0.0.1:4500 --ws-auth capability-token --ws-token-file "$sp_token"
  ) 9>&- >/dev/null 2>&1 &
  sp_pid=$!; sp_started=1; sp_foreground_ready=0; sp_server_lifecycle=foreground; sp_start=$(process_start "$sp_pid")
  [ -n "$sp_start" ] || return 1
  if [ -f "$sp_server_receipt" ] && [ ! -f "$sp_session/server-original.json" ]; then cp "$sp_server_receipt" "$sp_session/server-original.json"; native sync "$sp_session/server-original.json" || return 1; fi
  native server-write "$sp_server_receipt" "$sp_pid" "$sp_start" "$(stat -f '%u:%Lp:%i' "$sp_token")" "$(service_hash "$sp_token")" "$SP_SHA" || return 1
  sp_newreceipt_hash=$(service_hash "$sp_server_receipt")
  : > "$sp_session/start-server"
  sp_attempt=0
  while [ "$sp_attempt" -lt 20 ]; do
    [ "$(process_start "$sp_pid")" = "$sp_start" ] || return 1
    sp_ready=$(lsof -nP -a -p "$sp_pid" -iTCP:4500 -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p' || :)
    [ "$sp_ready" = '127.0.0.1:4500' ] && break
    sleep 1; sp_attempt=$((sp_attempt + 1))
  done
  [ "$sp_ready" = '127.0.0.1:4500' ] || return 1
  sp_foreground_ready=1
}

# Only for a foreground child created by this exact setup process.
service_terminate_owned_child() {
  if [ -n "$1" ] && [ "$(process_start "$1")" = "$2" ]; then
    kill "$1" 2>/dev/null || :
    sp_terminate_count=0
    while [ "$(process_start "$1")" = "$2" ] && [ "$sp_terminate_count" -lt 20 ]; do sleep 0.1; sp_terminate_count=$((sp_terminate_count + 1)); done
    if [ "$(process_start "$1")" = "$2" ]; then kill -KILL "$1" 2>/dev/null || :; fi
  fi
  wait "$1" 2>/dev/null || :
}
# Setup-only V5 repair. Never embed this library in the unchanged V4 controller.
service_upgrade_v4_if_needed() {
  service_paths
  if [ ! -e "$sp_service_manifest" ] && [ ! -L "$sp_service_manifest" ]; then return 0; fi
  sp_upgrade_state=$(native upgrade-service-v4 inspect "$sp_service_manifest" "$HOME" "$sp_uid" "$sp_session/native.js" "$sp_session/service-control.sh") || fail 'The installed background helper could not be verified. Its running server was not changed.'
  case "$sp_upgrade_state" in
    current) return 0;;
    required)
      native consent 'Repair the verified Screenpunk background helper from setup v4? Continue preserves its exact original helper and ownership receipt, then updates only the native parser and its recorded hash. The running server is not stopped, restarted or bootstrapped. Your saved credential, SSH access, startup controller and LaunchAgent plist remain unchanged. Cancel leaves this installation unchanged.' || return 1
      native upgrade-service-v4 prepare "$sp_service_manifest" "$HOME" "$sp_uid" "$sp_session/native.js" "$sp_session/service-control.sh" >/dev/null || fail 'Background helper repair preparation did not complete. The running server was not changed.';;
    resume) :;;
    *) fail 'Unknown background helper repair state. No service was changed.';;
  esac
  native upgrade-service-v4 apply "$sp_service_manifest" "$HOME" "$sp_uid" "$sp_session/native.js" "$sp_session/service-control.sh" >/dev/null || fail 'Background helper repair is incomplete. Its private journal preserves the originals for retry; no server was restarted or credential rotated.'
}
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || fail 'This reviewed setup supports Apple Silicon macOS only.'
sp_os=$(sw_vers -productVersion); [ "${sp_os%%.*}" -ge 13 ] || fail 'macOS 13 or later is required.'
[ -x "$SP_CODEX" ] || fail 'Install the supported ChatGPT Mac app; the bundled Codex was not found.'
[ "$(shasum -a 256 "$SP_CODEX" | awk '{print $1}')" = "$SP_SHA" ] || fail 'Codex binary changed. Use the reviewed supported build; no software was installed or downgraded.'
[ "$("$SP_CODEX" --version | awk '{print $NF}')" = "$SP_VERSION" ] || fail 'Codex version is unsupported.'
sp_uid=$(id -u); sp_user=$(id -un)
case "$sp_user" in ''|-*|*[!A-Za-z0-9._-]*) fail 'Unsupported account short name.';; esac
[ "${#sp_user}" -le 64 ] || fail 'Unsupported account short name.'
case "$HOME" in /*) ;; *) fail 'An absolute Mac home directory is required.';; esac
[ "$(cd "$HOME" && pwd -P)" = "$HOME" ] || fail 'The home directory must not contain symbolic links.'
private_dir() {
  [ ! -L "$1" ] || fail 'A Screenpunk directory is a symbolic link; review it before continuing.'
  if [ -e "$1" ]; then
    [ -d "$1" ] && [ "$(stat -f '%u:%Lp' "$1")" = "$sp_uid:700" ] || fail 'Existing Screenpunk directories must be owned by this account with mode 700. Review permissions; setup will not repair unknown files.'
  else mkdir "$1"; fi
}
private_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -f '%u:%Lp:%l' "$1")" = "$sp_uid:600:1" ] || fail 'Expected a private, singly linked, account-owned Screenpunk file.'; }
if [ -e "$HOME/.codex" ] || [ -L "$HOME/.codex" ]; then
  [ -d "$HOME/.codex" ] && [ ! -L "$HOME/.codex" ] && [ "$(stat -f '%u' "$HOME/.codex")" = "$sp_uid" ] || fail 'Review the Codex home directory ownership/symlink.'
  sp_parentmode=$(stat -f '%Lp' "$HOME/.codex"); [ "$((0$sp_parentmode & 022))" -eq 0 ] || fail 'Codex home must not be writable by other accounts.'
else mkdir "$HOME/.codex"; fi
export CODEX_HOME="$HOME/.codex/screenpunk-local"
private_dir "$CODEX_HOME"; private_dir "$CODEX_HOME/workspace"; private_dir "$CODEX_HOME/setup-receipts"
for sp_sensitive in auth.json config.toml; do [ ! -L "$CODEX_HOME/$sp_sensitive" ] || fail 'Dedicated Codex authentication/configuration must not link to another home.'; done
# Kernel-held descriptor lease: no stale directory to delete after SIGKILL/power loss.
sp_lock="$CODEX_HOME/.setup.lock"
if [ -e "$sp_lock" ] || [ -L "$sp_lock" ]; then private_file "$sp_lock"; fi
exec 9<> "$sp_lock"
/usr/bin/lockf -t 0 9 || fail 'Another setup is running. Wait for its connection display to close, then retry.'
sp_lock_held=1
sp_session=$(mktemp -d "$CODEX_HOME/setup-session.XXXXXX")
sp_policy_added=0; sp_key_added=0; sp_token_created=0; sp_started=0; sp_handoff=0; sp_pid=''; sp_start=''
sp_token="$CODEX_HOME/transport-token"; sp_server_receipt="$CODEX_HOME/setup-server.json"; sp_token_receipt="$CODEX_HOME/setup-token.json"
sp_keys="$HOME/.ssh/authorized_keys"
sp_server_lifecycle=foreground; sp_service_started_by_setup=0; sp_service_migrated=0; sp_service_plist_published=0; sp_foreground_ready=0
sp_migration_token_identity=''; sp_migration_token_hash=''
sp_policyhash=''; sp_keyline=''; sp_newreceipt_hash=''; sp_tokenidentity=''; sp_tokenhash=''; sp_tokenreceipt_hash=''
process_start() { ps -p "$1" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//'; }
cleanup() {
  sp_status=$?
  set +e
  sp_restore_failed=0
  trap - EXIT
  # Cleanup can itself restore a foreground child. Cover that startup window,
  # not only the later wait, without recursing into the main EXIT handler.
  cleanup_interrupted() {
    trap - HUP INT TERM
    if [ "$sp_started" -eq 1 ]; then service_terminate_owned_child "$sp_pid" "$sp_start"; fi
    rm -f "$sp_session/private-reply.json" "$sp_session/connection.png" "$sp_session/new-token"
    if [ "$sp_lock_held" -eq 1 ]; then exec 9>&-; fi
    printf '%s\n' 'Setup cleanup was interrupted. Saved credentials and ownership evidence were retained for review.' >&2
    exit 130
  }
  trap cleanup_interrupted HUP INT TERM
  # A verified migrated service preserves the old pair even if a new reply fails.
  sp_keep_restored_foreground=0
  if [ "$sp_handoff" -eq 0 ] && [ "$sp_service_migrated" -eq 1 ] && [ "$sp_server_lifecycle" = background ] && service_query_job && service_verify_job_process && [ "$(lsof -nP -a -p "$sp_service_job_pid" -iTCP:4500 -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p')" = '127.0.0.1:4500' ]; then
    sp_service_started_by_setup=0; sp_service_plist_published=0; sp_newreceipt_hash=''; sp_policy_added=0
    printf '%s\n' 'The verified background server remains enabled for the existing connection. This new pairing did not complete.' >&2
  fi
  if [ "$sp_handoff" -eq 0 ] && [ "$sp_service_migrated" -eq 1 ] && [ "$sp_server_lifecycle" = foreground ] && [ "$sp_foreground_ready" -eq 1 ]; then
    sp_keep_restored_foreground=1; sp_newreceipt_hash=''
  fi
  if [ "$sp_started" -eq 1 ] && [ "$sp_keep_restored_foreground" -eq 0 ] && [ "$(process_start "$sp_pid")" = "$sp_start" ]; then service_terminate_owned_child "$sp_pid" "$sp_start"; fi
  if [ "$sp_handoff" -eq 0 ]; then
    if [ "$sp_service_started_by_setup" -eq 1 ]; then
      if service_bootout_owned; then
        sp_service_started_by_setup=0
        if [ "$sp_service_migrated" -eq 1 ]; then sp_server_lifecycle=foreground; sp_foreground_ready=0; sp_pid=''; sp_start=''; fi
      else
        printf '%s\n' 'The new background job could not be safely unloaded. Saved credential and ownership receipt were retained for review.' >&2
        sp_token_created=0; sp_newreceipt_hash=''; sp_service_plist_published=0
      fi
    fi
    if [ "$sp_service_plist_published" -eq 1 ] && [ -f "$sp_service_plist" ] && [ ! -L "$sp_service_plist" ] && cmp -s "$sp_service_plist" "$sp_service_dir/agent-v4.plist"; then
      rm -f "$sp_service_plist"; native service-state "$sp_service_manifest" failed
    fi
    if [ "$sp_service_migrated" -eq 1 ] && [ "$sp_keep_restored_foreground" -eq 0 ] && [ "$sp_service_started_by_setup" -eq 0 ] && [ "$sp_server_lifecycle" != background ]; then
      sp_pid=''; sp_start=''
      if service_start_foreground; then sp_keep_restored_foreground=1; sp_newreceipt_hash=''; else
        sp_restore_failed=1
        if [ "$sp_started" -eq 1 ]; then service_terminate_owned_child "$sp_pid" "$sp_start"; fi
        printf '%s\n' 'Saved credentials and the receipt backup were retained, but foreground restoration needs review; no unknown listener was stopped.' >&2
      fi
    fi
    if [ "$sp_key_added" -eq 1 ] && [ -f "$sp_keys" ] && [ ! -L "$sp_keys" ]; then
      grep -Fvx -- "$sp_keyline" "$sp_keys" > "$sp_session/keys.rollback" || [ "$?" -eq 1 ]
      cat "$sp_session/keys.rollback" > "$sp_keys"
    fi
    if [ "$sp_policy_added" -eq 1 ] && [ ! -L "$SP_POLICY" ] && [ -f "$SP_POLICY" ] && [ "$(shasum -a 256 "$SP_POLICY" | awk '{print $1}')" = "$sp_policyhash" ]; then "$SP_SUDO" rm -f "$SP_POLICY" || :; fi
    if [ "$sp_token_created" -eq 1 ] && [ -f "$sp_token" ] && [ ! -L "$sp_token" ] && [ "$(stat -f '%u:%Lp:%i' "$sp_token")" = "$sp_tokenidentity" ] && [ "$(shasum -a 256 "$sp_token" | awk '{print $1}')" = "$sp_tokenhash" ]; then
      rm -f "$sp_token"
      if [ -n "$sp_tokenreceipt_hash" ] && [ -f "$sp_token_receipt" ] && [ ! -L "$sp_token_receipt" ] && [ "$(shasum -a 256 "$sp_token_receipt" | awk '{print $1}')" = "$sp_tokenreceipt_hash" ]; then rm -f "$sp_token_receipt"; fi
    fi
    if [ "$sp_started" -eq 1 ] && [ -n "$sp_newreceipt_hash" ] && [ -f "$sp_server_receipt" ] && [ ! -L "$sp_server_receipt" ] && [ "$(shasum -a 256 "$sp_server_receipt" | awk '{print $1}')" = "$sp_newreceipt_hash" ]; then
      if [ -f "$sp_session/server-original.json" ]; then native restore-server "$sp_session/server-original.json" "$sp_server_receipt" || sp_restore_failed=1; else rm -f "$sp_server_receipt"; fi
    fi
  fi
  rm -f "$sp_session/native.js" "$sp_session/request-path" "$sp_session/request.json" "$sp_session/key.pub" "$sp_session/key-digest" "$sp_session/policy" "$sp_session/authorized-line" "$sp_session/keys.rollback" "$sp_session/private-reply.json" "$sp_session/connection.png" "$sp_session/metadata.json" "$sp_session/server-pid" "$sp_session/server-start" "$sp_session/server-tokenIdentity" "$sp_session/server-tokenSHA256" "$sp_session/server-serverLifecycle" "$sp_session/new-token" "$sp_session/start-server" "$sp_session/.screenpunk-session.json" "$sp_session/service-control.sh" "$sp_session/service.plist" "$sp_session/service-job.plist" "$sp_session/service-job-pid"
  if [ "$sp_restore_failed" -eq 0 ]; then rm -f "$sp_session/server-original.json"; fi
  rmdir "$sp_session" 2>/dev/null || :
  if [ "$sp_lock_held" -eq 1 ]; then exec 9>&-; fi
  if [ "$sp_keep_restored_foreground" -eq 1 ]; then
    printf '%s\n' 'The existing connection was restored in this Terminal. Keep it open; the new pairing did not complete.' >&2
    stop_restored_foreground() {
      trap - HUP INT TERM
      service_terminate_owned_child "$sp_pid" "$sp_start"
      exit "$sp_status"
    }
    trap stop_restored_foreground HUP INT TERM
    wait "$sp_pid" 2>/dev/null || :
    trap - HUP INT TERM
  fi
  exit "$sp_status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
cat > "$sp_session/native.js" <<'SCREENPUNK_NATIVE_JS'
/* Embedded in macos.sh by generate.mjs. Native Apple frameworks only; no network APIs. */
ObjC.import('Foundation');
// macOS fsync + F_FULLFSYNC (fcntl command 51) order file/rename metadata before grants/exec.
ObjC.bindFunction('open',['int',['char *','int']]);
ObjC.bindFunction('fsync',['int',['int']]);
ObjC.bindFunction('fcntl',['int',['int','int','int']]);
ObjC.bindFunction('close',['int',['int']]);
ObjC.bindFunction('renamex_np',['int',['char *','char *','int']]);
ObjC.bindFunction('unlink',['int',['char *']]);
function syncDirectory(path) { var fd=$.open(path,0); if(fd<0) fail('Cannot open setup directory for durability'); try { if($.fsync(fd)!==0) fail('Cannot synchronize setup directory'); } finally { $.close(fd); } }
function syncPath(path) { var fd=$.open(path,0); if(fd<0) fail('Cannot open setup file for durability'); try { if($.fsync(fd)!==0) fail('Cannot synchronize setup file'); syncDirectory(path.slice(0,path.lastIndexOf('/')) || '/'); if($.fcntl(fd,51,0)!==0) fail('Cannot establish durable setup ordering on this filesystem'); } finally { $.close(fd); } }

function utf8Bytes(s) { return unescape(encodeURIComponent(s)).length; }
function fail(message) { throw new Error(message); }
function bounded(s, max) { return typeof s === 'string' && utf8Bytes(s) > 0 && utf8Bytes(s) <= max && !/[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]/.test(s); }
function b64decode(s) {
    var alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/', bits = 0, value = 0, bytes = [];
    for (var i = 0; i < s.length; i++) { var n = alphabet.indexOf(s[i]); if (n < 0) fail('Invalid base64'); value = (value << 6) | n; bits += 6; if (bits >= 8) { bits -= 8; bytes.push((value >> bits) & 255); } }
    if (bits && (value & ((1 << bits) - 1))) fail('Noncanonical base64');
    return bytes;
}
function validDigest(s) { return typeof s === 'string' && /^SHA256:[A-Za-z0-9+/]{43}$/.test(s) && b64decode(s.slice(7)).length === 32; }
function exactObject(text, keys, limit) {
    if (utf8Bytes(text) > limit) fail('Setup request is too large');
    var value = JSON.parse(text);
    if (!value || Array.isArray(value) || Object.keys(value).sort().join('|') !== keys.slice().sort().join('|')) fail('Unexpected setup request fields');
    // The schema is flat. Count decoded keys before JSON.parse can discard duplicates.
    var matches = text.match(/"(?:[^"\\]|\\.)*"\s*:/g) || [], seen = {};
    matches.forEach(function (m) { var k = JSON.parse(m.replace(/\s*:$/, '')); if (seen[k]) fail('Duplicate setup request field'); seen[k] = true; });
    if (matches.length !== keys.length) fail('Duplicate or nested setup request field');
    return value;
}
function validateRequest(text, now) {
    var keys = ['type','schemaVersion','pairingID','nonce','issuedAt','expiresAt','publicKeyOpenSSH','publicKeySHA256','deviceName','codexVersion','protocolProfile'];
    var r = exactObject(text, keys, 8192);
    if (r.type !== 'screenpunk.pairing-request.v1' || r.schemaVersion !== 1 || r.codexVersion !== '0.164.0-alpha.11.1' || r.protocolProfile !== 'macos-codex-0.164.0-alpha.11.1') fail('Unsupported setup request or Codex profile');
    if (typeof r.pairingID !== 'string' || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(r.pairingID) || typeof r.nonce !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(r.nonce) || b64decode(r.nonce.replace(/-/g,'+').replace(/_/g,'/')).length !== 32 || !validDigest(r.publicKeySHA256)) fail('Invalid setup request identity');
    if (!Number.isSafeInteger(r.issuedAt) || !Number.isSafeInteger(r.expiresAt) || r.issuedAt <= 0 || r.expiresAt <= r.issuedAt || r.expiresAt - r.issuedAt > 1800000) fail('Invalid setup request lifetime');
    if (r.issuedAt > now + 120000) fail('Mac and iPad clocks differ; correct the clock and share a new request');
    if (r.expiresAt < now - 120000) fail('Setup request expired; share a new request from iPad');
    if (!bounded(r.deviceName, 128) || !bounded(r.publicKeyOpenSSH, 512)) fail('Invalid device label or public key');
    var parts = r.publicKeyOpenSSH.split(/ +/), blob;
    if (parts.length < 2 || parts[0] !== 'ssh-ed25519' || !/^[A-Za-z0-9+/]{68}$/.test(parts[1])) fail('Expected an Ed25519 iPad public key');
    blob = b64decode(parts[1]);
    if (blob.length !== 51 || blob.slice(0,19).join(',') !== [0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32].join(',')) fail('Invalid Ed25519 key encoding');
    r.publicKeyOpenSSH = 'ssh-ed25519 ' + parts[1]; // Never retain supplied key options/comments.
    return r;
}
function read(path) { var error = Ref(), value = $.NSString.stringWithContentsOfFileEncodingError($(path), $.NSUTF8StringEncoding, error); if (!value) fail('Cannot read local setup file'); return ObjC.unwrap(value); }
function write(path, text) { if (!$(text).writeToFileAtomicallyEncodingError($(path), true, $.NSUTF8StringEncoding, null)) fail('Cannot write private setup material'); $.NSFileManager.defaultManager.setAttributesOfItemAtPathError($({NSFilePosixPermissions: 384}), $(path), null); syncPath(path); }
function field(dir, name, value) { write(dir + '/' + name, String(value)); }
function nativeApp() { var app = Application.currentApplication(); app.includeStandardAdditions = true; return app; }
function makeReply(r, fields, now) {
    var host = fields.host, username = fields.username, workspace = fields.macWorkspace;
    if (!bounded(fields.computerName,128) || typeof host !== 'string' || !/^[A-Za-z0-9.:%_-]{1,253}$/.test(host) || host[0] === '-' || !/^[A-Za-z0-9._-]{1,64}$/.test(username) || username[0] === '-' || !bounded(workspace,1024) || workspace[0] !== '/' || workspace === '/' || /\/\//.test(workspace) || workspace.split('/').some(function(p){return p === '.' || p === '..';}) || !validDigest(fields.hostKeySHA256) || !/^[a-f0-9]{64}$/.test(fields.appServerToken)) fail('Computer metadata cannot be safely paired');
    var result = {type:'screenpunk.pairing-reply.v1',schemaVersion:1,pairingID:r.pairingID,nonce:r.nonce,publicKeySHA256:r.publicKeySHA256,issuedAt:now,expiresAt:now+300000,computerName:fields.computerName,host:host,sshPort:22,username:username,hostKeySHA256:fields.hostKeySHA256,appServerPort:4500,macWorkspace:workspace,codexVersion:r.codexVersion,protocolProfile:r.protocolProfile,appServerToken:fields.appServerToken};
    if (fields.serverLifecycle === 'background') result.serverLifecycle='background';
    else if (fields.serverLifecycle !== undefined && fields.serverLifecycle !== 'foreground') fail('Invalid local server lifecycle');
    return result;
}
function renderQR(reply, path) {
    ObjC.import('Cocoa'); ObjC.import('CoreImage');
    var data = $(reply).dataUsingEncoding($.NSUTF8StringEncoding), filter = $.CIFilter.filterWithName('CIQRCodeGenerator');
    filter.setValueForKey(data,'inputMessage'); filter.setValueForKey($('M'),'inputCorrectionLevel');
    var qr = filter.outputImage, extent = qr.extent;
    var white = $.CIImage.imageWithColor($.CIColor.colorWithRedGreenBlue(1,1,1)).imageByCroppingToRect($.NSMakeRect(-4,-4,extent.size.width+8,extent.size.height+8));
    qr = qr.imageByCompositingOverImage(white);
    var scale = $.NSAffineTransform.transform; scale.scaleBy(8);
    filter = qr.imageByApplyingFilterWithInputParameters('CIAffineTransform', $({inputTransform:scale}));
    var ci = filter, context = $.CIContext.contextWithOptions($({})), cg = context.createCGImageFromRect(ci,ci.extent), bitmap = $.NSBitmapImageRep.alloc.initWithCGImage(cg);
    if (!bitmap.representationUsingTypeProperties($.NSPNGFileType,$({})).writeToFileAtomically($(path),true)) fail('Cannot render connection code');
}
function showReply(dir) {
    ObjC.import('Cocoa');
    var reply = JSON.parse(read(dir + '/private-reply.json')), qr = $.NSFileManager.defaultManager.fileExistsAtPath($(dir + '/connection.png'));
    var alert = $.NSAlert.alloc.init;
    alert.messageText = $('Scan with Screenpunk on your iPad');
    var startupText=reply.serverLifecycle==='background'?'Background startup is verified. After scanning, Terminal can close. Keep this Mac signed in, awake and reachable.':'Keep Terminal open.';
    alert.informativeText = $('Private connection code for ' + reply.computerName + '. Expires in five minutes. '+startupText+' The private file contains a bearer: transfer locally only, never upload or email it.');
    alert.addButtonWithTitle('Done'); alert.addButtonWithTitle('Show private file');
    if (qr) {
        var image = $.NSImage.alloc.initWithContentsOfFile($(dir + '/connection.png'));
        var iv = $.NSImageView.alloc.initWithFrame($.NSMakeRect(0,0,540,540));
        iv.image = image; iv.imageScaling = $.NSImageScaleProportionallyUpOrDown; alert.accessoryView = iv;
    } else { alert.informativeText = $('This connection needs the private file fallback. Use “Show private file” and transfer it locally to Screenpunk. It contains a bearer; never upload or email it. It expires in five minutes. '+startupText); }
    $.NSApplication.sharedApplication.setActivationPolicy($.NSApplicationActivationPolicyAccessory);
    $.NSApplication.sharedApplication.activateIgnoringOtherApps(true);
    ObjC.registerSubclass({name:'ScreenpunkPairingExpiry',superclass:'NSObject',methods:{'expire:':{types:['void',['id']],implementation:function(){ $.NSApplication.sharedApplication.abortModal; }}}});
    var expiryTarget=$.ScreenpunkPairingExpiry.alloc.init;
    while (Date.now() < reply.expiresAt) {
        var timer=$.NSTimer.timerWithTimeIntervalTargetSelectorUserInfoRepeats(Math.max(0.001,(reply.expiresAt-Date.now())/1000),expiryTarget,'expire:',null,false);
        $.NSRunLoop.currentRunLoop.addTimerForMode(timer,$.NSModalPanelRunLoopMode);
        var result=Number(alert.runModal); timer.invalidate; alert.window.orderOut(null);
        if (result === Number($.NSAlertSecondButtonReturn) && Date.now() < reply.expiresAt) { $.NSWorkspace.sharedWorkspace.selectFileInFileViewerRootedAtPath($(dir+'/private-reply.json'),$(dir)); continue; }
        break;
    }
}
function auditSSHText(text, username, includeDirectory, main, sourcePath, cryptoPath, cryptoOnly) {
    var includesCrypto = false;
    text.split(/\r?\n/).forEach(function(line, index) {
        line = line.replace(/#.*$/, '').trim(); if (!line) return;
        var parts = line.split(/\s+/), directive = parts.shift();
        var location = sourcePath + ':' + (index + 1);
        if (!/^[A-Za-z]+$/.test(directive)) fail('Unsupported SSH configuration syntax at '+location+'; review it before pairing');
        directive = directive.toLowerCase();
        if (cryptoOnly) {
            if (['ciphers','kexalgorithms','macs'].indexOf(directive) < 0 || parts.length === 0) fail('Unsupported directive '+directive+' at '+location+'; the macOS crypto Include may contain only Ciphers, KexAlgorithms and MACs');
            return;
        }
        if (directive === 'include') {
            var standardDirectory = main && parts.length === 1 && (parts[0] === includeDirectory+'/*' || parts[0] === includeDirectory+'/*.conf');
            var standardCrypto = !main && sourcePath === includeDirectory+'/100-macos.conf' && parts.length === 1 && parts[0] === cryptoPath;
            if (!standardDirectory && !standardCrypto) fail('Nonstandard or nested SSH Include at '+location+': '+line+'; manual review is required before pairing');
            if (standardCrypto) includesCrypto = true;
        }
        if (directive === 'match' && !(parts.length === 1 && parts[0].toLowerCase() === 'all') && !(parts.length === 2 && parts[0].toLowerCase() === 'user' && parts[1] === username)) fail('Conditional SSH Match rules at '+location+' could override forwarding for the iPad. Review host/address/group policies before pairing');
    });
    return includesCrypto;
}
function run(args) {
    var action = args[0], dir = args[2], app;
    if (action === 'upgrade-service-v4') return upgradeServiceV4(args);
    if (action.indexOf('service-')===0) return serviceAction(args);
    if (action === 'token-adopt') {
        var destination=args[1], temporary=destination+'.adopt-'+ObjC.unwrap($.NSUUID.UUID.UUIDString);
        try {
            write(temporary,JSON.stringify({schemaVersion:1,origin:'adopted-legacy-token',pid:Number(args[2]),start:args[3],tokenIdentity:args[4],tokenSHA256:args[5],binarySHA256:args[6]}));
            // RENAME_EXCL (Darwin sys/stdio.h): one atomic move, no overwrite or two-link crash window.
            if($.renamex_np(temporary,destination,4)!==0) fail('Existing connection ownership changed; no receipt was overwritten');
        } finally { $.unlink(temporary); }
        syncPath(destination); return;
    }
    if (action === 'restore-server') { write(args[2],read(args[1])); return; }
    if (action === 'sync') { syncPath(args[1]); return; }
    if (action === 'sync-rename') { syncDirectory(args[2]); syncPath(args[1]); return; }
    if (action === 'session-start') { write(args[1]+'/.screenpunk-session.json',JSON.stringify({owner:'screenpunk.mac-setup.v1',directory:args[1],pid:Number(args[2]),createdAt:Date.now()})); return; }
    if (action === 'session-clean') { var marker=JSON.parse(read(args[1]+'/.screenpunk-session.json')); if(marker.owner!=='screenpunk.mac-setup.v1' || marker.directory!==args[1] || !Number.isSafeInteger(marker.pid) || marker.pid<1) fail('Unknown prior setup session; inspect it before continuing'); ['private-reply.json','connection.png','new-token'].forEach(function(n){var path=args[1]+'/'+n; if($.NSFileManager.defaultManager.fileExistsAtPath($(path))) $.NSFileManager.defaultManager.removeItemAtPathError($(path),null);}); return; }
    if (action === 'choose') { app = nativeApp(); var chosen = app.chooseFile({withPrompt:'Select the PUBLIC Screenpunk setup-request JSON received from your iPad'}); write(args[1], String(chosen)); return; }
    if (action === 'consent') { app = nativeApp(); app.displayDialog(args[1],{withTitle:'Screenpunk Mac setup',buttons:['Cancel','Continue'],defaultButton:'Cancel',cancelButton:'Cancel'}); return; }
    if (action === 'request') { var request = validateRequest(read(args[1]),Date.now()); write(dir+'/request.json',JSON.stringify(request)); field(dir,'key.pub',request.publicKeyOpenSSH+'\n'); field(dir,'key-digest',request.publicKeySHA256); return; }
    if (action === 'reply') { var r = validateRequest(read(args[1]+'/request.json'),Date.now()), metadata = JSON.parse(read(args[1]+'/metadata.json')); metadata.appServerToken=read(args[2]).trim(); var text=JSON.stringify(makeReply(r,metadata,Date.now())); if(utf8Bytes(text)>8192) fail('Private reply too large'); write(args[1]+'/private-reply.json',text); if(utf8Bytes(text)<=1536) { try { renderQR(text,args[1]+'/connection.png'); } catch (_) { /* Private-file fallback stays available if CoreImage is unavailable. */ } } return; }
    if (action === 'audit-ssh') { var crypto=args[4], includedCrypto=false; auditSSHText(read(args[1]),args[3],args[2],true,args[1],crypto,false); var names=ObjC.deepUnwrap($.NSFileManager.defaultManager.contentsOfDirectoryAtPathError($(args[2]),null)); if(!names) fail('Cannot inspect SSH include directory'); names.forEach(function(n){if(auditSSHText(read(args[2]+'/'+n),args[3],args[2],false,args[2]+'/'+n,crypto,false)) includedCrypto=true;}); if(includedCrypto) { var leaf=args[5]; if(typeof leaf!=='string' || !leaf) fail('Verified SSH crypto policy path is missing'); auditSSHText(read(leaf),args[3],args[2],false,leaf,crypto,true); } return; }
    if (action === 'display') { showReply(args[1]); return; }
    if (action === 'metadata') { write(args[1]+'/metadata.json',JSON.stringify({computerName:args[2],host:args[3],username:args[4],hostKeySHA256:args[5],macWorkspace:args[6],serverLifecycle:args[7] || 'foreground'})); return; }
    if (action === 'server-write') { write(args[1],JSON.stringify({schemaVersion:1,pid:Number(args[2]),start:args[3],tokenIdentity:args[4],tokenSHA256:args[5],binarySHA256:args[6]})); return; }
    if (action === 'server-read') { var s=JSON.parse(read(args[1])); if(s.schemaVersion!==1 || !Number.isSafeInteger(s.pid) || s.pid<0 || !bounded(s.start,128) || (s.pid===0 && s.start!=='not-started') || !/^[0-9]+:600:[0-9]+$/.test(s.tokenIdentity) || !/^[a-f0-9]{64}$/.test(s.tokenSHA256) || s.binarySHA256!=='a04752e4d46a4d89e53e6f61c59c5349a638c8ce172ffbf391fd482b4d902a4e') fail('Unknown App Server receipt'); ['pid','start','tokenIdentity','tokenSHA256'].forEach(function(k){field(dir,'server-'+k,s[k]);}); if(s.serverLifecycle==='background')field(dir,'server-serverLifecycle','background'); return; }
    if (action === 'prepared-receipts') { var names=ObjC.deepUnwrap($.NSFileManager.defaultManager.contentsOfDirectoryAtPathError($(args[1]),null)); if(!names) fail('Cannot inspect setup receipts'); names.forEach(function(n){if(JSON.parse(read(args[1]+'/'+n)).lifecycle!=='prepared') fail('A paired-client receipt exists without its bearer. Review it; setup did not rotate the token');}); return; }
    if (action === 'receipt-complete') { var record=JSON.parse(read(args[1])); if(record.lifecycle==='handoff-ready') return; if(record.lifecycle!=='prepared') fail('Unknown install journal stage'); record.lifecycle='handoff-ready'; record.handoffReadyAt=Date.now(); write(args[1],JSON.stringify(record)); return; }
    if (action === 'receipt') { if ($.NSFileManager.defaultManager.fileExistsAtPath($(args[1]))) { var old=JSON.parse(read(args[1])); if(old.schemaVersion!==1 || old.addedPublicKeyLine!==read(args[2]+'/authorized-line') || old.policyPath!==args[4] || old.policySHA256!==args[5] || old.serverReceipt!==args[7] || old.tokenFile!==args[8]) fail('Existing install receipt conflicts; review ownership'); return; } write(args[1],JSON.stringify({schemaVersion:1,setupVersion:'5',lifecycle:'prepared',pairingID:JSON.parse(read(args[2]+'/request.json')).pairingID,addedPublicKeyLine:read(args[2]+'/authorized-line'),keyWasAdded:args[3]==='1',policyPath:args[4],policySHA256:args[5],policyWasAdded:args[6]==='1',serverReceipt:args[7],tokenFile:args[8],tokenWasCreated:args[9]==='1',createdAt:Date.now(),revoke:'Remove only addedPublicKeyLine from ~/.ssh/authorized_keys. Keep the shared account policy/token/server until every paired client is revoked. Stop only the PID with matching start identity in serverReceipt. Never rotate the token without reviewing all paired clients.'})); return; }
    fail('Unknown native setup action');
}
/* Native support for the optional user-consented LaunchAgent. No network APIs. */
var screenpunkServiceLabel = 'xyz.screenpunk.local-agent';
function serviceXML(value) { return String(value).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&apos;'); }
function serviceManifest(path) {
    var m=JSON.parse(read(path));
    if(m.schemaVersion!==1 || m.kind!=='screenpunk.launchagent.v1' || m.label!==screenpunkServiceLabel || m.version!=='4' || !Number.isSafeInteger(m.uid) || m.uid<0 || !bounded(m.home,1024) || m.home[0]!=='/' || m.serviceDirectory!==m.home+'/.codex/screenpunk-local/setup-service' || m.plistPath!==m.home+'/Library/LaunchAgents/'+m.label+'.plist' || m.controlPath!==m.serviceDirectory+'/manage-v4.sh' || m.nativePath!==m.serviceDirectory+'/native-v4.js' || m.cachedPlistPath!==m.serviceDirectory+'/agent-v4.plist' || m.domain!=='gui/'+m.uid || m.binarySHA256!=='a04752e4d46a4d89e53e6f61c59c5349a638c8ce172ffbf391fd482b4d902a4e' || !/^[0-9]+:600:[0-9]+$/.test(m.tokenIdentity) || !/^[a-f0-9]{64}$/.test(m.tokenSHA256)) fail('Unknown background-service ownership receipt; no service was changed');
    ['controlSHA256','nativeSHA256','plistSHA256'].forEach(function(k){if(!/^[a-f0-9]{64}$/.test(m[k])) fail('Invalid background-service file receipt');});
    if(['prepared','enabled','failed','uninstalled'].indexOf(m.lifecycle)<0 || m.consent!==true) fail('Background startup was not authorized');
    return m;
}
// `launchctl list label` emits a diagnostic dictionary, not an OpenStep/XML
// plist: array elements are semicolon-delimited and the outer brace may end in
// a semicolon. Parse only this observed format; never eval or guess a format.
function parseLaunchctlJobInformation(text) {
    function bad(reason) { fail('Cannot verify LaunchAgent job information: '+reason+'; no job was stopped'); }
    if(typeof text!=='string' || !text.length || utf8Bytes(text)>65536) bad('output exceeds the supported bound');
    var index=0, nodes=0;
    function whitespace() { while(index<text.length && /[ \t\r\n]/.test(text[index])) index++; }
    function expect(character) { whitespace();if(text[index]!==character) bad('malformed diagnostic dictionary');index++; }
    function quoted() {
        whitespace();if(text[index]!== '"') bad('quoted string required');
        var start=index++;
        while(index<text.length) {
            if(text[index]==='\\') {index+=2;continue;}
            if(text[index]==='"') {index++;var value;try{value=JSON.parse(text.slice(start,index));if(utf8Bytes(value)>4096 || /[\x00-\x1f\x7f]/.test(value))bad('unsupported string');}catch(_){bad('invalid quoted string');}return value;}
            index++;
        }
        bad('unterminated quoted string');
    }
    function value(depth) {
        if(depth>4 || ++nodes>256) bad('output is too complex');
        whitespace();var character=text[index];
        if(character==='"') return quoted();
        if(character==='{') {
            index++;var object=Object.create(null), count=0;whitespace();
            while(text[index]!=='}') {
                if(index>=text.length || ++count>64) bad('dictionary is too large or incomplete');
                var key=quoted();if(!key || Object.prototype.hasOwnProperty.call(object,key))bad('duplicate or empty field');
                expect('=');object[key]=value(depth+1);expect(';');whitespace();
            }
            index++;return object;
        }
        if(character==='(') {
            index++;var array=[];whitespace();
            while(text[index]!==')') {if(index>=text.length || array.length>=64)bad('array is too large or incomplete');array.push(value(depth+1));expect(';');whitespace();}
            index++;return array;
        }
        var token=/^(?:true|false|-?(?:0|[1-9][0-9]*))/.exec(text.slice(index));
        if(!token)bad('unsupported diagnostic value');index+=token[0].length;
        if(token[0]==='true')return true;if(token[0]==='false')return false;
        var number=Number(token[0]);if(!Number.isSafeInteger(number))bad('integer is out of range');return number;
    }
    whitespace();if(text[index]!=='{')bad('unsupported output format');var job=value(0);whitespace();if(text[index]===';'){index++;whitespace();}if(index!==text.length)bad('trailing output');
    if(!job || Array.isArray(job) || typeof job!=='object' || typeof job.Label!=='string' || !Array.isArray(job.ProgramArguments) || job.ProgramArguments.length!==3 || !job.ProgramArguments.every(function(v){return typeof v==='string';}) || (job.Program!==undefined && typeof job.Program!=='string'))bad('invalid identity field shape');
    if(job.PID!==undefined && (typeof job.PID!=='number' || !Number.isSafeInteger(job.PID) || job.PID<0 || job.PID>2147483647))bad('invalid process identity');
    if(job.LastExitStatus!==undefined && (typeof job.LastExitStatus!=='number'||!Number.isSafeInteger(job.LastExitStatus)||job.LastExitStatus< -2147483648||job.LastExitStatus>2147483647))bad('invalid exit status');
    if(job.OnDemand!==undefined && typeof job.OnDemand!=='boolean')bad('invalid demand state');
    ['StandardOutPath','StandardErrorPath','LimitLoadToSessionType'].forEach(function(k){if(job[k]!==undefined && typeof job[k]!=='string')bad('invalid advisory field shape');});
    return job;
}
function serviceAction(args) {
    var action=args[0];
    if(action==='service-choice') {
        var result=nativeApp().displayDialog('Keep Screenpunk available after closing Terminal? Enable background startup installs a LaunchAgent for your Mac account and starts the same private local server now and whenever you sign in. It restarts if the server exits. Your Mac must stay awake and you must be logged in; logout stops it, and reboot requires login. Existing SSH keys and the saved credential are unchanged. Choose Terminal only for the foreground alternative.',{withTitle:'Screenpunk background startup',buttons:['Cancel','Terminal only','Enable background startup'],defaultButton:'Enable background startup',cancelButton:'Cancel'});
        return result.buttonReturned==='Enable background startup'?'background':'foreground';
    }
    if(action==='service-plist') {
        var home=args[2], uid=Number(args[3]), dir=home+'/.codex/screenpunk-local/setup-service';
        if(!bounded(home,1024) || home[0]!=='/' || !Number.isSafeInteger(uid) || uid<0) fail('Invalid background-service account');
        var xml='<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>'
        +'<key>Label</key><string>'+screenpunkServiceLabel+'</string><key>ProgramArguments</key><array><string>/bin/sh</string><string>'+serviceXML(dir+'/manage-v4.sh')+'</string><string>run</string></array>'
        +'<key>EnvironmentVariables</key><dict><key>HOME</key><string>'+serviceXML(home)+'</string><key>CODEX_HOME</key><string>'+serviceXML(home+'/.codex/screenpunk-local')+'</string><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>'
        +'<key>WorkingDirectory</key><string>'+serviceXML(home+'/.codex/screenpunk-local/workspace')+'</string><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>30</integer><key>ProcessType</key><string>Background</string><key>LimitLoadToSessionType</key><string>Aqua</string><key>Umask</key><integer>63</integer><key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>/dev/null</string></dict></plist>\n';
        write(args[1],xml);return;
    }
    if(action==='service-prepare') {
        var home=args[3], dir=home+'/.codex/screenpunk-local/setup-service', manifest={schemaVersion:1,kind:'screenpunk.launchagent.v1',version:'4',label:screenpunkServiceLabel,uid:Number(args[4]),home:home,domain:'gui/'+args[4],serviceDirectory:dir,plistPath:home+'/Library/LaunchAgents/'+screenpunkServiceLabel+'.plist',controlPath:dir+'/manage-v4.sh',nativePath:dir+'/native-v4.js',cachedPlistPath:dir+'/agent-v4.plist',tokenIdentity:args[5],tokenSHA256:args[6],binarySHA256:args[7],controlSHA256:args[8],nativeSHA256:args[9],plistSHA256:args[10],lifecycle:'prepared',consent:true,createdAt:Date.now()};
        if($.NSFileManager.defaultManager.fileExistsAtPath($(args[1]))) {
            var old=serviceManifest(args[1]);Object.keys(manifest).forEach(function(k){if(['lifecycle','createdAt'].indexOf(k)<0 && old[k]!==manifest[k]) fail('Existing background-service ownership conflicts; no files were overwritten');});return;
        }
        var names=ObjC.deepUnwrap($.NSFileManager.defaultManager.contentsOfDirectoryAtPathError($(dir),null));
        if(!names || names.length) fail('Unknown files exist in the background-service directory; review them before installing');
        if($.NSFileManager.defaultManager.fileExistsAtPath($(manifest.plistPath))) fail('An unknown LaunchAgent plist already exists; it was not replaced');
        write(args[1],JSON.stringify(manifest));return;
    }
    if(action==='service-files') {
        var m=serviceManifest(args[1]), source=args[2];
        [[source+'/service-control.sh',m.controlPath,448],[source+'/native.js',m.nativePath,384],[source+'/service.plist',m.cachedPlistPath,384]].forEach(function(v){if(!$.NSFileManager.defaultManager.fileExistsAtPath($(v[1]))) {write(v[1],read(v[0]));if(!$.NSFileManager.defaultManager.setAttributesOfItemAtPathError($({NSFilePosixPermissions:v[2]}),$(v[1]),null)) fail('Cannot set private service file permissions');syncPath(v[1]);}});return;
    }
    if(action==='service-validate') {
        var m=serviceManifest(args[1]);
        if(m.home!==args[2] || String(m.uid)!==args[3] || m.tokenIdentity!==args[4] || m.tokenSHA256!==args[5] || m.controlSHA256!==args[6] || m.nativeSHA256!==args[7] || m.plistSHA256!==args[8]) fail('Background-service files or saved credential changed; nothing was stopped');
        if(args[9]) {field(args[9],'service-domain',m.domain);field(args[9],'service-lifecycle',m.lifecycle);} return;
    }
    if(action==='service-job') {
        var m=serviceManifest(args[1]);
        var attributes=ObjC.deepUnwrap($.NSFileManager.defaultManager.attributesOfItemAtPathError($(args[2]),Ref()));
        if(!attributes || attributes.NSFileType!=='NSFileTypeRegular' || typeof attributes.NSFileSize!=='number' || attributes.NSFileSize<1 || attributes.NSFileSize>65536) fail('Cannot verify LaunchAgent job information: unsupported output file; no job was stopped');
        var job=parseLaunchctlJobInformation(read(args[2])), expected=['/bin/sh',m.controlPath,'run'];
        if(job.Label!==m.label || JSON.stringify(job.ProgramArguments)!==JSON.stringify(expected) || (job.Program!==undefined && job.Program!=='/bin/sh')) fail('The LaunchAgent label belongs to an unknown job; nothing was stopped');
        field(args[3],'service-job-pid',job.PID===undefined?0:job.PID);return;
    }
    if(action==='service-state') {var m=serviceManifest(args[1]);if(['enabled','failed','uninstalled'].indexOf(args[2])<0) fail('Invalid service state');m.lifecycle=args[2];m.updatedAt=Date.now();write(args[1],JSON.stringify(m));return;}
    if(action==='service-server-write') {
        var m=serviceManifest(args[1]);write(args[2],JSON.stringify({schemaVersion:1,pid:Number(args[3]),start:args[4],tokenIdentity:m.tokenIdentity,tokenSHA256:m.tokenSHA256,binarySHA256:m.binarySHA256,serverLifecycle:'background',serviceLabel:m.label,serviceDirectory:m.serviceDirectory}));return;
    }
    if(action==='service-ready') {
        var m=serviceManifest(args[1]), s=JSON.parse(read(args[2]));
        if(s.serverLifecycle!=='background'||s.serviceLabel!==m.label||s.serviceDirectory!==m.serviceDirectory||String(s.pid)!==args[3]||s.start!==args[4]||s.tokenIdentity!==m.tokenIdentity||s.tokenSHA256!==m.tokenSHA256||s.binarySHA256!==m.binarySHA256)fail('Background listener ownership is not verified');return;
    }
    if(action==='service-status') {var m=serviceManifest(args[1]);write(m.serviceDirectory+'/status.json',JSON.stringify({schemaVersion:1,lifecycle:m.lifecycle,stage:args[2],updatedAt:Date.now(),note:'No server request, reply, bearer or account payload is logged. Client connection diagnostics provide protocol errors.'}));return;}
    if(action==='service-copy-plist') {
        var m=serviceManifest(args[1]), text=read(m.cachedPlistPath), fm=$.NSFileManager.defaultManager;
        [m.home+'/Library',m.home+'/Library/LaunchAgents'].forEach(function(path){var a=ObjC.deepUnwrap(fm.attributesOfItemAtPathError($(path),Ref()));if(!a||a.NSFileType!=='NSFileTypeDirectory'||[0,m.uid].indexOf(Number(a.NSFileOwnerAccountID))<0||(Number(a.NSFilePosixPermissions)&18)!==0)fail('LaunchAgent parent ownership changed during review');});
        var a=ObjC.deepUnwrap(fm.attributesOfItemAtPathError($(m.plistPath),Ref()));
        if(a){if(a.NSFileType!=='NSFileTypeRegular'||Number(a.NSFileOwnerAccountID)!==m.uid||Number(a.NSFilePosixPermissions)!==384||Number(a.NSFileReferenceCount)!==1||read(m.plistPath)!==text)fail('An unknown LaunchAgent plist appeared during review; it was not overwritten');return 'existing';}
        var temporary=m.plistPath+'.prepare-'+ObjC.unwrap($.NSUUID.UUID.UUIDString);
        try{write(temporary,text);if($.renamex_np(temporary,m.plistPath,4)!==0)fail('LaunchAgent publication lost ownership; no plist was overwritten');}finally{$.unlink(temporary);}
        syncPath(m.plistPath);return 'created';
    }
    fail('Unknown background-service action');
}
/* Setup-only, consent-gated repair of the known V4 parser. No service/network APIs. */
var screenpunkV4NativeSHA256='e3090e5962e34250a0cdaa011fbe39802a7ef20dd987b95bde9039836442842c';
var screenpunkV4ControlSHA256='5aae5398e4563d8d8fa96ebadbc8641339079587d1b0bd2ac95d91fba30f4e24';
ObjC.bindFunction('getuid',['unsigned int',[]]);
function upgradeServiceV4(args) {
    var operation=args[1], manifestPath=args[2], home=args[3], uid=Number(args[4]), source=args[5], controlSource=args[6];
    var fm=$.NSFileManager.defaultManager;
    function reject(){fail('Background helper repair ownership does not match the reviewed V4 installation. Nothing was stopped, restarted or rotated.');}
    if(['inspect','prepare','apply'].indexOf(operation)<0 || !Number.isSafeInteger(uid) || uid!==Number($.getuid()) || !bounded(home,1024) || home[0]!=='/' || /\/\//.test(home) || home.split('/').some(function(p){return p==='.'||p==='..';}) || ObjC.unwrap($(home).stringByResolvingSymlinksInPath)!==home) reject();
    var dir=home+'/.codex/screenpunk-local/setup-service', backup=dir+'/native-upgrade-v5';
    var journalPath=backup+'/journal.json', originalNative=backup+'/original-native-v4.js', originalManifest=backup+'/original-install-v4.json', nextNative=backup+'/replacement-native-v4.js', nextManifest=backup+'/replacement-install-v4.json';
    if(manifestPath!==dir+'/install.json') reject();
    function attrs(path){return ObjC.deepUnwrap(fm.attributesOfItemAtPathError($(path),Ref()));}
    function directory(path,strict){var a=attrs(path);if(!a||a.NSFileType!=='NSFileTypeDirectory'||Number(a.NSFileOwnerAccountID)!==uid||(strict?Number(a.NSFilePosixPermissions)!==448:(Number(a.NSFilePosixPermissions)&18)!==0))reject();}
    function file(path,mode,max){var a=attrs(path);if(!a||a.NSFileType!=='NSFileTypeRegular'||Number(a.NSFileOwnerAccountID)!==uid||Number(a.NSFilePosixPermissions)!==mode||Number(a.NSFileReferenceCount)!==1||Number(a.NSFileSize)>max)reject();return String(a.NSFileSystemNumber)+':'+String(a.NSFileSystemFileNumber)+':'+String(a.NSFileSize);}
    function hash(path,mode,max){var identity=file(path,mode,max), task=$.NSTask.alloc.init, pipe=$.NSPipe.pipe, errors=$.NSPipe.pipe;task.launchPath='/usr/bin/shasum';task.arguments=$(['-a','256',path]);task.standardOutput=pipe;task.standardError=errors;task.launch;var data=pipe.fileHandleForReading.readDataToEndOfFile;task.waitUntilExit;if(Number(task.terminationStatus)!==0||file(path,mode,max)!==identity)reject();var text=ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data,$.NSUTF8StringEncoding));if(typeof text!=='string'||!/^[a-f0-9]{64} /.test(text))reject();return text.slice(0,64);}
    function exclusive(path,text){
        if(attrs(path))reject();
        // Stage in the already verified private setup session, not the strict
        // backup inventory. A crash before rename preserves this exact orphan
        // for review without blocking journal-driven recovery of the targets.
        var temporary=source.slice(0,source.lastIndexOf('/'))+'/service-upgrade-stage-'+path.slice(path.lastIndexOf('/')+1)+'-'+ObjC.unwrap($.NSUUID.UUID.UUIDString);
        write(temporary,text);
        if($.renamex_np(temporary,path,4)!==0)reject();
        syncDirectory(source.slice(0,source.lastIndexOf('/')));syncPath(path);
    }
    function backupFile(path,text,expected){if(attrs(path)){if(hash(path,384,1048576)!==expected)reject();return;}exclusive(path,text);if(hash(path,384,1048576)!==expected)reject();}
    directory(home,false);directory(home+'/.codex',false);directory(home+'/.codex/screenpunk-local',true);directory(dir,true);
    if(typeof source!=='string'||typeof controlSource!=='string'||source[0]!=='/'||controlSource[0]!=='/'||source.slice(0,source.lastIndexOf('/'))!==controlSource.slice(0,controlSource.lastIndexOf('/')))reject();
    directory(source.slice(0,source.lastIndexOf('/')),true);
    file(source,384,1048576);file(controlSource,384,1048576);
    var newSHA=hash(source,384,1048576);if(newSHA===screenpunkV4NativeSHA256||hash(controlSource,384,1048576)!==screenpunkV4ControlSHA256)reject();
    function snapshot(){
        file(manifestPath,384,16384);var m=serviceManifest(manifestPath);
        if(m.home!==home||m.uid!==uid||m.controlSHA256!==screenpunkV4ControlSHA256)reject();
        directory(home+'/Library',false);directory(home+'/Library/LaunchAgents',false);
        if(hash(m.controlPath,448,1048576)!==screenpunkV4ControlSHA256||hash(m.cachedPlistPath,384,16384)!==m.plistSHA256)reject();
        if(attrs(m.plistPath)&&hash(m.plistPath,384,16384)!==m.plistSHA256)reject();
        var tokenPath=home+'/.codex/screenpunk-local/transport-token';file(tokenPath,384,65);
        var a=attrs(tokenPath);if(Number(a.NSFileSize)!==65||m.tokenIdentity!==uid+':600:'+String(a.NSFileSystemFileNumber)||hash(tokenPath,384,65)!==m.tokenSHA256)reject();
        var nativeSHA=hash(m.nativePath,384,1048576), manifestSHA=hash(manifestPath,384,16384);
        if([screenpunkV4NativeSHA256,newSHA].indexOf(nativeSHA)<0||[screenpunkV4NativeSHA256,newSHA].indexOf(m.nativeSHA256)<0)reject();
        return {m:m,nativeSHA:nativeSHA,manifestSHA:manifestSHA,tokenIdentity:file(tokenPath,384,65)};
    }
    var initial=snapshot(), journal=null;
    function loadJournal(){
        if(!attrs(backup))return null;directory(backup,true);
        var names=ObjC.deepUnwrap(fm.contentsOfDirectoryAtPathError($(backup),null)), allowed=['journal.json','original-native-v4.js','original-install-v4.json','replacement-native-v4.js','replacement-install-v4.json'];
        if(!names||names.some(function(n){return allowed.indexOf(n)<0;}))reject();
        if(!attrs(journalPath)){if(names.length)reject();return null;}
        file(journalPath,384,16384);var j=JSON.parse(read(journalPath));
        if(j.schemaVersion!==1||j.kind!=='screenpunk.native-helper-upgrade.v1'||j.consent!==true||j.home!==home||j.uid!==uid||j.manifestPath!==manifestPath||j.fromNativeSHA256!==screenpunkV4NativeSHA256||j.toNativeSHA256!==newSHA||j.controlSHA256!==screenpunkV4ControlSHA256||j.tokenIdentity!==initial.m.tokenIdentity||j.tokenSHA256!==initial.m.tokenSHA256||j.plistSHA256!==initial.m.plistSHA256||!Number.isSafeInteger(j.createdAt)||['preparing','prepared','completed'].indexOf(j.lifecycle)<0||!/^[a-f0-9]{64}$/.test(j.originalManifestSHA256))reject();
        if(j.lifecycle!=='preparing'&&!/^[a-f0-9]{64}$/.test(j.replacementManifestSHA256))reject();
        return j;
    }
    journal=loadJournal();
    function state(){
        var s=snapshot();
        if(s.m.tokenIdentity!==initial.m.tokenIdentity||s.tokenIdentity!==initial.tokenIdentity||s.m.tokenSHA256!==initial.m.tokenSHA256||s.m.plistSHA256!==initial.m.plistSHA256)reject();
        var oldOld=s.nativeSHA===screenpunkV4NativeSHA256&&s.m.nativeSHA256===screenpunkV4NativeSHA256;
        var newOld=s.nativeSHA===newSHA&&s.m.nativeSHA256===screenpunkV4NativeSHA256;
        var newNew=s.nativeSHA===newSHA&&s.m.nativeSHA256===newSHA;
        if(!oldOld&&!newOld&&!newNew)reject();
        if(!journal){if(newOld)reject();return {name:oldOld?'required':'current',snapshot:s};}
        if(oldOld&&s.manifestSHA!==journal.originalManifestSHA256)reject();
        if(newOld&&(journal.lifecycle==='preparing'||s.manifestSHA!==journal.originalManifestSHA256))reject();
        if(newNew&&(journal.lifecycle==='preparing'||journal.lifecycle!=='completed'&&s.manifestSHA!==journal.replacementManifestSHA256))reject();
        if(journal.lifecycle==='completed'&&!newNew)reject();
        if(journal.lifecycle!=='preparing'){
            if(hash(originalNative,384,1048576)!==screenpunkV4NativeSHA256||hash(originalManifest,384,16384)!==journal.originalManifestSHA256||hash(nextNative,384,1048576)!==newSHA||hash(nextManifest,384,16384)!==journal.replacementManifestSHA256)reject();
            var before=JSON.parse(read(originalManifest)), after=JSON.parse(read(nextManifest));before.nativeSHA256=newSHA;
            if(JSON.stringify(before)!==JSON.stringify(after))reject();
            if(newNew&&journal.lifecycle==='completed'){
                // Normal controller lifecycle writes may follow a completed repair.
                // All other fields must still equal the archived replacement.
                var active=JSON.parse(read(manifestPath)), expected=JSON.parse(read(nextManifest));
                if(active.updatedAt!==undefined&&(!Number.isSafeInteger(active.updatedAt)||active.updatedAt<=0))reject();
                delete active.lifecycle;delete active.updatedAt;delete expected.lifecycle;delete expected.updatedAt;
                if(JSON.stringify(active)!==JSON.stringify(expected))reject();
            }
        }
        return {name:newNew?'current':'resume',snapshot:s};
    }
    var current=state();
    if(operation==='inspect')return current.name;
    if(!journal){
        if(current.name==='current')return 'current';
        if(operation!=='prepare')reject();
        if(!attrs(backup)){if(!fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError($(backup),false,$({NSFilePosixPermissions:448}),null))reject();syncDirectory(dir);}directory(backup,true);
        // Consent is supplied by the trusted setup dispatcher only after its dialog.
        journal={schemaVersion:1,kind:'screenpunk.native-helper-upgrade.v1',consent:true,home:home,uid:uid,manifestPath:manifestPath,fromNativeSHA256:screenpunkV4NativeSHA256,toNativeSHA256:newSHA,controlSHA256:screenpunkV4ControlSHA256,tokenIdentity:initial.m.tokenIdentity,tokenSHA256:initial.m.tokenSHA256,plistSHA256:initial.m.plistSHA256,originalManifestSHA256:initial.manifestSHA,lifecycle:'preparing',createdAt:Date.now()};
        exclusive(journalPath,JSON.stringify(journal));
    }
    if(journal.lifecycle==='preparing'){
        current=state();if(current.snapshot.nativeSHA!==screenpunkV4NativeSHA256||current.snapshot.manifestSHA!==journal.originalManifestSHA256)reject();
        backupFile(originalNative,read(initial.m.nativePath),screenpunkV4NativeSHA256);
        backupFile(originalManifest,read(manifestPath),journal.originalManifestSHA256);
        backupFile(nextNative,read(source),newSHA);
        var replacement=JSON.parse(read(originalManifest));replacement.nativeSHA256=newSHA;
        var nextText=JSON.stringify(replacement);
        if(attrs(nextManifest)){file(nextManifest,384,16384);if(read(nextManifest)!==nextText)reject();}else exclusive(nextManifest,nextText);
        journal.replacementManifestSHA256=hash(nextManifest,384,16384);journal.lifecycle='prepared';
        state();write(journalPath,JSON.stringify(journal));
    }
    if(operation==='prepare')return 'prepared';
    current=state();
    if(current.snapshot.nativeSHA===screenpunkV4NativeSHA256){write(initial.m.nativePath,read(nextNative));syncPath(initial.m.nativePath);}
    current=state();
    // The helper is durable before its receipt changes. A crash here is new-old,
    // recoverable only through the durable consent journal and original backups.
    if(current.snapshot.m.nativeSHA256===screenpunkV4NativeSHA256){write(manifestPath,read(nextManifest));syncPath(manifestPath);}
    current=state();if(current.name!=='current')reject();
    if(journal.lifecycle!=='completed'){journal.lifecycle='completed';journal.completedAt=Date.now();write(journalPath,JSON.stringify(journal));}
    return 'current';
}
SCREENPUNK_NATIVE_JS
cat > "$sp_session/service-control.sh" <<'SCREENPUNK_SERVICE_CONTROL'
#!/bin/sh
# Screenpunk v4 per-user LaunchAgent controller. User-installed, no private token in argv/plist.
set -eu
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
SP_CODEX='/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'
SP_OSASCRIPT=/usr/bin/osascript
SP_LAUNCHCTL=/bin/launchctl
SP_SHA=a04752e4d46a4d89e53e6f61c59c5349a638c8ce172ffbf391fd482b4d902a4e
SP_VERSION=0.164.0-alpha.11.1
fail() { printf '%s\n' "$1" >&2; exit 1; }
sp_uid=$(id -u)
[ "$(cd "$HOME" && pwd -P)" = "$HOME" ] || fail 'Background home must not contain symbolic links.'
export CODEX_HOME="$HOME/.codex/screenpunk-local"
sp_token="$CODEX_HOME/transport-token"; sp_server_receipt="$CODEX_HOME/setup-server.json"
sp_pid=''; sp_start=''; sp_server_lifecycle=background
private_dir() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -f '%u:%Lp' "$1")" = "$sp_uid:700" ] || fail 'Expected a private owned Screenpunk directory.'; }
private_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -f '%u:%Lp:%l' "$1")" = "$sp_uid:600:1" ] || fail 'Expected a private singly-linked owned Screenpunk file.'; }
process_start() { ps -p "$1" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//'; }
private_dir "$CODEX_HOME"; private_dir "$CODEX_HOME/workspace"
# Optional user-consented LaunchAgent lifecycle. Functions only when embedded.
service_paths() {
  sp_service_dir="$CODEX_HOME/setup-service"
  sp_service_manifest="$sp_service_dir/install.json"
  sp_service_plist="$HOME/Library/LaunchAgents/xyz.screenpunk.local-agent.plist"
  sp_service_label='xyz.screenpunk.local-agent'
  sp_service_domain="gui/$sp_uid"
  sp_service_target="$sp_service_domain/$sp_service_label"
}
service_parent() {
  [ -d "$1" ] && [ ! -L "$1" ] || fail "Review the background-service directory: $1"
  sp_service_owner=$(stat -f '%u' "$1")
  [ "$sp_service_owner" = "$sp_uid" ] || [ "$sp_service_owner" = 0 ] || fail "Unknown background-service directory owner: $1"
  sp_service_mode=$(stat -f '%Lp' "$1")
  [ "$((0$sp_service_mode & 022))" -eq 0 ] || fail "Background-service directory is writable by another account: $1"
}
service_hash() { shasum -a 256 "$1" | awk '{print $1}'; }
service_private_control() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -f '%u:%Lp:%l' "$1")" = "$sp_uid:700:1" ] || fail 'Background management script must be an owned private regular file.'; }
service_validate_files() {
  service_paths
  private_dir "$sp_service_dir"; private_file "$sp_service_manifest"
  service_parent "$HOME/Library"; service_parent "$HOME/Library/LaunchAgents"
  service_private_control "$sp_service_dir/manage-v4.sh"; private_file "$sp_service_dir/native-v4.js"; private_file "$sp_service_dir/agent-v4.plist"; private_file "$sp_token"
  # Verify the installed parser before executing it. plutil reads only this
  # private no-secret manifest; no unverified helper is invoked for validation.
  sp_service_expected_native=$(plutil -extract nativeSHA256 raw -o - "$sp_service_manifest") || fail 'Cannot read background-service native-file ownership.'
  [ "$(service_hash "$sp_service_dir/native-v4.js")" = "$sp_service_expected_native" ] || fail 'Background-service native helper changed; no job was stopped.'
  native service-validate "$sp_service_manifest" "$HOME" "$sp_uid" "$(stat -f '%u:%Lp:%i' "$sp_token")" "$(service_hash "$sp_token")" "$(service_hash "$sp_service_dir/manage-v4.sh")" "$(service_hash "$sp_service_dir/native-v4.js")" "$(service_hash "$sp_service_dir/agent-v4.plist")" || fail 'Background-service file or credential ownership could not be verified.'
  if [ -e "$sp_service_plist" ] || [ -L "$sp_service_plist" ]; then
    private_file "$sp_service_plist"; cmp -s "$sp_service_plist" "$sp_service_dir/agent-v4.plist" || fail 'The LaunchAgent plist changed; it was not replaced or stopped.'
  fi
}
service_query_job() {
  # `launchctl print` explicitly has no stable API. `list label` returns a plist;
  # reject unavailable/unknown fields instead of guessing a job's ownership.
  if "$SP_LAUNCHCTL" list "$sp_service_label" > "$sp_session/service-job.plist" 2>/dev/null; then
    native service-job "$sp_service_manifest" "$sp_session/service-job.plist" "$sp_session" || return 1
    sp_service_job_pid=$(cat "$sp_session/service-job-pid")
    return 0
  fi
  sp_service_job_pid=0
  return 2
}
service_verify_job_process() {
  [ "$sp_service_job_pid" -gt 0 ] || return 0
  private_file "$sp_server_receipt"
  sp_service_job_start=$(process_start "$sp_service_job_pid")
  [ -n "$sp_service_job_start" ] || fail 'The background process changed during ownership review.'
  native service-ready "$sp_service_manifest" "$sp_server_receipt" "$sp_service_job_pid" "$sp_service_job_start"
}
service_wait_ready() {
  sp_service_attempt=0
  while [ "$sp_service_attempt" -lt 20 ]; do
    if service_query_job && [ "$sp_service_job_pid" -gt 0 ] && [ -f "$sp_server_receipt" ]; then
      sp_service_job_start=$(process_start "$sp_service_job_pid")
      if [ -n "$sp_service_job_start" ] && native service-ready "$sp_service_manifest" "$sp_server_receipt" "$sp_service_job_pid" "$sp_service_job_start" 2>/dev/null; then
        sp_service_listener=$(lsof -nP -a -p "$sp_service_job_pid" -iTCP:4500 -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p' || :)
        sp_service_all=$(lsof -nP -a -iTCP:4500 -sTCP:LISTEN -t 2>/dev/null | sort -u || :)
        if [ "$sp_service_listener" = '127.0.0.1:4500' ] && [ "$sp_service_all" = "$sp_service_job_pid" ]; then
          sp_pid=$sp_service_job_pid; sp_start=$sp_service_job_start; sp_server_lifecycle=background
          native service-state "$sp_service_manifest" enabled
          native service-status "$sp_service_manifest" ready
          return 0
        fi
      fi
    fi
    sleep 1; sp_service_attempt=$((sp_service_attempt + 1))
  done
  return 1
}
service_prepare_install() {
  service_paths
  [ -e "$HOME/Library" ] || mkdir "$HOME/Library"
  service_parent "$HOME/Library"
  [ -e "$HOME/Library/LaunchAgents" ] || mkdir "$HOME/Library/LaunchAgents"
  service_parent "$HOME/Library/LaunchAgents"
  if "$SP_LAUNCHCTL" list "$sp_service_label" > /dev/null 2>&1; then
    [ -f "$sp_service_manifest" ] && [ ! -L "$sp_service_manifest" ] || fail 'An unknown job already uses the Screenpunk LaunchAgent label. It was not stopped.'
  fi
  private_dir "$sp_service_dir"
  if [ -e "$sp_service_manifest" ] || [ -L "$sp_service_manifest" ]; then private_file "$sp_service_manifest"; fi
  native service-plist "$sp_session/service.plist" "$HOME" "$sp_uid"
  native service-prepare "$sp_service_manifest" "$sp_session" "$HOME" "$sp_uid" "$(stat -f '%u:%Lp:%i' "$sp_token")" "$(service_hash "$sp_token")" "$SP_SHA" "$(service_hash "$sp_session/service-control.sh")" "$(service_hash "$sp_session/native.js")" "$(service_hash "$sp_session/service.plist")"
  # The persistent service journal references this exact token even on a failed
  # first attempt. Retain it for resumption; never rotate credentials on retry.
  sp_token_created=0
  # Existing files are verified before native code fills only missing paths.
  for sp_service_pair in 'manage-v4.sh:700' 'native-v4.js:600' 'agent-v4.plist:600'; do
    sp_service_name=${sp_service_pair%:*}; sp_service_permission=${sp_service_pair#*:}
    if [ -e "$sp_service_dir/$sp_service_name" ] || [ -L "$sp_service_dir/$sp_service_name" ]; then
      if [ "$sp_service_permission" = 700 ]; then service_private_control "$sp_service_dir/$sp_service_name"; else private_file "$sp_service_dir/$sp_service_name"; fi
      case "$sp_service_name" in manage-v4.sh) sp_service_source="$sp_session/service-control.sh";; native-v4.js) sp_service_source="$sp_session/native.js";; *) sp_service_source="$sp_session/service.plist";; esac
      cmp -s "$sp_service_dir/$sp_service_name" "$sp_service_source" || fail 'Existing background-service source changed. Review it; no file was overwritten.'
    fi
  done
  if [ -e "$sp_service_plist" ] || [ -L "$sp_service_plist" ]; then private_file "$sp_service_plist"; cmp -s "$sp_service_plist" "$sp_session/service.plist" || fail 'An unknown LaunchAgent plist was not overwritten.'; fi
  native service-files "$sp_service_manifest" "$sp_session"
  service_validate_files
}
service_bootout_owned() {
  service_validate_files
  if service_query_job; then
    service_verify_job_process || return 1
    "$SP_LAUNCHCTL" bootout "$sp_service_target" || return 1
    if "$SP_LAUNCHCTL" list "$sp_service_label" >/dev/null 2>&1; then return 1; fi
  else
    sp_service_query_status=$?
    [ "$sp_service_query_status" -eq 2 ] || return 1
  fi
}
service_start_background() {
  service_prepare_install
  sp_service_loaded_before=0
  if service_query_job; then
    service_verify_job_process; sp_service_loaded_before=1
    if service_wait_ready; then return 0; fi
    fail 'The existing background job is not ready. Review status; it was not restarted automatically.'
  else
    [ "$?" -eq 2 ] || fail 'The existing LaunchAgent job could not be verified.'
  fi
  if [ -n "$sp_pid" ]; then
    native consent "Move the verified Screenpunk foreground server (PID $sp_pid) to background startup? Continue briefly disconnects this iPad, stops only that exact owned server, and starts the same pinned server with the unchanged credential. If background startup fails, setup will try to restore it in this Terminal. Cancel leaves the running connection unchanged."
    private_file "$sp_token"; private_file "$sp_server_receipt"
    native server-read "$sp_server_receipt" "$sp_session" || fail 'Cannot recheck the foreground ownership receipt.'
    [ "$(cat "$sp_session/server-pid")" = "$sp_pid" ] && [ "$(cat "$sp_session/server-start")" = "$sp_start" ] && [ "$(cat "$sp_session/server-tokenIdentity")" = "$(stat -f '%u:%Lp:%i' "$sp_token")" ] && [ "$(cat "$sp_session/server-tokenSHA256")" = "$(service_hash "$sp_token")" ] || fail 'Foreground credential ownership changed during review; nothing was stopped.'
    sp_migration_token_identity=$(stat -f '%u:%Lp:%i' "$sp_token"); sp_migration_token_hash=$(service_hash "$sp_token")
    [ "$(process_start "$sp_pid")" = "$sp_start" ] || fail 'The foreground process changed during review; nothing was stopped.'
    [ "$(lsof -nP -a -p "$sp_pid" -iTCP:4500 -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p')" = '127.0.0.1:4500' ] || fail 'The foreground listener changed during review; nothing was stopped.'
    sp_service_migrated=1
    kill "$sp_pid" || fail 'Could not stop the exact foreground server after approval.'
    sp_service_stop_attempt=0
    while [ -n "$(process_start "$sp_pid")" ] && [ "$sp_service_stop_attempt" -lt 20 ]; do sleep 0.1; sp_service_stop_attempt=$((sp_service_stop_attempt + 1)); done
    [ -z "$(process_start "$sp_pid")" ] || fail 'The approved foreground server did not stop; background startup was not attempted.'
    sp_pid=''; sp_start=''
  fi
  if [ -f "$sp_server_receipt" ]; then cp "$sp_server_receipt" "$sp_session/server-original.json"; native sync "$sp_session/server-original.json"; fi
  # A declined migration must never leave an autoload plist behind.
  if "$SP_LAUNCHCTL" list "$sp_service_label" >/dev/null 2>&1; then fail 'A job appeared during background review. It was not stopped; setup will restore the approved foreground connection if safe.'; fi
  sp_service_publication=$(native service-copy-plist "$sp_service_manifest") || fail 'Cannot safely publish the LaunchAgent plist.'
  if [ "$sp_service_publication" = created ]; then sp_service_plist_published=1; fi
  native service-status "$sp_service_manifest" starting
  sp_service_bootstrapped=0
  if "$SP_LAUNCHCTL" bootstrap "$sp_service_domain" "$sp_service_plist"; then sp_service_bootstrapped=1; sp_service_started_by_setup=1; fi
  if [ "$sp_service_bootstrapped" -eq 1 ] && service_wait_ready; then return 0; fi
  printf '%s\n' 'Background startup failed. Preserving the saved credential and restoring foreground operation.' >&2
  if ! service_bootout_owned; then fail 'Background job cleanup could not be verified. Saved credentials remain intact; review the service before starting another server.'; fi
  if [ "$sp_service_plist_published" -eq 1 ] && [ -e "$sp_service_plist" ]; then private_file "$sp_service_plist"; cmp -s "$sp_service_plist" "$sp_service_dir/agent-v4.plist" || fail 'Service plist changed during recovery.'; rm -f "$sp_service_plist"; fi
  native service-state "$sp_service_manifest" failed
  native service-status "$sp_service_manifest" startup-failed
  sp_server_lifecycle=foreground; sp_service_started_by_setup=0; sp_pid=''; sp_start=''
  return 0
}
service_run() {
  service_validate_files
  native service-status "$sp_service_manifest" preflight
  if ! { [ -x "$SP_CODEX" ] && [ "$(service_hash "$SP_CODEX")" = "$SP_SHA" ] && [ "$("$SP_CODEX" --version | awk '{print $NF}')" = "$SP_VERSION" ]; }; then
    native service-status "$sp_service_manifest" pinned-build-changed
    fail 'The pinned Codex build changed; background startup stopped for review.'
  fi
  [ "$(wc -c < "$sp_token" | tr -d '[:space:]')" -eq 65 ] && LC_ALL=C grep -Eq '^[0-9a-f]{64}$' "$sp_token" || fail 'The private saved credential changed.'
  [ ! -e "$sp_service_dir/instance.lock" ] || private_file "$sp_service_dir/instance.lock"
  exec 7<> "$sp_service_dir/instance.lock"
  /usr/bin/lockf -t 0 7 || fail 'Another background server instance owns the service lock.'
  [ -z "$(lsof -nP -a -iTCP:4500 -sTCP:LISTEN -t 2>/dev/null || :)" ] || fail 'Port 4500 already has a listener; background startup did not stop it.'
  native service-status "$sp_service_manifest" launching
  sp_start=$(process_start "$$"); [ -n "$sp_start" ] || fail 'Cannot record the background process start identity.'
  native service-server-write "$sp_service_manifest" "$sp_server_receipt" "$$" "$sp_start"
  cd "$CODEX_HOME/workspace"
  exec "$SP_CODEX" -c features.shell_tool=false -c features.unified_exec=false -c features.apps=false -c features.plugins=false -c features.hooks=false -c features.browser_use=false -c features.browser_use_external=false -c features.computer_use=false -c features.in_app_browser=false -c features.image_generation=false -c features.view_image=false -c features.multi_agent=false -c features.skill_search=false -c features.skill_mcp_dependency_install=false -c features.workspace_dependencies=false -c 'web_search="disabled"' -c project_doc_max_bytes=0 app-server --listen ws://127.0.0.1:4500 --ws-auth capability-token --ws-token-file "$sp_token"
}
service_manage() {
  service_validate_files
  case "$1" in
    status) if service_query_job; then service_verify_job_process; printf 'Screenpunk background job is loaded (PID %s). Mac must be logged in, awake and reachable.\n' "$sp_service_job_pid"; else [ "$?" -eq 2 ] || fail 'Unknown LaunchAgent job.'; printf '%s\n' 'Screenpunk background job is not loaded.'; fi;;
    start) if service_query_job; then service_verify_job_process; "$SP_LAUNCHCTL" kickstart "$sp_service_target"; else [ "$?" -eq 2 ] || fail 'Unknown LaunchAgent job.'; if [ ! -e "$sp_service_plist" ]; then native service-copy-plist "$sp_service_manifest"; fi; "$SP_LAUNCHCTL" bootstrap "$sp_service_domain" "$sp_service_plist"; fi; service_wait_ready || fail 'Background start failed; inspect local status and client connection diagnostics.';;
    restart) service_bootout_owned || fail 'Cannot verify the owned job for restart.'; if [ ! -e "$sp_service_plist" ]; then native service-copy-plist "$sp_service_manifest"; fi; "$SP_LAUNCHCTL" bootstrap "$sp_service_domain" "$sp_service_plist"; service_wait_ready || fail 'Background restart failed; saved credentials remain unchanged.';;
    uninstall) service_bootout_owned || fail 'Cannot verify the owned job for uninstall.'; native service-state "$sp_service_manifest" uninstalled; native service-status "$sp_service_manifest" uninstalled; rm -f "$sp_service_plist" "$sp_service_dir/manage-v4.sh" "$sp_service_dir/native-v4.js" "$sp_service_dir/agent-v4.plist"; printf '%s\n' 'Background startup removed. SSH grants, saved credential, Codex home and paired iPad settings were retained.';;
    *) fail 'Usage: manage-v4.sh status|start|restart|uninstall';;
  esac
}

# Reusable gated foreground launch, including restoration after an approved migration.
# Does not create/rotate credentials, stop listeners, or invoke a model request.
service_start_foreground() {
  [ -x "$SP_CODEX" ] && [ "$(service_hash "$SP_CODEX")" = "$SP_SHA" ] && [ "$("$SP_CODEX" --version | awk '{print $NF}')" = "$SP_VERSION" ] || return 1
  private_file "$sp_token"
  [ -z "$(lsof -nP -a -iTCP:4500 -sTCP:LISTEN -t 2>/dev/null || :)" ] || return 1
  if [ "$sp_service_migrated" -eq 1 ]; then
    [ "$(stat -f '%u:%Lp:%i' "$sp_token")" = "$sp_migration_token_identity" ] && [ "$(service_hash "$sp_token")" = "$sp_migration_token_hash" ] || return 1
  fi
  rm -f "$sp_session/start-server"
  (
    sp_gate_count=0
    while [ ! -f "$sp_session/start-server" ]; do [ "$sp_gate_count" -lt 100 ] || exit 1; sleep 0.1; sp_gate_count=$((sp_gate_count + 1)); done
    cd "$CODEX_HOME/workspace"
    exec "$SP_CODEX" -c features.shell_tool=false -c features.unified_exec=false -c features.apps=false -c features.plugins=false -c features.hooks=false -c features.browser_use=false -c features.browser_use_external=false -c features.computer_use=false -c features.in_app_browser=false -c features.image_generation=false -c features.view_image=false -c features.multi_agent=false -c features.skill_search=false -c features.skill_mcp_dependency_install=false -c features.workspace_dependencies=false -c 'web_search="disabled"' -c project_doc_max_bytes=0 app-server --listen ws://127.0.0.1:4500 --ws-auth capability-token --ws-token-file "$sp_token"
  ) 9>&- >/dev/null 2>&1 &
  sp_pid=$!; sp_started=1; sp_foreground_ready=0; sp_server_lifecycle=foreground; sp_start=$(process_start "$sp_pid")
  [ -n "$sp_start" ] || return 1
  if [ -f "$sp_server_receipt" ] && [ ! -f "$sp_session/server-original.json" ]; then cp "$sp_server_receipt" "$sp_session/server-original.json"; native sync "$sp_session/server-original.json" || return 1; fi
  native server-write "$sp_server_receipt" "$sp_pid" "$sp_start" "$(stat -f '%u:%Lp:%i' "$sp_token")" "$(service_hash "$sp_token")" "$SP_SHA" || return 1
  sp_newreceipt_hash=$(service_hash "$sp_server_receipt")
  : > "$sp_session/start-server"
  sp_attempt=0
  while [ "$sp_attempt" -lt 20 ]; do
    [ "$(process_start "$sp_pid")" = "$sp_start" ] || return 1
    sp_ready=$(lsof -nP -a -p "$sp_pid" -iTCP:4500 -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p' || :)
    [ "$sp_ready" = '127.0.0.1:4500' ] && break
    sleep 1; sp_attempt=$((sp_attempt + 1))
  done
  [ "$sp_ready" = '127.0.0.1:4500' ] || return 1
  sp_foreground_ready=1
}

# Only for a foreground child created by this exact setup process.
service_terminate_owned_child() {
  if [ -n "$1" ] && [ "$(process_start "$1")" = "$2" ]; then
    kill "$1" 2>/dev/null || :
    sp_terminate_count=0
    while [ "$(process_start "$1")" = "$2" ] && [ "$sp_terminate_count" -lt 20 ]; do sleep 0.1; sp_terminate_count=$((sp_terminate_count + 1)); done
    if [ "$(process_start "$1")" = "$2" ]; then kill -KILL "$1" 2>/dev/null || :; fi
  fi
  wait "$1" 2>/dev/null || :
}
service_paths
native() { "$SP_OSASCRIPT" -l JavaScript "$sp_service_dir/native-v4.js" "$@"; }
if [ "${1:-}" = run ]; then service_run; fi
sp_session=$(mktemp -d "$sp_service_dir/manage-session.XXXXXX")
cleanup() { sp_result=$?; rm -f "$sp_session/service-job.plist" "$sp_session/service-job-pid"; rmdir "$sp_session" 2>/dev/null || :; exit "$sp_result"; }
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
if [ -e "$CODEX_HOME/.setup.lock" ] || [ -L "$CODEX_HOME/.setup.lock" ]; then private_file "$CODEX_HOME/.setup.lock"; fi
exec 8<> "$CODEX_HOME/.setup.lock"
/usr/bin/lockf -t 0 8 || fail 'Another Screenpunk background-management action is running.'
service_manage "${1:-status}"
SCREENPUNK_SERVICE_CONTROL
native() { "$SP_OSASCRIPT" -l JavaScript "$sp_session/native.js" "$@"; }
# An acquired kernel lease proves no other setup display still owns the lease.
# Clear only declared private display files from verified prior script-owned sessions.
for sp_prior in "$CODEX_HOME"/setup-session.*; do
  [ -d "$sp_prior" ] && [ ! -L "$sp_prior" ] && [ "$sp_prior" != "$sp_session" ] || continue
  private_dir "$sp_prior"
  if [ -e "$sp_prior/.screenpunk-session.json" ] || [ -L "$sp_prior/.screenpunk-session.json" ]; then
    private_file "$sp_prior/.screenpunk-session.json"
    for sp_private in private-reply.json connection.png new-token; do
      if [ -e "$sp_prior/$sp_private" ] || [ -L "$sp_prior/$sp_private" ]; then private_file "$sp_prior/$sp_private"; fi
    done
    native session-clean "$sp_prior"
  fi
done
native session-start "$sp_session" "$$"
printf '%s\n' 'Select the PUBLIC setup request received from iPad. Nothing is uploaded.'
native choose "$sp_session/request-path"
sp_request=$(cat "$sp_session/request-path")
[ -f "$sp_request" ] && [ ! -L "$sp_request" ] || fail 'Select a regular public setup-request JSON file.'
[ "$(stat -f '%z' "$sp_request")" -le 8192 ] || fail 'Selected file is too large for the public iPad request. Choose Screenpunk-setup-request.json sent from the iPad, not the downloaded Mac setup script.'
native request "$sp_request" "$sp_session"
[ "$(ssh-keygen -lf "$sp_session/key.pub" -E sha256 | awk '{print $2}')" = "$(cat "$sp_session/key-digest")" ] || fail 'The public key digest does not match the request.'
# Check an already active Remote Login listener without enabling or restarting the service.
nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1 || fail 'Turn on Remote Login in System Settings > General > Sharing, allow this account, then run setup again. Screenpunk does not enable it.'
if dscl . -read /Groups/com.apple.access_ssh RecordName >/dev/null 2>&1; then
  dsmemberutil checkmembership -U "$sp_user" -G com.apple.access_ssh | grep -q 'is a member' || fail 'Allow this Mac account in Remote Login settings, then retry.'
fi
[ ! -L "$SP_HOSTKEY" ] || fail 'The public host key must not be a symbolic link.'
if [ ! -f "$SP_HOSTKEY" ]; then
  native consent 'The Mac has no public Ed25519 SSH host key. Continue authorizes sudo ssh-keygen -A to create missing system host keys only. Existing keys are never regenerated. Remote Login remains under your control.'
  "$SP_SUDO" ssh-keygen -A
fi
[ -f "$SP_HOSTKEY" ] && [ ! -L "$SP_HOSTKEY" ] && [ "$(stat -f '%u' "$SP_HOSTKEY")" = 0 ] || fail 'No public SSH host key is available. Review Remote Login and system host keys.'
sp_hostmode=$(stat -f '%Lp' "$SP_HOSTKEY"); [ "$((0$sp_hostmode & 022))" -eq 0 ] || fail 'The public host key is writable by another account.'
sp_hostpin=$(ssh-keygen -lf "$SP_HOSTKEY" -E sha256 | awk '{print $2}')
# Authentication is scoped to the dedicated home. Never copy global credentials.
if "$SP_CODEX" login status >/dev/null 2>&1; then printf '%s\n' 'Already signed in to the dedicated Screenpunk Codex home.'
else
  printf '%s\n' 'Sign in using the standard Codex browser flow for this dedicated Screenpunk home.'
  "$SP_CODEX" login
  "$SP_CODEX" login status >/dev/null 2>&1 || fail 'Codex sign-in was not confirmed. Retry after completing browser sign-in.'
fi
# Reuse a stopped earlier setup only after explicit review of its unchanged private bearer.
# Running unowned servers remain untouched; no creation history is inferred.
if { [ -e "$sp_token" ] || [ -L "$sp_token" ]; } && [ ! -e "$sp_server_receipt" ] && [ ! -L "$sp_server_receipt" ] && [ ! -e "$sp_token_receipt" ] && [ ! -L "$sp_token_receipt" ]; then
  private_file "$sp_token"
  [ "$(wc -c < "$sp_token" | tr -d '[:space:]')" -eq 65 ] && LC_ALL=C grep -Eq '^[0-9a-f]{64}$' "$sp_token" || fail 'The earlier saved bearer has an unexpected format; it was not changed.'
  sp_legacy_pid=$(lsof -nP -a -iTCP:4500 -sTCP:LISTEN -t 2>/dev/null | sort -u || :)
  if [ -z "$sp_legacy_pid" ]; then
    if nc -z -G 1 127.0.0.1 4500 >/dev/null 2>&1; then fail 'A live server cannot be identified for ownership review. Keep the working connection unchanged; setup did not stop anything.'; fi
    sp_legacy_identity=$(stat -f '%u:%Lp:%i' "$sp_token"); sp_legacy_hash=$(shasum -a 256 "$sp_token" | awk '{print $1}')
    native consent 'Reuse your saved Screenpunk connection credential? The earlier setup saved a private bearer but no ownership receipt, and no App Server is listening now. Continue records your approval to reuse this exact file unchanged and start the supported server using the startup mode you choose. Existing iPad credentials are not reset. Cancel keeps all saved data. No model request is sent.'
    private_file "$sp_token"
    [ "$(stat -f '%u:%Lp:%i' "$sp_token")" = "$sp_legacy_identity" ] && [ "$(shasum -a 256 "$sp_token" | awk '{print $1}')" = "$sp_legacy_hash" ] || fail 'The saved credential changed during review; nothing was adopted.'
    [ -z "$(lsof -nP -a -iTCP:4500 -sTCP:LISTEN -t 2>/dev/null || :)" ] || fail 'A listener appeared during review; no server was stopped.'
    if nc -z -G 1 127.0.0.1 4500 >/dev/null 2>&1; then fail 'A listener appeared during review; no server was stopped.'; fi
    [ ! -e "$sp_server_receipt" ] && [ ! -L "$sp_server_receipt" ] && [ ! -e "$sp_token_receipt" ] && [ ! -L "$sp_token_receipt" ] || fail 'Ownership changed during review; no receipt was overwritten.'
    native token-adopt "$sp_token_receipt" 0 not-started "$sp_legacy_identity" "$sp_legacy_hash" "$SP_SHA"
    printf '%s\n' 'Reusing the saved Screenpunk bearer unchanged; setup will start its foreground server.'
  else
    fail 'The earlier App Server is already running without ownership receipts. Keep it and your working connection unchanged. This upgrade needs manual ownership review; setup did not stop the server, rotate its bearer or add a key.'
  fi
fi
native consent "Authorize this iPad public key for this Mac account? Setup adds one restricted line to ~/.ssh/authorized_keys and, if absent, $SP_POLICY. The account-wide policy disables reverse TCP and Unix-socket forwarding for ALL SSH keys on $sp_user. The iPad key allows only local forwarding to 127.0.0.1:4500, with no shell, PTY or agent forwarding. Setup uses sudo for SSH policy validation, reuses an owned bearer/server, and asks separately whether to enable per-user background startup or keep App Server in this Terminal. No system daemon or helper app is installed."
printf 'Match User %s\n    AllowTcpForwarding local\n    PermitListen none\n    AllowStreamLocalForwarding no\nMatch all\n' "$sp_user" > "$sp_session/policy"
sp_policyhash=$(shasum -a 256 "$sp_session/policy" | awk '{print $1}')
private_dir "$HOME/.ssh"
if [ -e "$sp_keys" ] || [ -L "$sp_keys" ]; then private_file "$sp_keys"; fi
sp_keyline="restrict,port-forwarding,permitopen=\"127.0.0.1:4500\",command=\"/usr/bin/false\" $(cat "$sp_session/key.pub") Screenpunk-iPad"
printf '%s' "$sp_keyline" > "$sp_session/authorized-line"
sp_keyid=$(shasum -a 256 "$sp_session/key.pub" | awk '{print $1}')
sp_receipt="$CODEX_HOME/setup-receipts/$sp_keyid.json"
sp_keyplanned=0; sp_policyplanned=0; sp_tokenplanned=0
grep -Fqx -- "$sp_keyline" "$sp_keys" 2>/dev/null || sp_keyplanned=1
if [ ! -e "$SP_POLICY" ] && [ ! -L "$SP_POLICY" ]; then sp_policyplanned=1; fi
if [ ! -e "$sp_token" ] && [ ! -L "$sp_token" ]; then sp_tokenplanned=1; fi
if [ -e "$sp_receipt" ] || [ -L "$sp_receipt" ]; then private_file "$sp_receipt"; fi
# Durable nonsecret intent precedes privileged policy/key/token changes.
native receipt "$sp_receipt" "$sp_session" "$sp_keyplanned" "$SP_POLICY" "$sp_policyhash" "$sp_policyplanned" "$sp_server_receipt" "$sp_token" "$sp_tokenplanned"
if [ -e "$SP_POLICY" ] || [ -L "$SP_POLICY" ]; then
  [ ! -L "$SP_POLICY" ] && cmp -s "$sp_session/policy" "$SP_POLICY" || fail 'Existing Screenpunk SSH policy differs. No key was added; review that policy.'
else "$SP_SUDO" install -m 644 "$sp_session/policy" "$SP_POLICY"; sp_policy_added=1; native sync "$SP_POLICY"; fi
# A loopback-only -T check cannot prove restrictions across conditional LAN Match rules.
# Refuse unsupported conditionals/includes rather than granting a key under an unproved policy.
audit_ssh_configuration
"$SP_SUDO" "$SP_SSHD" -t || fail 'SSH configuration validation failed; check host keys and configuration.'
sp_effective=$("$SP_SUDO" "$SP_SSHD" -T -C "user=$sp_user,host=localhost,addr=127.0.0.1")
printf '%s\n' "$sp_effective" | awk '
$1 == "allowtcpforwarding" { tcp = ($2 == "local" && NF == 2) }
$1 == "permitlisten" { listen = ($2 == "none" && NF == 2) }
$1 == "allowstreamlocalforwarding" { stream = ($2 == "no" && NF == 2) }
$1 == "disableforwarding" { disabled = ($2 != "no") }
$1 == "pubkeyauthentication" { key = ($2 == "yes") }
END { exit !(tcp && listen && stream && !disabled && key) }' || fail 'Effective SSH policy is incompatible. No iPad key was added.'
# Never follow a symlink or replace an unknown token/receipt/listener.
if [ -e "$sp_token" ] || [ -L "$sp_token" ]; then
  private_file "$sp_token"
  if [ -e "$sp_server_receipt" ] || [ -L "$sp_server_receipt" ]; then private_file "$sp_server_receipt"; sp_readreceipt=$sp_server_receipt
  else private_file "$sp_token_receipt"; sp_readreceipt=$sp_token_receipt; fi
else
  [ ! -e "$sp_server_receipt" ] && [ ! -L "$sp_server_receipt" ] || fail 'Server receipt exists without its token. Review ownership before continuing.'
fi
sp_listener=$(lsof -nP -a -iTCP:4500 -sTCP:LISTEN -t 2>/dev/null | sort -u || :)
if [ -e "$sp_token" ]; then
  [ "$(wc -c < "$sp_token" | tr -d '[:space:]')" -eq 65 ] && LC_ALL=C grep -Eq '^[0-9a-f]{64}$' "$sp_token" || fail 'Saved bearer has an unexpected format; it was not rotated.'
  native server-read "$sp_readreceipt" "$sp_session"
  [ "$(cat "$sp_session/server-tokenIdentity")" = "$(stat -f '%u:%Lp:%i' "$sp_token")" ] && [ "$(cat "$sp_session/server-tokenSHA256")" = "$(shasum -a 256 "$sp_token" | awk '{print $1}')" ] || fail 'Saved bearer no longer matches its ownership receipt.'
  sp_savedpid=$(cat "$sp_session/server-pid"); sp_savedstart=$(cat "$sp_session/server-start")
  if [ -f "$sp_session/server-serverLifecycle" ]; then sp_server_lifecycle=background; fi
  if [ -n "$sp_listener" ]; then
    [ "$sp_listener" = "$sp_savedpid" ] && [ "$(process_start "$sp_savedpid")" = "$sp_savedstart" ] || fail 'Port 4500 belongs to an unverified process; nothing was stopped.'
    [ "$(lsof -nP -a -p "$sp_savedpid" -iTCP:4500 -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p')" = '127.0.0.1:4500' ] || fail 'Owned listener is not exclusively loopback.'
    sp_pid=$sp_savedpid; sp_start=$sp_savedstart
  else
    [ "$sp_savedpid" -eq 0 ] || [ -z "$(process_start "$sp_savedpid")" ] || fail 'Saved App Server is alive without its expected listener. Review it before retrying.'
  fi
else
  [ -z "$sp_listener" ] || fail 'Port 4500 is already occupied by an unknown process. Setup did not stop it.'
  native prepared-receipts "$CODEX_HOME/setup-receipts"
  if [ -e "$sp_token_receipt" ] || [ -L "$sp_token_receipt" ]; then
    private_file "$sp_token_receipt"; native server-read "$sp_token_receipt" "$sp_session"
    [ "$(cat "$sp_session/server-pid")" -eq 0 ] || fail 'Token provenance is not a prepared install.'
  fi
  openssl rand -hex 32 > "$sp_session/new-token"
  native sync "$sp_session/new-token"
  # A no-secret prepared receipt is durable BEFORE publishing the token inode.
  native server-write "$sp_token_receipt" 0 not-started "$(stat -f '%u:%Lp:%i' "$sp_session/new-token")" "$(shasum -a 256 "$sp_session/new-token" | awk '{print $1}')" "$SP_SHA"
  sp_tokenreceipt_hash=$(shasum -a 256 "$sp_token_receipt" | awk '{print $1}')
  mv -n "$sp_session/new-token" "$sp_token"
  [ ! -e "$sp_session/new-token" ] || fail 'A token appeared during setup; review its ownership.'
  sp_token_created=1
  native sync-rename "$sp_token" "$sp_session"
  sp_tokenidentity=$(stat -f '%u:%Lp:%i' "$sp_token"); sp_tokenhash=$(shasum -a 256 "$sp_token" | awk '{print $1}')
fi
[ -e "$sp_keys" ] || : > "$sp_keys"
if ! grep -Fqx -- "$sp_keyline" "$sp_keys"; then printf '\n%s\n' "$sp_keyline" >> "$sp_keys"; sp_key_added=1; native sync "$sp_keys"; fi
if [ "$sp_server_lifecycle" = background ]; then
  sp_service_mode=background
else
  sp_service_mode=$(native service-choice) || fail 'Background startup choice was cancelled; existing connection remains unchanged.'
fi
case "$sp_service_mode" in
  background) service_upgrade_v4_if_needed || fail 'Background helper repair did not complete. The existing server was not changed.'; service_start_background;;
  foreground) ;;
  *) fail 'Unknown server startup choice; nothing was stopped.';;
esac
if [ "$sp_server_lifecycle" = background ]; then
  sp_started=0
  if [ "$sp_service_started_by_setup" -eq 1 ]; then sp_newreceipt_hash=$(service_hash "$sp_server_receipt"); fi
fi
if [ -z "$sp_pid" ]; then service_start_foreground || fail 'App Server did not open its authenticated loopback listener.'; fi

sp_name=$(scutil --get ComputerName 2>/dev/null || printf '%s' "$sp_user Mac")
sp_localhost=$(scutil --get LocalHostName 2>/dev/null || :)
case "$sp_localhost" in ''|-*|*[!A-Za-z0-9-]*) fail 'Set a valid Mac LocalHostName in Sharing settings, then retry.';; esac
native metadata "$sp_session" "$sp_name" "$sp_localhost.local" "$sp_user" "$sp_hostpin" "$CODEX_HOME/workspace" "$sp_server_lifecycle"
native reply "$sp_session" "$sp_token"
native receipt-complete "$sp_receipt"
# Display dismissal/expiry is not authenticated iPad acknowledgement and never revokes access.
sp_handoff=1
printf '%s\n' 'Connection code is displayed locally. No bearer was printed, copied or uploaded.'
native display "$sp_session" || printf '%s\n' 'The local display closed. Rerun setup to create a new code; the selected server startup mode is unchanged.'
rm -f "$sp_session/private-reply.json" "$sp_session/connection.png"
if [ "$sp_server_lifecycle" = background ]; then
  printf '%s\n' 'Background startup is verified. Terminal can close. Keep this Mac signed in, awake and reachable. After reboot, sign in to the Mac before connecting.'
  printf 'Manage background startup: /bin/sh "%s/manage-v4.sh" status|start|restart|uninstall\n' "$sp_service_dir"
else
  printf '%s\n' 'Private display material cleared. Keep this Terminal open for App Server. Access persists until explicitly revoked using the private setup receipt.'
fi
exec 9>&-; sp_lock_held=0
if [ "$sp_server_lifecycle" = background ]; then
  : # The verified LaunchAgent owns the process; setup exits without stopping it.
elif [ "$sp_started" -eq 1 ]; then wait "$sp_pid"; else printf '%s\n' 'Reused the verified foreground App Server; keep its original Terminal open.'; fi
