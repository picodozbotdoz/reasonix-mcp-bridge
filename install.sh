#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Reasonix MCP Bridge — Installer
# Installs the bridge server and registers it as an MCP server for Reasonix.
# Run: curl -fsSL <url> | bash
# Or:  bash install.sh
# ──────────────────────────────────────────────────────────────────────────────

INSTALL_DIR="${INSTALL_DIR:-$HOME/.reasonix-mcp-bridge}"
REASONIX_CONFIG="${REASONIX_CONFIG:-$HOME/.reasonix/config.json}"

echo "==> Installing Reasonix MCP Bridge to: $INSTALL_DIR"

# 1. Create install directory
mkdir -p "$INSTALL_DIR"

# 2. Write package.json (self-contained — this script carries all files)
cat > "$INSTALL_DIR/package.json" << 'PKGJSON'
{
  "name": "reasonix-mcp-bridge",
  "version": "1.0.0",
  "description": "MCP bridge for Reasonix-to-Reasonix communication",
  "type": "module",
  "private": true,
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.18.0"
  }
}
PKGJSON

# 3. Write server.js
cat > "$INSTALL_DIR/server.js" << 'SRVJS'
#!/usr/bin/env node
/**
 * Reasonix MCP Bridge — stdio + shared-file transport
 * 
 * Each Reasonix instance spawns this as an MCP server (add_mcp_server with stdio).
 * All server processes share state via /tmp/reasonix-bridge/.
 * Tools expose message passing between peers (peer-a ↔ peer-b).
 */
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const STATE_DIR = "/tmp/reasonix-bridge";
const STATE_FILE = path.join(STATE_DIR, "state.json");

function ensureStateDir() {
  if (!fs.existsSync(STATE_DIR)) fs.mkdirSync(STATE_DIR, { recursive: true });
}

function readState() {
  try {
    ensureStateDir();
    const raw = fs.readFileSync(STATE_FILE, "utf-8");
    return JSON.parse(raw);
  } catch {
    return { messages: {}, inbox: {} };
  }
}

function writeState(state) {
  ensureStateDir();
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2), "utf-8");
}

function createMessage(from, to, text) {
  const state = readState();
  const id = crypto.randomUUID();
  const entry = { id, from, to, message: text, reply: null, createdAt: Date.now() };
  state.messages[id] = entry;
  if (!state.inbox[to]) state.inbox[to] = [];
  state.inbox[to].push(id);
  writeState(state);
  return entry;
}

function getInbox(peerId) {
  const state = readState();
  const ids = state.inbox[peerId] || [];
  return ids.map(id => state.messages[id]).filter(Boolean);
}

function replyToMessage(messageId, replyText) {
  const state = readState();
  const entry = state.messages[messageId];
  if (!entry) return { ok: false, error: "message not found" };
  if (entry.reply !== null) return { ok: false, error: "already replied" };
  entry.reply = replyText;
  writeState(state);
  return { ok: true };
}

function getResponse(messageId) {
  const state = readState();
  const entry = state.messages[messageId];
  if (!entry) return { ok: false, error: "message not found" };
  if (entry.reply === null) return { ok: false, error: "no reply yet" };
  return { ok: true, reply: entry.reply, from: entry.from, message: entry.message };
}

function listPeers() {
  const state = readState();
  const peers = new Set();
  for (const entry of Object.values(state.messages)) peers.add(entry.from), peers.add(entry.to);
  return [...peers];
}

function cleanOldMessages() {
  const state = readState();
  const cutoff = Date.now() - 60 * 60 * 1000;
  let changed = false;
  for (const [id, entry] of Object.entries(state.messages)) {
    if (entry.createdAt < cutoff) { delete state.messages[id]; changed = true; }
  }
  for (const peer of Object.keys(state.inbox)) {
    state.inbox[peer] = state.inbox[peer].filter(id => state.messages[id]);
    if (state.inbox[peer].length === 0) delete state.inbox[peer];
    changed = true;
  }
  if (changed) writeState(state);
}
setInterval(cleanOldMessages, 15 * 60 * 1000);

function reqStr(value, name) {
  if (typeof value !== "string" || value.trim().length === 0) throw new Error(`Missing or invalid: ${name}`);
  return value.trim();
}

const server = new Server(
  { name: "reasonix-mcp-bridge", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    { name: "send_message", description: "Send a message to a peer. Returns a message_id. Use get_response later to retrieve the peer's reply.", inputSchema: { type: "object", properties: { peer_id: { type: "string", description: "Recipient peer (e.g. 'peer-b')" }, message: { type: "string", description: "Message content" }, sender_id: { type: "string", description: "Your peer identifier (e.g. 'peer-a')" } }, required: ["peer_id", "message", "sender_id"] } },
    { name: "check_inbox", description: "List pending messages addressed to you.", inputSchema: { type: "object", properties: { peer_id: { type: "string", description: "Your peer identifier" } }, required: ["peer_id"] } },
    { name: "reply_to_message", description: "Reply to a received message by its ID.", inputSchema: { type: "object", properties: { message_id: { type: "string" }, response: { type: "string" } }, required: ["message_id", "response"] } },
    { name: "get_response", description: "Check if a reply is available for a sent message.", inputSchema: { type: "object", properties: { message_id: { type: "string" } }, required: ["message_id"] } },
    { name: "list_peers", description: "List all known peers.", inputSchema: { type: "object", properties: {} } },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  switch (name) {
    case "send_message": {
      const peerId = reqStr(args?.peer_id, "peer_id"), message = reqStr(args?.message, "message"), sender = reqStr(args?.sender_id, "sender_id");
      const entry = createMessage(sender, peerId, message);
      return { content: [{ type: "text", text: JSON.stringify({ ok: true, message_id: entry.id, note: `Sent to ${peerId}. get_response("${entry.id}") to retrieve the reply.` }) }] };
    }
    case "check_inbox": {
      const peerId = reqStr(args?.peer_id, "peer_id");
      const items = getInbox(peerId).map(e => ({ message_id: e.id, from: e.from, message: e.message, has_reply: e.reply !== null, created_at: new Date(e.createdAt).toISOString() }));
      return { content: [{ type: "text", text: JSON.stringify({ ok: true, messages: items }) }] };
    }
    case "reply_to_message": {
      return { content: [{ type: "text", text: JSON.stringify(replyToMessage(reqStr(args?.message_id, "message_id"), reqStr(args?.response, "response"))) }] };
    }
    case "get_response": {
      return { content: [{ type: "text", text: JSON.stringify(getResponse(reqStr(args?.message_id, "message_id"))) }] };
    }
    case "list_peers": {
      return { content: [{ type: "text", text: JSON.stringify({ ok: true, peers: listPeers() }) }] };
    }
    default: throw new Error(`Unknown tool: ${name}`);
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
SRVJS

chmod +x "$INSTALL_DIR/server.js"

# 4. Install npm dependencies
echo "==> Installing npm dependencies..."
cd "$INSTALL_DIR" && npm install --omit=dev 2>&1

# 5. Register with Reasonix config
echo "==> Registering MCP server with Reasonix..."
if [ -f "$REASONIX_CONFIG" ]; then
  # Add entry to mcp array if not already present
  TMP=$(mktemp)
  node -e "
    const cfg = JSON.parse(require('fs').readFileSync('$REASONIX_CONFIG','utf-8'));
    if (!cfg.mcp) cfg.mcp = [];
    const exists = cfg.mcp.find(e => e.name === 'reasonix-bridge');
    if (!exists) {
      cfg.mcp.push({
        name: 'reasonix-bridge',
        transport: 'stdio',
        command: 'node',
        args: ['$INSTALL_DIR/server.js']
      });
      require('fs').writeFileSync('$REASONIX_CONFIG', JSON.stringify(cfg, null, 2) + '\n');
      console.log('  ✓ registered');
    } else {
      console.log('  already registered');
    }
  " 2>&1
  rm -f "$TMP"
else
  echo "  ! Reasonix config not found at $REASONIX_CONFIG"
  echo "    Register manually after Reasonix is installed:"
  echo "    add_mcp_server(name=\"reasonix-bridge\", transport=\"stdio\", command=\"node\", args=[\"$INSTALL_DIR/server.js\"])"
fi

echo ""
echo "==> Done! Reasonix MCP Bridge installed at: $INSTALL_DIR"
echo ""
echo "Next step: Restart Reasonix so the MCP server loads."
echo "Then from any Reasonix session:"
echo "  send_message(peer_id=\"peer-b\", message=\"hello\", sender_id=\"peer-a\")"
echo "  check_inbox(peer_id=\"peer-b\")"
echo "  reply_to_message(message_id=\"...\", response=\"hi back\")"
echo "  get_response(message_id=\"...\")"
