import Foundation

/// Commands are displayed for the Mac owner to review and run; the app never executes them.
enum LocalAgentMacSetup {
    static let pinnedVersion = "0.164.0-alpha.11.1"
    static let pinnedSHA256 = "a04752e4d46a4d89e53e6f61c59c5349a638c8ce172ffbf391fd482b4d902a4e"
    static let binary = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    /// Public instructions only. Request/reply contents are never embedded in a URL.
    static func setupURL(baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/local/setup"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url!
    }
    /// Open the public review/download page on the Mac; that page owns the pinned script command.
    static func setupCommand(baseURL: URL) -> String {
        "/usr/bin/open " + quote(setupURL(baseURL: baseURL).absoluteString)
    }
    private static let prefix = """
    set -eu
    umask 077
    screenpunk_codex='\(binary)'
    test -x "$screenpunk_codex"
    test "$(shasum -a 256 "$screenpunk_codex" | awk '{print $1}')" = '\(pinnedSHA256)' || { echo 'Codex changed. Use the tested build or update Screenpunk’s version pin.' >&2; exit 1; }
    test "$("$screenpunk_codex" --version | awk '{print $NF}')" = '\(pinnedVersion)'
    export CODEX_HOME="$HOME/.codex/screenpunk-local"
    test ! -L "$CODEX_HOME" && test ! -L "$CODEX_HOME/workspace" || { echo 'Screenpunk requires a dedicated directory, not a symbolic link.' >&2; exit 1; }
    mkdir -p "$CODEX_HOME/workspace"
    chmod 700 "$CODEX_HOME" "$CODEX_HOME/workspace"
    """
    static func prepareCommands() -> String {
        script(prefix + """
        
        if "$screenpunk_codex" login status >/dev/null 2>&1; then
          printf 'Already signed in.\\n'
        else
          "$screenpunk_codex" login
          "$screenpunk_codex" login status >/dev/null 2>&1
        fi
        printf 'Screenpunk workspace: %s\\n' "$CODEX_HOME/workspace"
        """)
    }
    static func startCommands() -> String {
        let disabled = ["shell_tool", "unified_exec", "apps", "plugins", "hooks", "browser_use", "browser_use_external", "computer_use", "in_app_browser", "image_generation", "view_image", "multi_agent", "skill_search", "skill_mcp_dependency_install", "workspace_dependencies"].map { "-c features.\($0)=false" }.joined(separator: " ")
        return script(prefix + """
        
        if test -e "$CODEX_HOME/transport-token" || test -L "$CODEX_HOME/transport-token"; then
          test -f "$CODEX_HOME/transport-token" && test ! -L "$CODEX_HOME/transport-token" || { echo 'The Screenpunk token must be a regular private file.' >&2; exit 1; }
        else
          openssl rand -hex 32 > "$CODEX_HOME/transport-token"
        fi
        test "$(wc -c < "$CODEX_HOME/transport-token" | tr -d '[:space:]')" -eq 65 && LC_ALL=C grep -Eq '^[0-9a-f]{64}$' "$CODEX_HOME/transport-token" || { echo 'The saved Screenpunk token has an unexpected format. Review the token file before continuing.' >&2; exit 1; }
        chmod 600 "$CODEX_HOME/transport-token"
        printf 'Keep this Terminal open. The private bearer remains in the dedicated transport-token file; never upload it.\\n'
        cd "$CODEX_HOME/workspace"
        exec "$screenpunk_codex" \(disabled) -c 'web_search="disabled"' -c project_doc_max_bytes=0 app-server --listen ws://127.0.0.1:4500 --ws-auth capability-token --ws-token-file "$CODEX_HOME/transport-token"
        """)
    }
    static func authorizeKeyCommand(publicKey: String) -> String {
        guard let line = authorizedLine(publicKey) else { return "# The iPad public key is unavailable. Close setup and try again." }
        return script("""
        set -eu
        umask 077
        screenpunk_user=$(id -un)
        case "$screenpunk_user" in ''|*[!a-zA-Z0-9_-]*) echo 'Unsupported account short name' >&2; exit 1;; esac
        screenpunk_policy='/etc/ssh/sshd_config.d/090-screenpunk-local.conf'
        screenpunk_config=$(mktemp)
        screenpunk_installed=0
        screenpunk_verified=0
        screenpunk_cleanup() {
          rm -f "$screenpunk_config"
          if test "$screenpunk_installed" -eq 1 && test "$screenpunk_verified" -eq 0; then
            sudo rm -f "$screenpunk_policy"
          fi
        }
        trap screenpunk_cleanup EXIT
        trap 'exit 1' HUP INT TERM
        # This account's reverse TCP and Unix-socket forwards will be disabled.
        printf 'Match User %s\\n    AllowTcpForwarding local\\n    PermitListen none\\n    AllowStreamLocalForwarding no\\nMatch all\\n' "$screenpunk_user" > "$screenpunk_config"
        if test -e "$screenpunk_policy" || test -L "$screenpunk_policy"; then
          if test -L "$screenpunk_policy" || ! cmp -s "$screenpunk_config" "$screenpunk_policy"; then
            echo 'Screenpunk SSH policy already exists with different settings. Review it before continuing; no iPad key was added.' >&2
            exit 1
          fi
        else
          sudo install -m 644 "$screenpunk_config" "$screenpunk_policy"
          screenpunk_installed=1
        fi
        sudo /usr/sbin/sshd -t
        screenpunk_effective=$(sudo /usr/sbin/sshd -T -C "user=$screenpunk_user,host=localhost,addr=127.0.0.1")
        if ! printf '%s\\n' "$screenpunk_effective" | awk '
          $1 == "allowtcpforwarding" { tcp = ($2 == "local") }
          $1 == "permitlisten" { listen = ($2 == "none" && NF == 2) }
          $1 == "allowstreamlocalforwarding" { stream = ($2 == "no") }
          $1 == "disableforwarding" { disabled = ($2 != "no") }
          END { exit !(tcp && listen && stream && !disabled) }'; then
          echo 'Effective SSH forwarding settings do not match Screenpunk requirements. No iPad key was added.' >&2
          exit 1
        fi
        screenpunk_verified=1
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        touch "$HOME/.ssh/authorized_keys"
        chmod 600 "$HOME/.ssh/authorized_keys"
        screenpunk_key=\(quote(line))
        if ! grep -Fqx -- "$screenpunk_key" "$HOME/.ssh/authorized_keys"; then
          printf '\\n%s\\n' "$screenpunk_key" >> "$HOME/.ssh/authorized_keys"
        fi
        printf 'Screenpunk iPad key authorized for 127.0.0.1:4500 only.\\n'
        """)
    }
    static func revokeKeyCommand(publicKey: String) -> String {
        guard let line = authorizedLine(publicKey) else { return "# Remove this iPad’s Screenpunk public key from ~/.ssh/authorized_keys on the Mac." }
        return script("""
        set -eu
        umask 077
        screenpunk_keys="$HOME/.ssh/authorized_keys"
        test -f "$screenpunk_keys" && test ! -L "$screenpunk_keys" || { echo 'Review the authorized_keys file directly; it is absent or is a symbolic link.' >&2; exit 1; }
        screenpunk_copy=$(mktemp "$HOME/.ssh/screenpunk-revoke.XXXXXX")
        trap 'rm -f "$screenpunk_copy"' EXIT
        trap 'exit 1' HUP INT TERM
        grep -Fvx -- \(quote(line)) "$screenpunk_keys" > "$screenpunk_copy" || test "$?" -eq 1
        mv -f "$screenpunk_copy" "$screenpunk_keys"
        """)
    }
    private static func authorizedLine(_ key: String) -> String? {
        guard key.utf8.count <= 4096, !key.contains("\n"), !key.contains("\r"), !key.contains("\0") else { return nil }
        let parts = key.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2, parts[0] == "ssh-ed25519", let bytes = Data(base64Encoded: String(parts[1])), bytes.count == 51, bytes.base64EncodedString() == String(parts[1]),
              Array(bytes.prefix(19)) == [0,0,0,11] + Array("ssh-ed25519".utf8) + [0,0,0,32] else { return nil }
        // Strip arbitrary comments so no supplied string becomes shell code or an SSH option.
        return "restrict,port-forwarding,permitopen=\"127.0.0.1:4500\",command=\"/usr/bin/false\" ssh-ed25519 \(parts[1]) Screenpunk-iPad"
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private static func script(_ body: String) -> String { "/bin/sh <<'SCREENPUNK_SETUP'\n" + body + "\nSCREENPUNK_SETUP" }
}
