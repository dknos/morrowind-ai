"""
chroma_memory.py — ChromaDB-backed NPC memory for the Morrowind AI system.

Each NPC gets its own ChromaDB collection. Exchanges (player text + NPC response)
are stored as documents with metadata for retrieval and summarisation.

IMPORTANT: Uses ChromaDB embedded (PersistentClient), NOT Qdrant.
Qdrant is a shared swarm service — never use it here.
"""

import logging
import re
import time
from datetime import datetime, timezone
from typing import Optional

import chromadb

logger = logging.getLogger(__name__)


def _safe_collection_name(npc_id: str) -> str:
    """
    ChromaDB collection names must be 3-63 chars, start/end with alphanumeric,
    and contain only alphanumerics, underscores, or hyphens.
    Sanitise npc_id to meet these constraints.
    """
    # Replace any non-alphanumeric/underscore chars with underscore
    safe = re.sub(r"[^a-zA-Z0-9_-]", "_", npc_id)
    # Ensure it starts and ends with alphanumeric
    safe = re.sub(r"^[^a-zA-Z0-9]+", "", safe)
    safe = re.sub(r"[^a-zA-Z0-9]+$", "", safe)
    # Prefix to guarantee minimum length and a valid leading char
    safe = f"npc_{safe}" if safe else "npc_unknown"
    # Truncate to 63 chars
    return safe[:63]


class NPCMemory:
    """
    Persistent NPC memory backed by a local ChromaDB instance.

    Each NPC gets its own collection. Exchanges are stored with full metadata
    so they can be retrieved by recency (get_history) or semantic similarity
    (get_npc_summary).
    """

    def __init__(self, persist_dir: str = "/home/nemoclaw/morrowind-ai/chroma") -> None:
        self.persist_dir = persist_dir
        self.client = chromadb.PersistentClient(path=persist_dir)
        logger.info("NPCMemory initialised at %s", persist_dir)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _collection(self, npc_id: str):
        """Return (creating if needed) the ChromaDB collection for this NPC."""
        name = _safe_collection_name(npc_id)
        return self.client.get_or_create_collection(name=name)

    def _make_doc_id(self) -> str:
        """Generate a unique document ID based on current time."""
        return f"exchange_{int(time.time() * 1000)}"

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def store_exchange(
        self,
        npc_id: str,
        player_text: str,
        npc_response: str,
        location: str,
    ) -> None:
        """
        Persist a single player↔NPC exchange.

        Stored as:
          document: "Player: {player_text}\\nNPC: {npc_response}"
          metadata: {player_text, npc_response, location, timestamp, npc_id}
        """
        collection = self._collection(npc_id)
        timestamp = datetime.now(timezone.utc).isoformat()
        document = f"Player: {player_text}\nNPC: {npc_response}"

        doc_id = self._make_doc_id()
        collection.add(
            ids=[doc_id],
            documents=[document],
            metadatas=[
                {
                    "player_text": player_text,
                    "npc_response": npc_response,
                    "location": location,
                    "timestamp": timestamp,
                    "npc_id": npc_id,
                }
            ],
        )
        logger.debug(
            "Stored exchange for NPC '%s' at %s (doc_id=%s)", npc_id, location, doc_id
        )

    def get_history(self, npc_id: str, limit: int = 10) -> list[dict]:
        """
        Return the most recent exchanges with this NPC, newest-last.

        Returns:
            [{"player": str, "npc": str, "location": str, "timestamp": str}, ...]
        """
        collection = self._collection(npc_id)

        count = collection.count()
        if count == 0:
            return []

        # Fetch ALL documents then sort by timestamp in Python.
        # ChromaDB has no ORDER BY, and passing limit=n would return an
        # arbitrary n (not the n most recent), so we must fetch everything
        # and slice after sorting.
        result = collection.get(
            include=["metadatas"],
        )

        if not result or not result.get("metadatas"):
            return []

        # Sort ascending by timestamp string (ISO-8601 sorts lexicographically)
        metadatas = sorted(result["metadatas"], key=lambda m: m.get("timestamp", ""))

        # Return the most recent `limit` entries newest-last
        return [
            {
                "player": m.get("player_text", ""),
                "npc": m.get("npc_response", ""),
                "location": m.get("location", ""),
                "timestamp": m.get("timestamp", ""),
            }
            for m in metadatas[-limit:]
        ]

    def get_npc_summary(self, npc_id: str) -> str:
        """
        Return a prose summary of what this NPC knows about the player,
        derived from the most semantically relevant stored exchanges.

        Used by lore_agent to seed its context window.
        """
        collection = self._collection(npc_id)
        count = collection.count()

        if count == 0:
            return f"No prior interactions recorded for NPC '{npc_id}'."

        # Semantic search: pull exchanges most relevant to player knowledge
        query = "what does this NPC know about the player"
        n_results = min(5, count)

        try:
            result = collection.query(
                query_texts=[query],
                n_results=n_results,
                include=["documents", "metadatas"],
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("get_npc_summary query failed for '%s': %s", npc_id, exc)
            # Fallback: return recent history as plain text
            history = self.get_history(npc_id, limit=5)
            if not history:
                return f"No prior interactions recorded for NPC '{npc_id}'."
            lines = [
                f"[{h['timestamp']}] Player: {h['player']} | NPC: {h['npc']}"
                for h in history
            ]
            return f"Recent exchanges with NPC '{npc_id}':\n" + "\n".join(lines)

        docs = result.get("documents", [[]])[0]
        metas = result.get("metadatas", [[]])[0]

        if not docs:
            return f"No relevant memories found for NPC '{npc_id}'."

        # Build a concise summary string for injection into the lore_agent prompt
        parts = [f"Memory summary for NPC '{npc_id}' ({count} total exchanges):"]
        for doc, meta in zip(docs, metas):
            ts = meta.get("timestamp", "unknown time")
            loc = meta.get("location", "unknown location")
            parts.append(f"  [{ts} @ {loc}] {doc}")

        return "\n".join(parts)

    def clear_npc(self, npc_id: str) -> None:
        """
        Delete all stored memory for a given NPC.
        Drops the entire ChromaDB collection.
        """
        name = _safe_collection_name(npc_id)
        try:
            self.client.delete_collection(name=name)
            logger.info("Cleared memory for NPC '%s' (collection '%s')", npc_id, name)
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "Could not clear collection '%s' for NPC '%s': %s", name, npc_id, exc
            )
