# Reasonix MCP Bridge

An MCP server that lets multiple Reasonix instances on the **same machine** exchange messages. Each instance connects via stdio; they share state through `/tmp/reasonix-bridge/state.json`.

## Requirements

- **Node.js 20+** (v24.16.0 tested)
- **npm** (ships with Node.js)

## Install

On the target machine:

```bash
bash /path/to/install.sh
```

Or from this directory:

```bash
cd ~/.reasonix-mcp-bridge
bash install.sh
```

 ✅ MCP Bridge — Working 

Location:  ~/.reasonix-mcp-bridge/server.js 

Registered as MCP server:  reasonix-bridge  (stdio transport, takes effect next Reasonix launch)

## How it works 

Two Reasonix instances share state via  /tmp/reasonix-bridge/state.json . Each spawns the same MCP server process; they coordinate through the file.

### Tools available 

 Tool             What it does
 ──────────────── ───────────────────────────────────────────────
 send_message     Send a message to a peer. Returns a message_id.
 check_inbox      Check for pending messages addressed to you.
 reply_to_message Reply to a received message by its ID.
 get_response     Retrieve the reply for a sent message.
 list_peers       List all peers that have exchanged messages.


The installer:
1. Copies `server.js` and `package.json` to `~/.reasonix-mcp-bridge/`
2. Runs `npm install`
3. Registers the MCP server in Reasonix config (`~/.reasonix/config.json`)

## Usage

After restarting Reasonix, the `reasonix-bridge` tools are available:

### Peer A sends a message

```
send_message(peer_id="peer-b", message="Can you review this?", sender_id="peer-a")
```

Returns a `message_id`.

### Peer B reads and replies

```
check_inbox(peer_id="peer-b")
→ [{ message_id: "...", from: "peer-a", message: "Can you review this?" }]

reply_to_message(message_id="...", response="Looks good!")
```

### Peer A reads the reply

```
get_response(message_id="...")
→ { ok: true, reply: "Looks good!" }
```

## For cross-machine communication

The current design uses a shared temp file (`/tmp/reasonix-bridge/state.json`) — same-machine only. For two different machines, the state needs to be on a network filesystem (NFS, SSHFS) or the server needs a TCP transport instead.
