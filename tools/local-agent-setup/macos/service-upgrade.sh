# Resume only a still-owned V5 install with missing files, or an explicit uninstall.
# This verifies sources without running the removed helper or creating files.
# The normal installer fills missing owned paths only after fresh consent below.
service_review_incomplete() {
  sp_recovery_lifecycle=$1
  private_dir "$sp_service_dir"; private_file "$sp_service_manifest"; private_file "$sp_token"
  service_parent "$HOME/Library"; service_parent "$HOME/Library/LaunchAgents"
  native service-plist "$sp_session/service.plist" "$HOME" "$sp_uid" || fail 'Cannot review the expected background-service plist.'
  native service-validate "$sp_service_manifest" "$HOME" "$sp_uid" "$(stat -f '%u:%Lp:%i' "$sp_token")" "$(service_hash "$sp_token")" "$(service_hash "$sp_session/service-control.sh")" "$(service_hash "$sp_session/native.js")" "$(service_hash "$sp_session/service.plist")" || fail 'The incomplete service no longer matches its saved credential and reviewed sources. Nothing was restored.'
  for sp_reenable_pair in 'manage-v4.sh:700:service-control.sh' 'native-v4.js:600:native.js' 'agent-v4.plist:600:service.plist'; do
    sp_reenable_name=${sp_reenable_pair%%:*}; sp_reenable_tail=${sp_reenable_pair#*:}; sp_reenable_mode=${sp_reenable_tail%%:*}; sp_reenable_source=${sp_reenable_tail#*:}
    if [ -e "$sp_service_dir/$sp_reenable_name" ] || [ -L "$sp_service_dir/$sp_reenable_name" ]; then
      if [ "$sp_reenable_mode" = 700 ]; then service_private_control "$sp_service_dir/$sp_reenable_name"; else private_file "$sp_service_dir/$sp_reenable_name"; fi
      cmp -s "$sp_service_dir/$sp_reenable_name" "$sp_session/$sp_reenable_source" || fail 'An unexpected background-service file was not overwritten.'
    fi
  done
  if [ -e "$sp_service_plist" ] || [ -L "$sp_service_plist" ]; then
    private_file "$sp_service_plist"; cmp -s "$sp_service_plist" "$sp_session/service.plist" || fail 'An unknown LaunchAgent plist was not overwritten.'
  fi
  if "$SP_LAUNCHCTL" list "$sp_service_label" >/dev/null 2>&1; then fail 'A job uses the incomplete background-service label. Nothing was restored or stopped; review it first.'; fi
  [ "$(plutil -extract lifecycle raw -o - "$sp_service_manifest")" = "$sp_recovery_lifecycle" ] || fail 'Background-service state changed during review. Nothing was restored.'
  if [ "$sp_recovery_lifecycle" = prepared ]; then
    native consent 'Resume the verified interrupted Screenpunk background setup? Continue restores only its missing owned controller, native helper and LaunchAgent plist, then starts the same pinned server now and whenever you sign in. Your existing credential and SSH access stay unchanged. Your Mac must remain signed in, awake and reachable. Cancel leaves the interrupted setup unchanged.' || return 1
    return 0
  fi
  native consent 'Re-enable the verified Screenpunk background startup you previously uninstalled? Continue restores only the missing owned controller, native helper and LaunchAgent plist, then starts the same pinned server now and whenever you sign in. Your existing credential and SSH access stay unchanged. Your Mac must remain signed in, awake and reachable. Cancel leaves background startup uninstalled.' || return 1
}

# Setup-only V6 recovery and V5-compatible helper repair. Never embed this library in the unchanged V4 controller.
service_upgrade_v4_if_needed() {
  service_paths
  if [ ! -e "$sp_service_manifest" ] && [ ! -L "$sp_service_manifest" ]; then return 0; fi
  private_dir "$sp_service_dir"; private_file "$sp_service_manifest"
  sp_recovery_lifecycle=$(plutil -extract lifecycle raw -o - "$sp_service_manifest") || fail 'Cannot read background-service lifecycle.'
  if [ "$sp_recovery_lifecycle" = uninstalled ]; then
    service_review_incomplete uninstalled || return 1
    return 0
  fi
  if [ "$sp_recovery_lifecycle" = prepared ] && { [ ! -e "$sp_service_dir/manage-v4.sh" ] || [ ! -e "$sp_service_dir/native-v4.js" ] || [ ! -e "$sp_service_dir/agent-v4.plist" ]; }; then
    service_review_incomplete prepared || return 1
    return 0
  fi
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
