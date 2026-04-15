"""
openmw_log_bridge.py — Windows-compatible IPC bridge for OpenMW 0.49.

Why this exists:
  The OpenMW 0.49 Lua sandbox on Windows does NOT expose `io` or a writeable
  `os`. Global scripts can't touch arbitrary files. So we use:

    Lua  -> Python : print('[MWAI_REQ] <json>')   (tagged line in openmw.log)
    Python -> Lua  : write C:\\morrowind-ai-mod\\ai_inbox\\response.txt, which
                     the Lua VFS can read because C:\\morrowind-ai-mod is a
                     data= path in openmw.cfg.

This script tails openmw.log, dispatches tagged lines to the existing
lore_agent + memory, and atomically overwrites response.txt with a new
`req_id` so the Lua side can dedup.

Run as a standalone process (do NOT restart mw-bridge; the WSL IPC path is
owned by another agent). This is an additive alternative path.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import pathlib
import re
import tempfile
import time
from datetime import datetime, timezone
from typing import Optional

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# WSL-visible paths for Windows OpenMW install
OPENMW_LOG = pathlib.Path(
    "/mnt/c/Users/rneeb/Documents/My Games/OpenMW/openmw.log"
)
MOD_ROOT   = pathlib.Path("/mnt/c/morrowind-ai-mod")
INBOX_DIR  = MOD_ROOT / "ai_inbox"
RESPONSE_FILE = INBOX_DIR / "response.txt"
PLAYER_TEXT_FILE = INBOX_DIR / "player_text.txt"  # written by chat_window_vfs.py

# Lua tag prefixes emitted via print()
REQ_RE = re.compile(r"\[MWAI_REQ\]\s+(\{.*\})\s*$")


def _atomic_write_text(path: pathlib.Path, text: str) -> None:
    """Write then rename so the Lua VFS never sees a half-flushed file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp_", suffix=".txt")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class OpenMWLogBridge:
    """Tail openmw.log, dispatch to lore_agent, write inbox responses."""

    def __init__(self, config: dict, lore_agent, memory) -> None:
        self.config = config
        self.lore_agent = lore_agent
        self.memory = memory
        self._locked_npc: dict = {}  # most recent lock_npc context
        self._seen_req_ids: set[str] = set()
        self._counter: int = 0
        INBOX_DIR.mkdir(parents=True, exist_ok=True)
        logger.info("OpenMWLogBridge ready (log=%s inbox=%s)", OPENMW_LOG, RESPONSE_FILE)

    # ------------------------------------------------------------------ tail

    async def run(self) -> None:
        # Run log-tail, player-text watcher, and (optional) YouTube chat concurrently.
        tasks = [self._run_log_tail(), self._run_player_text_watch()]

        stream_cfg = self.config.get("stream", {}) or {}
        if stream_cfg.get("enabled") and stream_cfg.get("youtube_video_id"):
            try:
                from stream.youtube_chat import YouTubeChatListener  # type: ignore
                from stream.chat_commands import ChatCommandHandler  # type: ignore
                handler = ChatCommandHandler(self.config)
                listener = YouTubeChatListener(
                    {"video_id": stream_cfg["youtube_video_id"]},
                    handler,
                )
                tasks.append(listener.start())
                logger.info("YouTube chat listener enabled (video_id=%s)",
                            stream_cfg["youtube_video_id"])
            except Exception as exc:  # noqa: BLE001
                logger.error("Could not start YouTube chat listener: %s", exc)
        else:
            logger.info("YouTube chat disabled (stream.enabled=false or no video_id)")

        await asyncio.gather(*tasks)

    async def _run_player_text_watch(self) -> None:
        """
        Watch ai_inbox/player_text.txt for text entered by the external chat
        window (chat_window_vfs.py). Each new file is treated as one dialogue
        request against the most recently locked NPC.
        """
        last_mtime = 0.0
        while True:
            try:
                if PLAYER_TEXT_FILE.exists():
                    mtime = PLAYER_TEXT_FILE.stat().st_mtime
                    if mtime != last_mtime:
                        last_mtime = mtime
                        text = PLAYER_TEXT_FILE.read_text(encoding="utf-8").strip()
                        if text:
                            self._counter += 1
                            req = {
                                "req_id": f"chat-{int(time.time())}-{self._counter}",
                                "type": "dialogue",
                                "player_text": text,
                            }
                            await self._handle_dialogue(req)
            except OSError as exc:
                logger.warning("player_text watch error: %s", exc)
            await asyncio.sleep(0.25)

    async def _run_log_tail(self) -> None:
        logger.info("OpenMWLogBridge tailing %s", OPENMW_LOG)
        # Wait for log file to exist
        while not OPENMW_LOG.exists():
            await asyncio.sleep(1.0)

        # Start at end of file so we don't re-process old runs
        with OPENMW_LOG.open("r", encoding="utf-8", errors="replace") as fh:
            fh.seek(0, os.SEEK_END)
            pos = fh.tell()

            while True:
                try:
                    fh.seek(pos)
                    chunk = fh.read()
                    if chunk:
                        pos = fh.tell()
                        for line in chunk.splitlines():
                            m = REQ_RE.search(line)
                            if m:
                                await self._handle_request_line(m.group(1))
                    else:
                        # Detect log rotation / truncation
                        try:
                            size = OPENMW_LOG.stat().st_size
                            if size < pos:
                                logger.info("openmw.log truncated; rewinding")
                                pos = 0
                        except OSError:
                            pass
                        await asyncio.sleep(0.25)
                except asyncio.CancelledError:
                    logger.info("OpenMWLogBridge cancelled")
                    return
                except Exception as exc:  # noqa: BLE001
                    logger.error("tail error: %s", exc, exc_info=True)
                    await asyncio.sleep(1.0)

    # ------------------------------------------------------------- dispatch

    async def _handle_request_line(self, payload: str) -> None:
        try:
            req = json.loads(payload)
        except json.JSONDecodeError as exc:
            logger.warning("bad MWAI_REQ json: %s (%s)", exc, payload[:120])
            return

        rid = str(req.get("req_id") or "")
        if not rid or rid in self._seen_req_ids:
            return
        self._seen_req_ids.add(rid)
        # cap memory
        if len(self._seen_req_ids) > 512:
            self._seen_req_ids = set(list(self._seen_req_ids)[-256:])

        rtype = req.get("type", "dialogue")
        if rtype == "lock_npc":
            self._locked_npc = req
            logger.info("lock_npc: %s (%s)", req.get("npc_name"), req.get("npc_id"))
            return
        if rtype == "dialogue":
            await self._handle_dialogue(req)
            return
        logger.warning("unknown MWAI type '%s'", rtype)

    async def _handle_dialogue(self, req: dict) -> None:
        ctx = self._locked_npc or {}
        npc_id = req.get("npc_id") or ctx.get("npc_id") or "unknown_npc"
        location = req.get("location") or ctx.get("location") or "unknown"
        player_text = req.get("player_text", "")

        history = self.memory.get_history(
            npc_id, limit=self.config.get("memory", {}).get("history_limit", 10)
        )

        try:
            agent_request = {
                "npc_id": npc_id,
                "npc_name": ctx.get("npc_name", npc_id),
                "npc_race": ctx.get("npc_race", "Dunmer"),
                "npc_class": ctx.get("npc_class", "Commoner"),
                "npc_faction": ctx.get("npc_faction", ""),
                "player_input": player_text,
                "location": location,
                "conversation_history": history,
            }
            result = await self.lore_agent.generate_response(
                agent_request, memory_context=history
            )
            npc_response = (
                result.get("response", "...") if isinstance(result, dict) else str(result)
            )
        except Exception as exc:  # noqa: BLE001
            logger.error("lore_agent failed: %s", exc, exc_info=True)
            npc_response = "..."

        self.memory.store_exchange(npc_id, player_text, npc_response, location)

        # Reply req_id = echo of request so Lua dedup sees each new reply.
        reply = {
            "req_id": req.get("req_id"),
            "type": "dialogue",
            "npc_id": npc_id,
            "npc_response": npc_response,
            "location": location,
            "timestamp": _now_iso(),
        }
        try:
            _atomic_write_text(RESPONSE_FILE, json.dumps(reply, ensure_ascii=False))
            logger.info("wrote inbox response for req_id=%s", reply["req_id"])
        except OSError as exc:
            logger.error("could not write inbox response: %s", exc)


# ----------------------------------------------------------- optional entry

async def _main() -> None:
    import yaml
    from agents.lore_agent import LoreAgent  # type: ignore
    from memory.chroma_memory import NPCMemory  # type: ignore

    logging.basicConfig(level=logging.INFO)
    cfg = yaml.safe_load(open("config.yaml"))
    mem = NPCMemory(cfg["memory"]["chroma_dir"])
    lore = LoreAgent(cfg)
    bridge = OpenMWLogBridge(cfg, lore, mem)
    await bridge.run()


if __name__ == "__main__":
    asyncio.run(_main())
