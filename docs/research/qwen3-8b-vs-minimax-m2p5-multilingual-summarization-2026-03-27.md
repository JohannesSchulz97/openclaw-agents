# Qwen3 8B vs MiniMax M2P5: Multilingual Conversation Summarization

**Date:** 2026-03-27
**Research Type:** Technology Comparison
**Status:** Actionable
**Use Case:** Summarizing agent-developer conversations containing English, German, and Georgian text

## Executive Summary

**Recommendation: Use Qwen3 8B for conversation summarization, not MiniMax M2P5.**

Qwen3 8B is the significantly better choice for this use case because:
1. It explicitly supports 119 languages including Georgian (ka) and German (de)
2. It costs 60-85% less than MiniMax M2P5
3. MiniMax M2P5's "multilingual" strength is in programming languages, not natural languages
4. Qwen3 8B was trained on 36 trillion tokens with deliberate multilingual data coverage

MiniMax M2P5 excels at agentic coding tasks but has no documented natural language multilingual benchmarks for German or Georgian. It would be a poor fit for summarizing conversations in these languages.

## Comparison Table

| Dimension | Qwen3 8B | MiniMax M2P5 (M2.5) |
|-----------|----------|---------------------|
| **Fireworks Model ID** | `accounts/fireworks/models/qwen3-8b` | `accounts/fireworks/models/minimax-m2p5` |
| **Parameters** | 8.2B (dense) | 228.7B (MoE, 10B active) |
| **Context Window (Fireworks)** | 41K tokens | 197K tokens (configured as 16K in OpenClaw) |
| **Input Price** | $0.20/1M tokens | $0.30/1M tokens |
| **Output Price** | $0.20/1M tokens | $1.20/1M tokens |
| **Cached Input** | $0.10/1M tokens | $0.03/1M tokens |
| **Natural Languages** | 119 languages (incl. Georgian, German) | Not documented; focus on programming languages |
| **German Support** | Explicit; trained on German data | Likely supported (Chinese company, global model) but not benchmarked |
| **Georgian Support** | Explicit; listed in supported languages | No evidence of Georgian support |
| **Summarization Benchmarks** | No specific benchmarks; strong general NLU | No specific benchmarks; optimized for code/agent tasks |
| **Intelligence Index** | 11 (non-reasoning 8B class) | 42 (frontier MoE class) |
| **Primary Strength** | Multilingual NLU, reasoning modes | Coding, agentic workflows, tool use |
| **License** | Apache 2.0 | Custom |

## Detailed Analysis

### 1. Multilingual Support (Critical Differentiator)

**Qwen3 8B:**
- Trained on 36 trillion tokens across 119 languages and dialects
- Georgian (ka) is explicitly listed in the supported language table
- German (de) is well-supported as a high-resource European language
- Multilingual benchmarks: MGSM 76, MMMLU 75, IINCLUDE 59 (base model)
- Qwen-MT (specialized translation variant) outperforms GPT-4.1-mini on English-German translation
- Cross-lingual understanding is a design goal, not an afterthought

**MiniMax M2P5:**
- "Multilingual" capabilities refer to programming languages (Go, C++, TypeScript, Rust, etc.)
- Multi-SWE-Bench (51.3%) measures code tasks across programming languages, not human languages
- No published benchmarks for German or any other natural language
- No evidence of Georgian language data in training
- MiniMax is a Chinese AI company; the model likely handles Chinese and English well but other languages are undocumented

**Verdict:** Qwen3 8B is categorically better for natural language multilingual tasks. MiniMax M2P5's multilingual claims are about code, not conversation.

### 2. Georgian Language Specifically

Georgian is a low-resource language with unique Mkhedruli script (~4 million speakers). Key considerations:

- **Qwen3 8B:** Georgian is listed among supported languages. However, as a low-resource language, quality will be lower than for English or German. The model was trained on data from OpenSubtitles, WikiMatrix, CCAligned, and other parallel corpora that include Georgian text. At 8B parameters, expect reasonable but imperfect Georgian comprehension.
- **MiniMax M2P5:** No evidence of Georgian support whatsoever. The model would likely fail or produce poor results on Georgian text.

**Risk mitigation for Georgian:** Even with Qwen3 8B, Georgian portions of conversations may be summarized with reduced accuracy. Consider:
- Instructing the summarizer to preserve Georgian text verbatim when uncertain
- Using a larger Qwen3 model (14B or 32B) if Georgian accuracy is critical
- Testing with sample Georgian technical conversations before deploying

### 3. German Language

Both models likely handle German reasonably well, but:
- **Qwen3 8B:** Explicitly benchmarked. Qwen-MT shows strong English-German performance. German is a high-resource language well-represented in training data.
- **MiniMax M2P5:** Likely handles German as a major world language, but no benchmarks exist. MiniMax Speech 2.5 supports German TTS, suggesting some German capability in the ecosystem.

### 4. Summarization Quality

Neither model has published summarization-specific benchmarks (ROUGE, BERTScore, etc.). Assessment by proxy:

**Qwen3 8B:**
- Strong general NLU (outperforms Qwen2.5-14B on many benchmarks)
- Thinking/non-thinking mode: non-thinking mode is suitable for fast summarization
- 41K context window is sufficient for most conversation summaries
- Pre-training on 36T tokens with diverse data improves comprehension
- Known strength in creative writing, role-playing, multi-turn dialogues

**MiniMax M2P5:**
- Higher raw intelligence (42 vs 11 on Artificial Analysis index), but this reflects coding/reasoning, not summarization
- 197K context window is advantageous for very long conversations
- Optimized for agentic tool use, not text comprehension tasks
- Office work benchmarks (59% win rate on Word/Excel/PPT tasks) suggest some document understanding

**For technical conversation summarization specifically:** Qwen3 8B is well-suited. It needs to:
- Understand mixed-language input (strong)
- Extract key decisions, instructions, and action items (strong general NLU)
- Produce coherent summaries (strong, particularly in non-thinking mode)
- Handle technical terminology (adequate at 8B; Qwen3 excels at STEM)

### 5. Cost Analysis

For a summarization workload (input-heavy, moderate output):

Assuming average summarization task: 4,000 input tokens, 500 output tokens.

| Model | Input Cost | Output Cost | Total per Summary | Monthly (1000 summaries) |
|-------|-----------|-------------|-------------------|--------------------------|
| Qwen3 8B | $0.0008 | $0.0001 | $0.0009 | $0.90 |
| MiniMax M2P5 | $0.0012 | $0.0006 | $0.0018 | $1.80 |

Qwen3 8B is **50% cheaper** per summary. The gap widens with longer conversations due to MiniMax's 6x higher output pricing.

### 6. Context Window Consideration

- **Qwen3 8B (41K):** Sufficient for most conversations. A 2-hour agent check-in conversation rarely exceeds 20K tokens.
- **MiniMax M2P5 (197K on Fireworks, but configured as 16K in OpenClaw):** Larger window, but currently misconfigured. Even if fixed, the context advantage is irrelevant for summarization of typical conversations.

If summarizing very long multi-day conversations (>40K tokens), consider Qwen3 30B ($0.90/1M tokens, larger context) instead.

## Known Weaknesses of Qwen3 8B

1. **Low-resource language quality:** Georgian output will be lower quality than English/German. Expect occasional errors in grammar, vocabulary, or script handling.
2. **8B parameter limit:** For complex technical conversations with nuanced reasoning, a larger model (14B+) would produce better summaries. However, for straightforward summarization, 8B is sufficient.
3. **No specific summarization fine-tuning:** The model is a general-purpose LLM, not a summarization specialist. Prompt engineering is important.
4. **41K context window:** Cannot handle extremely long conversations in a single pass. Chunking would be needed for conversations exceeding ~30K tokens (accounting for output).
5. **Intelligence Index of 11:** Below median for non-reasoning 8B models. For critical summaries, consider testing against gpt-oss-20b ($0.07/1M input) which may offer better quality-per-dollar.

## Recommendation

### Primary: Qwen3 8B

Use `accounts/fireworks/models/qwen3-8b` for conversation summarization.

**Rationale:**
- Only option with confirmed Georgian language support
- Strong German and English capabilities
- 50% cheaper than MiniMax M2P5
- Designed for multilingual NLU tasks
- Adequate context window for typical conversations

### Alternative: gpt-oss-20b for English/German-only conversations

If Georgian is not present in a particular conversation, `gpt-oss-20b` at $0.07/1M input is 65% cheaper than Qwen3 8B and has more parameters (20B). However, it lacks Qwen3's explicit multilingual training.

### Not Recommended: MiniMax M2P5

Do not use MiniMax M2P5 for this use case. Its strengths (coding, agentic workflows) are irrelevant, and its natural language multilingual capabilities are undocumented. It costs more and provides no advantage for conversation summarization.

## Implementation Notes

To add Qwen3 8B to the `fw-mm25` provider in `openclaw.json`, add it to the models array:

```json
{
  "id": "accounts/fireworks/models/qwen3-8b",
  "alias": "fw-qwen3-8b",
  "contextWindow": 41000,
  "maxTokens": 8192
}
```

For Lossless Claw summarization configuration:
```json
{
  "summaryModel": "fw-mm25/accounts/fireworks/models/qwen3-8b",
  "summaryProvider": "fw-mm25"
}
```

## Sources

- [Qwen3 Technical Report (arXiv:2505.09388)](https://arxiv.org/abs/2505.09388)
- [Qwen3 Official Blog](https://qwenlm.github.io/blog/qwen3/)
- [Qwen3 8B on Fireworks AI](https://fireworks.ai/models/fireworks/qwen3-8b)
- [MiniMax M2.5 Announcement](https://www.minimax.io/news/minimax-m25)
- [MiniMax M2.5 on Fireworks AI](https://fireworks.ai/models/fireworks/minimax-m2p5)
- [Artificial Analysis - Qwen3 8B](https://artificialanalysis.ai/models/qwen3-8b-instruct)
- [Artificial Analysis - MiniMax M2.5](https://artificialanalysis.ai/models/minimax-m2-5)
- [Galaxy.ai - MiniMax M2.5 vs Qwen3 8B](https://blog.galaxy.ai/compare/minimax-m2-5-vs-qwen3-8b)
- [Georgian NLP Resources](https://github.com/alexamirejibi/awesome-ka-nlp)
- [Fireworks AI Pricing](https://fireworks.ai/pricing)
