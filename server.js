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

// ─── Shared state file ──────────────────────────────────────────────────────

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
  for (const entry of Object.values(state.messages)) {
    peers.add(entry.from);
    peers.add(entry.to);
  }
  return [...peers];
}

// Clean old messages (>1 hour)
function cleanOldMessages() {
  const state = readState();
  const cutoff = Date.now() - 60 * 60 * 1000;
  let changed = false;
  for (const [id, entry] of Object.entries(state.messages)) {
    if (entry.createdAt < cutoff) {
      delete state.messages[id];
      changed = true;
    }
  }
  // Clean inbox references
  for (const peer of Object.keys(state.inbox)) {
    state.inbox[peer] = state.inbox[peer].filter(id => state.messages[id]);
    if (state.inbox[peer].length === 0) delete state.inbox[peer];
    changed = true;
  }
  if (changed) writeState(state);
}

// Run cleanup every 15 min
setInterval(cleanOldMessages, 15 * 60 * 1000);

// ─── Validate params ────────────────────────────────────────────────────────

function reqStr(value, name) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`Missing or invalid: ${name}`);
  }
  return value.trim();
}

// ─── MCP Server setup ───────────────────────────────────────────────────────

const server = new Server(
  { name: "reasonix-mcp-bridge", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "send_message",
      description: "Send a message to a peer. Returns immediately with a message ID. Use get_response to retrieve the peer's reply later.",
      inputSchema: {
        type: "object",
        properties: {
          peer_id:   { type: "string", description: "Recipient peer identifier (e.g., 'peer-b')" },
          message:   { type: "string", description: "Message content" },
          sender_id: { type: "string", description: "Your own peer identifier (e.g., 'peer-a')" },
        },
        required: ["peer_id", "message", "sender_id"],
      },
    },
    {
      name: "check_inbox",
      description: "List all pending messages addressed to you, with their IDs and sender info.",
      inputSchema: {
        type: "object",
        properties: {
          peer_id: { type: "string", description: "Your peer identifier" },
        },
        required: ["peer_id"],
      },
    },
    {
      name: "reply_to_message",
      description: "Reply to a message you received. Requires the message_id from check_inbox.",
      inputSchema: {
        type: "object",
        properties: {
          message_id: { type: "string", description: "ID of the message to reply to" },
          response:   { type: "string", description: "Your reply text" },
        },
        required: ["message_id", "response"],
      },
    },
    {
      name: "get_response",
      description: "Check if a reply is available for a sent message (use the message_id from send_message).",
      inputSchema: {
        type: "object",
        properties: {
          message_id: { type: "string", description: "Message ID from send_message" },
        },
        required: ["message_id"],
      },
    },
    {
      name: "list_peers",
      description: "List all known peer identifiers that have exchanged messages through the bridge.",
      inputSchema: {
        type: "object",
        properties: {},
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "send_message": {
      const peerId  = reqStr(args?.peer_id, "peer_id");
      const message = reqStr(args?.message, "message");
      const sender  = reqStr(args?.sender_id, "sender_id");
      const entry   = createMessage(sender, peerId, message);
      return {
        content: [{ type: "text", text: JSON.stringify({
          ok: true,
          message_id: entry.id,
          note: `Sent to ${peerId}. get_response("${entry.id}") to retrieve the reply.`,
        })}],
      };
    }

    case "check_inbox": {
      const peerId = reqStr(args?.peer_id, "peer_id");
      const items  = getInbox(peerId).map(e => ({
        message_id: e.id,
        from: e.from,
        message: e.message,
        has_reply: e.reply !== null,
        created_at: new Date(e.createdAt).toISOString(),
      }));
      return {
        content: [{ type: "text", text: JSON.stringify({ ok: true, messages: items })}],
      };
    }

    case "reply_to_message": {
      const mid  = reqStr(args?.message_id, "message_id");
      const resp = reqStr(args?.response, "response");
      return {
        content: [{ type: "text", text: JSON.stringify(replyToMessage(mid, resp)) }],
      };
    }

    case "get_response": {
      const mid = reqStr(args?.message_id, "message_id");
      return {
        content: [{ type: "text", text: JSON.stringify(getResponse(mid)) }],
      };
    }

    case "list_peers": {
      return {
        content: [{ type: "text", text: JSON.stringify({ ok: true, peers: listPeers() }) }],
      };
    }

    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

// ─── Connect via stdio transport ───────────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);
