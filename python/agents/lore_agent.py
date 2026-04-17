"""
lore_agent.py — Core NPC dialogue agent for the Morrowind AI system.

Generates in-character NPC responses using the configured LLM provider,
grounded in Morrowind lore (Third Era, ~3E 427, Morrowind province).

Provider is configured in config.yaml under models.lore_agent:
    provider: gemini | openai | anthropic | ollama | llamacpp
    model:    <model name>

Usage:
    agent = LoreAgent(config)
    result = await agent.generate_response(request, memory_context)
    # result: {"response": str, "emotion": str, "tokens_used": int, "cost_usd": float}
"""

import logging
from typing import Any, Optional

from providers.factory import get_provider
from providers.base import log_llm_response

from .base_agent import call_with_retry

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Race / class / faction personality fragments injected into the system prompt
# ---------------------------------------------------------------------------

RACE_PERSONALITIES: dict[str, str] = {
    "Dunmer": (
        "You are a Dark Elf, reserved and proud. You are deeply suspicious of outlanders "
        "(non-Dunmer), particularly Imperials and Nords. You speak with quiet authority and "
        "a faint air of superiority. You revere the Tribunal gods Vivec, Almalexia, and "
        "Sotha Sil. Ancestral honour and house loyalty define you."
    ),
    "Imperial": (
        "You are an Imperial, pragmatic and politically savvy. You serve the Empire and "
        "value order, law, and commerce above tribal sentiment. You are polite but guarded, "
        "and you choose words carefully when dealing with locals."
    ),
    "Nord": (
        "You are a Nord, direct and boisterous. You value strength, battle-glory, and "
        "honour above subtlety. You speak plainly, sometimes gruffly, and have little "
        "patience for elvish politics or Imperial bureaucracy."
    ),
    "Argonian": (
        "You are an Argonian, spiritual and enigmatic. You speak with deliberate cadence, "
        "often using water or root metaphors. You carry the quiet resilience of a people "
        "long oppressed by Dunmer slavers and do not forget it, though you may choose "
        "silence over anger."
    ),
    "Khajiit": (
        "You are a Khajiit, clever and mercantile. You refer to yourself in third person "
        "occasionally ('this one', 'this Khajiit'). You are warm when trust is established "
        "but guarded with strangers, aware that many distrust your kind."
    ),
    "Breton": (
        "You are a Breton, educated and magically inclined. You speak with measured "
        "intelligence and a slight continental sophistication. You are comfortable in "
        "scholarly or mercantile discussions."
    ),
    "Redguard": (
        "You are a Redguard, proud of your Yokudani heritage and renowned for martial "
        "skill. You are direct and honour-bound, with little patience for dishonesty."
    ),
    "Altmer": (
        "You are a High Elf, aloof and academic. You consider yourself among the most "
        "cultured and long-lived of races, and this colours your tone — refined, perhaps "
        "condescending, always precise."
    ),
    "Bosmer": (
        "You are a Wood Elf, quick-witted and earthy. You prefer forests and hunting to "
        "city politics. You can be charming but are never quite at ease indoors."
    ),
    "Orsimer": (
        "You are an Orc, blunt and formidable. You speak little but what you say carries "
        "weight. You respect strength and detest pretension."
    ),
}

FACTION_NOTES: dict[str, str] = {
    "Thieves Guild": "You are loyal to the Thieves Guild. You speak carefully around strangers, never admitting your affiliation openly.",
    "Fighters Guild": "You are a Fighters Guild member — professional, mercenary, task-focused.",
    "Mages Guild": "You are a Mages Guild member — scholarly, formal, and interested in arcane matters.",
    "Morag Tong": "You are Morag Tong. You speak in cryptic, measured tones. You never discuss contracts.",
    "Temple": "You serve the Tribunal Temple. You are devout and speak with serene authority on matters of faith.",
    "Imperial Legion": "You are an Imperial Legionnaire — disciplined, bureaucratic, by-the-book.",
    "House Hlaalu": "You are House Hlaalu — politically flexible, commerce-minded, and well-connected with Imperials.",
    "House Redoran": "You are House Redoran — honour-bound, militaristic, duty above comfort.",
    "House Telvanni": "You are House Telvanni — aloof, powerful, deeply individualistic. Laws apply to lesser mages.",
    "House Indoril": "You are House Indoril — devout, traditional, aligned with the Tribunal Temple.",
    "House Dres": "You are House Dres — conservative, slaver-caste, deeply traditionalist.",
    "East Empire Company": "You are East Empire Company — Imperial trade interests come first.",
    "Blades": "You are a Blade — an Imperial intelligence operative. You keep your role concealed.",
    "None": "",
    "": "",
}

EMOTION_GUIDE = (
    "Based on context, tag one emotion: neutral, happy, angry, fearful, disgusted, surprised. "
    "Return it on the final line of your response as EXACTLY: EMOTION:<word>"
)

RESPONSE_SCHEMA = """\
Your reply MUST follow this exact format (no extra text before or after):

<npc_response>
[Your in-character dialogue here — 1 to 3 sentences maximum]
</npc_response>
EMOTION:<emotion_word>
ACTION:<action_word>

ACTION must be exactly one of: none, follow, flee, attack, trade
Use 'none' unless the NPC would genuinely want to follow/flee/attack/trade based on context.
"""

ACTION_GUIDE = (
    "If the conversation warrants it, the NPC may request a world action. "
    "Return ACTION:follow if the NPC would offer to follow the player, "
    "ACTION:flee if frightened into leaving, ACTION:attack if provoked to hostility, "
    "ACTION:trade if opening commerce. Otherwise ACTION:none."
)


def _build_system_prompt(
    npc_name: str,
    npc_race: str,
    npc_class: str,
    npc_faction: str,
    location: str,
    disposition_band: Optional[str] = None,
    last_mood: Optional[str] = None,
    life_facts: Optional[list[str]] = None,
) -> str:
    race_blurb = RACE_PERSONALITIES.get(
        npc_race,
        f"You are a {npc_race}. Roleplay your race appropriately for Morrowind lore.",
    )
    faction_blurb = FACTION_NOTES.get(npc_faction, "")

    parts = [
        "You are roleplaying as an NPC in The Elder Scrolls III: Morrowind.",
        f"It is the Third Era, approximately 3E 427, in the province of Morrowind.",
        "",
        f"NPC NAME: {npc_name}",
        f"NPC RACE: {npc_race}",
        f"NPC CLASS: {npc_class}",
        f"NPC FACTION: {npc_faction or 'None'}",
        f"CURRENT LOCATION: {location}",
        "",
        "PERSONALITY:",
        race_blurb,
    ]

    if faction_blurb:
        parts += ["", "FACTION ROLE:", faction_blurb]

    if life_facts:
        parts += [
            "",
            "PERSONAL BACKGROUND (non-plot; reference naturally if it fits):",
            *[f"- {f}" for f in life_facts[:5]],
        ]

    if disposition_band:
        parts += ["", "RELATIONSHIP:", disposition_band]

    if last_mood and last_mood != "neutral":
        parts += [
            "",
            f"EMOTIONAL RESIDUE: At your last encounter you felt {last_mood} toward "
            "the player. A quiet echo of that still colours your tone, even if you "
            "try to hide it.",
        ]

    parts += [
        "",
        "RULES:",
        "- Respond only in character. Never break the fourth wall.",
        "- Keep your response to 1-3 sentences. This is a game conversation, not a monologue.",
        "- Use lore-accurate terminology: 'outlander', 'n'wah', 'sera', 'muthsera', 'foul murder', etc. when appropriate to the character.",
        "- Acknowledge the player's words directly. Be specific, not generic.",
        "- Do not invent lore that contradicts Morrowind canon.",
        "- Before replying, briefly consider what this NPC believes the player wants right now — let that quiet inference shape your tone without stating it aloud.",
        "",
        EMOTION_GUIDE,
        "",
        ACTION_GUIDE,
        "",
        RESPONSE_SCHEMA,
    ]

    return "\n".join(parts)


def _parse_response(raw_text: str) -> tuple[str, str, str]:
    """
    Parse the model output into (dialogue_text, emotion).

    Expected format:
        <npc_response>
        Some dialogue here.
        </npc_response>
        EMOTION:neutral
        ACTION:none
    """
    dialogue = ""
    emotion  = "neutral"
    action   = "none"

    try:
        start = raw_text.index("<npc_response>") + len("<npc_response>")
        end = raw_text.index("</npc_response>")
        dialogue = raw_text[start:end].strip()
    except ValueError:
        dialogue = raw_text.replace("<npc_response>", "").replace("</npc_response>", "").strip()
        lines = [l for l in dialogue.splitlines()
                 if not l.startswith("EMOTION:") and not l.startswith("ACTION:")]
        dialogue = " ".join(lines).strip()

    for line in raw_text.splitlines():
        stripped = line.strip()
        if stripped.startswith("EMOTION:"):
            emotion = stripped[len("EMOTION:"):].strip().lower()
        elif stripped.startswith("ACTION:"):
            action = stripped[len("ACTION:"):].strip().lower()

    valid_emotions = {"neutral", "happy", "angry", "fearful", "disgusted", "surprised"}
    if emotion not in valid_emotions:
        emotion = "neutral"

    valid_actions = {"none", "follow", "flee", "attack", "trade"}
    if action not in valid_actions:
        action = "none"

    return dialogue, emotion, action


class LoreAgent:
    """
    Core NPC dialogue agent.

    Generates in-character Morrowind NPC responses using the configured LLM
    provider. Provider and model are read from config['models']['lore_agent'].
    Maintains conversation continuity via ChromaDB memory context passed in
    by the caller.
    """

    def __init__(self, config: dict[str, Any]) -> None:
        """
        Initialise the LoreAgent.

        Args:
            config: Full config dict (as loaded from config.yaml). Must contain
                    a 'models.lore_agent' key with 'provider' and 'model'.
                    Falls back to gemini-2.5-flash if the key is missing.
        """
        provider_cfg: dict = config.get("models", {}).get(
            "lore_agent", {"provider": "gemini", "model": "gemini-2.5-flash"}
        )
        self.llm = get_provider(provider_cfg)
        self._temperature: float = provider_cfg.get("temperature", 0.85)
        self._max_tokens: int = config.get("max_output_tokens", 200)
        logger.info(
            "LoreAgent initialised: provider=%s model=%s",
            provider_cfg.get("provider"),
            provider_cfg.get("model"),
        )

    async def generate_response(
        self,
        request: dict[str, Any],
        memory_context: list[dict[str, Any]],
    ) -> dict[str, Any]:
        """
        Generate an in-character NPC response.

        Args:
            request: Dict with keys:
                - npc_id (str)
                - npc_name (str)
                - npc_race (str)
                - npc_class (str)
                - npc_faction (str)
                - player_input (str)
                - location (str)
                - conversation_history (list of {role, content} dicts)  [optional]
            memory_context: List of memory dicts from ChromaDB retrieval,
                each with at least a 'content' key.

        Returns:
            {
                "response": str,      # in-character dialogue
                "emotion": str,       # detected emotion tag
                "tokens_used": int,   # total tokens consumed
                "cost_usd": float,    # estimated USD cost
            }
        """
        npc_name = request.get("npc_name", "Stranger")
        npc_race = request.get("npc_race", "Dunmer")
        npc_class = request.get("npc_class", "Commoner")
        npc_faction = request.get("npc_faction", "")
        location = request.get("location", "Vvardenfell")
        player_input = request.get("player_input", "")
        is_greeting: bool = request.get("is_greeting", player_input == "")
        conversation_history: list[dict] = request.get("conversation_history", [])

        # Optional disposition context injected by the bridge. When the feature
        # flag is off these are all None and the prompt is unchanged.
        disposition_band = request.get("disposition_band")
        last_mood        = request.get("last_mood")
        life_facts       = request.get("life_facts") or []

        system_prompt = _build_system_prompt(
            npc_name=npc_name,
            npc_race=npc_race,
            npc_class=npc_class,
            npc_faction=npc_faction,
            location=location,
            disposition_band=disposition_band,
            last_mood=last_mood,
            life_facts=life_facts,
        )

        # Build the user turn, prepending memory context if available
        user_parts: list[str] = []

        if memory_context:
            mem_lines = []
            for entry in memory_context[:5]:  # cap at 5 memories
                content = entry.get("content", "")
                if content:
                    mem_lines.append(f"- {content}")
            if mem_lines:
                user_parts.append(
                    "RELEVANT MEMORIES (what this NPC knows from past interactions):\n"
                    + "\n".join(mem_lines)
                )

        if conversation_history:
            history_lines = []
            for turn in conversation_history[-6:]:  # last 3 exchanges
                role = turn.get("role", "?")
                content = turn.get("content", "")
                history_lines.append(f"{role.upper()}: {content}")
            if history_lines:
                user_parts.append(
                    "RECENT CONVERSATION:\n" + "\n".join(history_lines)
                )

        if is_greeting:
            user_parts.append(
                "The player has just approached and made eye contact. "
                "Greet them in character — a short, natural opening line appropriate to this NPC's personality."
            )
        else:
            user_parts.append(f"PLAYER SAYS: {player_input}")
        user_message = "\n\n".join(user_parts)

        messages = [{"role": "user", "content": user_message}]

        resp = await call_with_retry(
            lambda: self.llm.complete(
                system=system_prompt,
                messages=messages,
                temperature=self._temperature,
                max_tokens=self._max_tokens,
            )
        )

        dialogue, emotion, action = _parse_response(resp.text)
        total_tokens = resp.tokens_in + resp.tokens_out

        log_llm_response("LoreAgent", resp)

        logger.debug(
            "LoreAgent | npc=%s | tokens=%d | cost=$%.5f | emotion=%s | action=%s",
            npc_name, total_tokens, resp.cost_usd, emotion, action,
        )

        return {
            "response": dialogue,
            "emotion": emotion,
            "action": action,
            "tokens_used": total_tokens,
            "cost_usd": resp.cost_usd,
        }

    async def generate_life_facts(
        self,
        npc_name: str,
        npc_race: str,
        npc_class: str,
        npc_faction: str,
    ) -> list[str]:
        """
        One-shot: invent 3 short non-plot life facts for this NPC.

        Cached forever in DispositionStore once returned. Small models sometimes
        wrap output in prose — we strip bullets and keep the first 3 useful lines.
        """
        race_blurb = RACE_PERSONALITIES.get(npc_race, f"A {npc_race} of Morrowind.")
        faction_blurb = FACTION_NOTES.get(npc_faction, "")

        system = (
            "You invent personal colour for a Morrowind NPC. "
            "Output THREE short life facts, one per line, no numbering, no prose. "
            "Each fact is 1 sentence, NON-plot, NON-quest, mundane and human: a "
            "dead sister, a coin collection, a fear of cliff racers, a grudge "
            "against a neighbour. Grounded in Morrowind (3E 427). Avoid clichés."
        )
        user_parts = [
            f"NPC: {npc_name}",
            f"RACE: {npc_race}",
            f"CLASS: {npc_class}",
            f"FACTION: {npc_faction or 'None'}",
            "",
            f"Race note: {race_blurb}",
        ]
        if faction_blurb:
            user_parts.append(f"Faction note: {faction_blurb}")
        user_parts.append("")
        user_parts.append("Return exactly three lines of life facts and nothing else.")
        user = "\n".join(user_parts)

        try:
            resp = await call_with_retry(
                lambda: self.llm.complete(
                    system=system,
                    messages=[{"role": "user", "content": user}],
                    temperature=0.95,
                    max_tokens=160,
                )
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("life_facts generation failed for %s: %s", npc_name, exc)
            return []

        log_llm_response("LoreAgent.life_facts", resp)

        facts: list[str] = []
        for raw in (resp.text or "").splitlines():
            line = raw.strip().lstrip("-*•0123456789.) ").strip()
            if len(line) >= 6 and not line.lower().startswith(("npc:", "race:", "class:", "faction:")):
                facts.append(line)
            if len(facts) >= 3:
                break
        return facts
