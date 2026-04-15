# morrowind-ai

LLM-driven NPC dialogue for **OpenMW 0.49** — persistent per-NPC memory, live conversation, runs alongside the unmodified game on Windows or Linux.

## What it does

- Press **H** near any NPC to lock onto them.
- Type in an external chat window → the NPC replies in-game using Gemini / OpenAI / Claude / Ollama.
- Every exchange is stored in a per-NPC ChromaDB vector collection, so NPCs remember you across sessions.

## Why this exists (the novel part)

OpenMW 0.49's Lua sandbox on Windows blocks `io` and writable `os` in global scripts, which kills every "write a file from Lua" IPC pattern. This project uses a **dual-channel bridge** that stays inside the sandbox:

- **Lua → Python**: `print('[MWAI_REQ] <json>')` — Python tails `openmw.log`.
- **Python → Lua**: Python atomically writes `ai_inbox/response.txt` inside a `data=` path; Lua reads it via `openmw.vfs.open()`.

Dedup uses monotonic `req_id` on both sides. No `io`, no external injectors, no modified engine.

Combined with per-NPC ChromaDB memory and a provider-agnostic agent layer, this is (to our knowledge) the first openly published OpenMW LLM dialogue mod that works under the Windows sandbox.

## Architecture

```
+------------------+         print('[MWAI_REQ] ...')        +---------------------+
| OpenMW Lua       | ---------------------------------> tail | openmw_log_bridge   |
| (ipc_client.lua, |                                         | (Python, asyncio)   |
|  dialogue_ui)    | <--- vfs.open('ai_inbox/response.txt') -|  + lore_agent       |
+------------------+                                         |  + NPCMemory (Chroma)|
                                                             +---------------------+
                                                                      |
                                                              provider (Gemini /
                                                               OpenAI / Claude /
                                                               Ollama / llama.cpp)
```

Linux users can also use the simpler `bridge.py` path (direct file IPC at `ipc/request.json`), since Linux OpenMW exposes `io` in global scripts.

## Layout

| Path | Purpose |
|---|---|
| `openmw-mod/` | Lua scripts — dialogue UI, IPC client, game-side handlers |
| `python/openmw_log_bridge.py` | Windows sandbox bridge (vfs + print) |
| `python/bridge.py` | Linux direct file-IPC bridge |
| `python/agents/lore_agent.py` | NPC dialogue generation |
| `python/memory/chroma_memory.py` | Per-NPC ChromaDB memory |
| `python/providers/` | Gemini / OpenAI / Anthropic / Ollama / llama.cpp |
| `python/config.yaml` | Per-agent provider + model selection |

## Install

1. Copy `openmw-mod/` to a path on disk (e.g. `C:\morrowind-ai-mod` or `~/morrowind-ai-mod`).
2. In `openmw.cfg` add:
   ```
   data="C:\morrowind-ai-mod"
   content=morrowind-ai.omwscripts
   ```
3. Put your API key in `~/.nemoclaw_env` (or export `GOOGLE_API_KEY` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`).
4. `cd python && pip install -r requirements.txt`
5. Run the bridge:
   - **Windows/WSL path**: `python3 python/openmw_log_bridge.py` + `python chat_window_vfs.py` (Windows).
   - **Linux path**: `python3 python/main.py`.
6. Launch OpenMW. In-game, press **H** near an NPC to lock.

## YouTube live-chat integration (optional, disabled by default)

The bridge can listen to a YouTube live stream's chat (via `pytchat`, no API key) and route viewer commands into the game as IPC events (e.g. summon an NPC, trigger weather, spawn a creature).

To enable:

1. `pip install pytchat`
2. Edit `python/config.yaml`:
   ```yaml
   stream:
     enabled: true
     youtube_video_id: "YOUR_LIVE_VIDEO_ID"
   ```
3. Restart `openmw_log_bridge.py`. Chat messages are logged to `logs/chat.log`; recognised commands write JSON events to `ipc/events/` for the Lua mod to consume.

Leave `enabled: false` for normal single-player use.

## Status

Working on: OpenMW 0.49 (Windows + Linux), Gemini 3.1 Flash Lite Preview, ChromaDB embedded.

## License

MIT.
