"""
gemini_provider.py — Google Gemini provider using the new google.genai SDK.

Supports vision (image_bytes → inline Part).
Default model: gemini-2.5-flash

Pricing (USD per million tokens, as of 2025-Q2):
  Input:  $0.075 / 1M
  Output: $0.30  / 1M
"""

import logging

from google import genai
from google.genai import types as genai_types

from .base import LLMProvider, LLMResponse, read_nemoclaw_env

logger = logging.getLogger(__name__)

_INPUT_COST_PER_M = 0.075
_OUTPUT_COST_PER_M = 0.30


class GeminiProvider(LLMProvider):
    """
    LLM provider backed by Google Gemini (new google-genai SDK).

    Config keys:
        model      — Gemini model name (default: "gemini-2.5-flash")
        api_key    — Override; if absent, read GOOGLE_API_KEY from ~/.nemoclaw_env
    """

    def __init__(self, cfg: dict) -> None:
        self.model_name: str = cfg.get("model", "gemini-2.5-flash")
        api_key: str = cfg.get("api_key") or read_nemoclaw_env("GOOGLE_API_KEY")
        self._client = genai.Client(api_key=api_key)
        logger.info("GeminiProvider ready: model=%s", self.model_name)

    async def complete(
        self,
        system: str,
        messages: list[dict],
        image_bytes: bytes | None = None,
        **kwargs,
    ) -> LLMResponse:
        temperature: float = kwargs.get("temperature", 0.8)
        max_output_tokens: int = kwargs.get("max_tokens", 512)

        # Flatten system + prior history into a single prompt string.
        history_lines: list[str] = [system, ""]
        for msg in messages[:-1]:
            role = msg.get("role", "user").upper()
            history_lines.append(f"{role}: {msg.get('content', '')}")
        if len(messages) > 1:
            history_lines.append("")

        last_msg = messages[-1] if messages else {"role": "user", "content": ""}
        history_lines.append(f"USER: {last_msg.get('content', '')}")
        prompt_text = "\n".join(history_lines)

        # Build contents. For text-only, a string is fine; for vision, assemble Parts.
        if image_bytes is not None:
            contents = [
                genai_types.Part.from_text(text=prompt_text),
                genai_types.Part.from_bytes(data=image_bytes, mime_type="image/png"),
            ]
        else:
            contents = prompt_text

        config = genai_types.GenerateContentConfig(
            temperature=temperature,
            max_output_tokens=max_output_tokens,
        )

        # No retry here — callers (agents) already wrap .complete() in call_with_retry.
        response = await self._client.aio.models.generate_content(
            model=self.model_name,
            contents=contents,
            config=config,
        )

        raw_text: str = (getattr(response, "text", None) or "") or ""

        usage = getattr(response, "usage_metadata", None)
        tokens_in: int = getattr(usage, "prompt_token_count", 0) or 0
        tokens_out: int = getattr(usage, "candidates_token_count", 0) or 0

        cost = (tokens_in / 1_000_000) * _INPUT_COST_PER_M + (
            tokens_out / 1_000_000
        ) * _OUTPUT_COST_PER_M

        return LLMResponse(
            text=raw_text,
            tokens_in=tokens_in,
            tokens_out=tokens_out,
            cost_usd=cost,
            model=self.model_name,
            provider="gemini",
        )
