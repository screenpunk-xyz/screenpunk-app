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
