# Cloud setup

You need a preview invitation and access to ChatGPT Work + Cloud or a dot.

1. **Connect.** Sign in on the iPad under **Settings → Account**. Choose **Cloud** under **Use for new requests**, then **Set up cloud listener**. Open the plugin link and connect using the same email.
2. **Start listening.** In ChatGPT, open **Work → Cloud** (or your dot), select the Screenpunk plugin, and send the copied listener request. Wait for confirmation that it’s listening with your account.
3. **Ask for a screen.** Return to the iPad. Hold three fingers, say “Show me a large clock,” then lift to send.

## Need help?

- **No subscription support:** use Work + Cloud or a dot. Local Codex tasks cannot run the listener.
- **Still waiting:** check that both apps use the same email and that the listener is active. After a connection interruption, return to the existing request. Use **Cancel** on the iPad if you no longer want it.
- **Plugin unavailable:** check your preview invitation.
- **Earlier screens:** open **Settings → Account → Saved libraries**. Previous Cloud libraries use Local.

The guide is always available under **Settings → Account → Set up cloud listener**.

## Listener recovery

When handling a `screenpunk.request.created` event, read the current state with `get_request`. Use the same request ID after reconnecting or after a tool call times out. Stop work when the request is explicitly cancelled, already has a result or application receipt, or has another authoritative terminal state. A pending request stays recoverable after its legacy `deadlineAt` timestamp. If a completion response is lost, check the existing request before attempting completion again.

## Before inviting users

Verify app access, account enrollment, plugin sharing, and a complete device request with a non-creator account. The current private development plugin needs sharing before other users can connect.

Listener environment: [OpenAI MCP Events](https://developers.openai.com/plugins/build/mcp-events#test-in-chatgpt).
