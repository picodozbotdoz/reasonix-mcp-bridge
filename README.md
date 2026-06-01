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
