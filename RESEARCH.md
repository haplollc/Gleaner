# Research notes

What the literature and Apple's own documentation say about getting good results from a small model with a small
window, and which parts Gleaner uses. Every link below was opened and checked while writing this. Where a number
comes from a paper's abstract and not from rerunning the experiment, it says so.

## 1. The hard facts about Apple's on-device model

| Fact | Source |
| --- | --- |
| The context window is **4,096 tokens per session**. Instructions, every prompt, tool definitions and their output, `@Generable` schemas, and the model's own answers all share it. | [TN3193: Managing the on-device foundation model's context window](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window) |
| A token is roughly 3 to 4 characters of English, about one character for Chinese, Japanese and Korean. | TN3193, citing [WWDC25 session 286](https://developer.apple.com/videos/play/wwdc2025/286/) |
| `SystemLanguageModel.contextSize` and `tokenCount(for:)` (instructions, prompt, tools, schema, transcript entries) arrive in **iOS and macOS 26.4**. Before that the number is 4,096 and you estimate. | [`tokenCount(for:)`](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/tokencount(for:)) availability, TN3193 revision history (2026-03-31) |
| Overflow throws `.exceededContextWindowSize` and the session cannot answer again. | TN3193 |
| Other errors a long run meets: `guardrailViolation`, `rateLimited`, `concurrentRequests` (a second prompt while the first runs), `refusal`, `decodingFailure`, `assetsUnavailable`. | [`LanguageModelSession.GenerationError`](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror). In the OS 27 SDK these moved to `LanguageModelError`. |
| The model is about 3 billion parameters. | [Apple Intelligence Foundation Language Models Tech Report 2025](https://arxiv.org/abs/2507.13575) |
| Apple's own advice: split a big task into steps with a fresh session each, summarize chunks then summarize the summaries, carry the previous result into the next prompt, ask for less output, keep prompts to 1 to 3 paragraphs, keep `@Generable` types small, give the model 3 to 5 tools at most, and use retrieval for large knowledge bases. | TN3193 |

**On "8k".** The owner of this project remembered 8k. The number in Apple's documentation is 4,096, and a real run on a
Mac with Apple Intelligence reported `contextSize` = 4096 (see the README). Some cloud models have 8k windows, which may
be where the memory comes from.

A few things measured while building this (macOS 27, Apple silicon):

- `tokenCount` is exact but takes about 45 ms a call, so Gleaner measures chunks with a calibrated estimate and checks
  each finished prompt exactly (one call, not one per record).
- A one-line instruction cost 51 tokens and a small schema 123: framing and schemas are not free, so Gleaner counts them.
- A prompt that was the word "word" repeated 5,000 times came back as a guardrail error, not a context error. Do not
  assume an oversized prompt always reports as overflow; handle both by splitting.
- `NLEmbedding` crashed when two threads called it at once, so Gleaner serializes calls to it.

## 2. Techniques for long input and a small window

### Map-reduce and hierarchical summarization

Split, process each piece alone, merge the partial results, repeat until the result fits. The oldest and simplest
approach, and the one Apple recommends in TN3193.

- Wu et al., [Recursively Summarizing Books with Human Feedback](https://arxiv.org/abs/2109.10862) (2021): summarize
  small sections, then summarize the summaries, recursively, to cover whole novels.
- Zhou et al., [LLM×MapReduce: Simplified Long-Sequence Processing using Large Language Models](https://arxiv.org/abs/2410.09342)
  (2024): training-free split and merge, with a structured protocol for information that crosses chunk edges and a
  confidence step for conflicting answers. Its lesson for us: what you pass between stages should be structured, not prose.
- **In Gleaner:** `extract` (map, then a tree reduce that merges in order) and `summarize` (hierarchical levels). Items
  are `@Generable` structs, so what flows between stages is structured.

### Chain of Agents

Zhang et al., [Chain of Agents: Large Language Models Collaborating on Long-Context Tasks](https://arxiv.org/abs/2406.02818)
(Google, 2024). Worker agents read segments in order, each passing a message to the next; a manager writes the answer.
The abstract reports gains of up to 10 percent over RAG and full-context baselines.

- **In Gleaner:** `runningNotes`. One model plays every worker. The message is a short note block with a hard token
  budget, compacted when it grows. Use it when facts build on each other or order matters.

### Trees of summaries

- Sarthi et al., [RAPTOR: Recursive Abstractive Processing for Tree-Organized Retrieval](https://arxiv.org/abs/2401.18059)
  (2024): cluster chunks, summarize each cluster, repeat upward; retrieve from every level so both detail and the big
  picture are reachable. The abstract reports about 20 points on QuALITY when paired with GPT-4.
- Chen et al., [Walking Down the Memory Maze (MemWalker)](https://arxiv.org/abs/2310.05029) (2023): a tree of summaries
  that the model navigates to find an answer.
- **In Gleaner:** the reduce is a tree, and `NoteIndex` can hold the intermediate summaries next to the raw notes, so a
  lookup can hit either level. Gleaner does not cluster (no good on-device clustering that is cheap); it merges in order.

### Gist memory and paging

- Lee et al., [A Human-Inspired Reading Agent with Gist Memory of Very Long Contexts (ReadAgent)](https://arxiv.org/abs/2402.09727)
  (2024): paginate, compress each page to a gist, and look the original page up again only when a question needs detail.
  The abstract reports an effective window 3.5 to 20 times larger.
- Packer et al., [MemGPT: Towards LLMs as Operating Systems](https://arxiv.org/abs/2310.08560) (2023), now
  [Letta](https://github.com/letta-ai/letta): treat the window as fast memory and the rest as slow storage the model
  pages in and out.
- **In Gleaner:** the same split. Gists and notes live in the prompt; raw records live in `NoteIndex` and come back by
  lookup. Gleaner does not let the model decide when to page (a 3B model is poor at that); your code decides.

### Treating the prompt as an environment

Zhang, Kraska and Khattab, [Recursive Language Models](https://arxiv.org/abs/2512.24601) (2025 to 2026): let the
model inspect and split a long input with code and call itself on the pieces. They report handling inputs about two
orders of magnitude past the window. This needs a model that writes reliable code and plans well, which Apple's small
model is not, so Gleaner keeps the control flow in Swift. The idea that the *program* decides how to slice the input,
and the model only reads small slices, is the same.

### Where to put things in the prompt

Liu et al., [Lost in the Middle: How Language Models Use Long Contexts](https://arxiv.org/abs/2307.03172) (2023):
accuracy is best when the relevant text is at the start or end of the input and drops when it sits in the middle.
Even with a 4k window this matters.

- **In Gleaner:** retrieved notes are ordered best first and second best last (`Packing.edgeOrder`), and the task is
  restated after the data in every map prompt.

### Prompt compression

- Jiang et al., [LLMLingua](https://arxiv.org/abs/2310.05736) (2023): drop low-information tokens using a small model;
  the abstract reports up to 20x compression with little loss.
- Jiang et al., [LongLLMLingua](https://arxiv.org/abs/2310.06839) (2023, ACL 2024): question-aware compression for long
  contexts; the abstract reports up to 21.4 percent better accuracy on NaturalQuestions with about 4x fewer tokens.
- **In Gleaner:** not implemented. LLMLingua needs a second language model to score tokens, which is a poor trade on a
  phone. The cheap cousins are used instead: near-duplicate removal, truncating long records on word boundaries,
  numbered short lines, and short instructions. Compression-by-extraction (the map step) does the real work.

### Retrieval with small models

- Hybrid retrieval beats either half alone. Keyword search (BM25, Robertson and Zaragoza,
  [The Probabilistic Relevance Framework: BM25 and Beyond](https://nowpublishers.com/article/Details/INR-019), 2009)
  catches exact names and rare words; embeddings catch paraphrase.
- Fuse the two rankings with Reciprocal Rank Fusion: Cormack, Clarke and Büttcher,
  [Reciprocal Rank Fusion outperforms Condorcet and individual rank learning methods](https://research.google/pubs/pub36196/)
  (SIGIR 2009). Score is the sum over lists of 1/(k + rank), k = 60. It needs no score calibration between lists,
  which matters because BM25 scores and cosine similarities live on different scales.
- Anthropic's [Contextual Retrieval](https://www.anthropic.com/news/contextual-retrieval) (2024) reports that combining
  BM25 with embeddings cut failed top-20 retrievals by 49 percent (5.7 to 2.9 percent), and adding a reranker by 67
  percent (to 1.9 percent), after prepending a short context line to each chunk. The numbers are theirs, on their data.
- **In Gleaner:** `NoteIndex` does BM25 + `NLEmbedding` + RRF, drops near-duplicates, and packs to a token budget. A good
  habit that follows from Contextual Retrieval: write each note so it stands alone ("She runs trail races" beats
  "also likes that"), because notes are retrieved without their neighbours. There is no reranker; with a 4k window
  and 20 or fewer candidates, packing the top few is the rerank.

### Structured output

Willard and Louf, [Efficient Guided Generation for Large Language Models](https://arxiv.org/abs/2307.09702) (2023, the
Outlines library): constrain decoding with a state machine so output always parses. Apple's guided generation
(`@Generable`) gives the same guarantee on device: the answer is always a valid value of your type, never prose you must
parse. Small models gain the most from this. Two costs to respect: the schema takes window space (123 tokens for a
tiny type here), and `@Guide(.maximumCount)` bounds the answer length better than a hard token cap, which Apple warns
can produce truncated or malformed output (TN3193).

### Small models, used well

Belcak et al., [Small Language Models are the Future of Agentic AI](https://arxiv.org/abs/2506.02153) (2025): small
models are enough for narrow, repetitive, well-specified sub-tasks. The pattern in all of the above is the same: make
each call narrow and the input short, let code do the planning, and let the model read and label.

## 3. NaturalLanguage for on-device retrieval

- `NLEmbedding.sentenceEmbedding(for:)`: 512-dimension vectors, no download, about 10 to 15 ms a note on an M-series
  Mac (measured). Apple's own docs point to it for semantic similarity. It is Gleaner's default.
- `NLContextualEmbedding` ([docs](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding)): a
  BERT-style model that returns one vector per token, so you pool them yourself. It can need to download assets
  (`requestAssets`), has a maximum sequence length, and Apple's documentation says to prefer `NLEmbedding` for
  similarity. Gleaner ships `ContextualEmbedder` (mean pooled) for scripts and languages `NLEmbedding` lacks.
- Averaging word vectors from `NLEmbedding.wordEmbedding` is a cheap fallback that works, and is what the
  HaploAI app's provider does. The sentence embedding is better for whole notes.

## 4. What a production app already did (HaploAI)

The HaploAI iOS app's memory layer was read for ideas (no code copied):

- Hybrid text plus vector search with a small top-k (3 items in chat) injected into the prompt.
- An importance filter before anything is remembered, so the index stays small and relevant.
- Facts extracted from conversation as short standalone statements, stored separately from raw turns.

Gleaner keeps all three ideas: hybrid search, small packed context, and writing short standalone notes.

## 5. What it means for a 4k model: the short list

1. **Budget every call.** Count instructions and schema, reserve room for the answer, keep a margin. Overflowing wastes
   a whole call.
2. **Small, specific tasks.** One question per call, a short imperative instruction, a short answer with a `maximumCount`.
3. **Fresh session per call.** History is the enemy of a 4k window. Carry state yourself, as short notes.
4. **Structured in, structured out.** Number the records; return `@Generable` items; pass items, not prose, between stages.
5. **Merge as a tree, in order.** Cheap, parallelizable in principle, and keeps recency and ordering.
6. **Keep the raw data out of the prompt and look it up.** Hybrid retrieval, packed to a budget, best at the edges.
7. **Never trust the model's knowledge, only its reading.** Give it the facts; ask it to extract, label or rank.
8. **Expect failure and design for it.** Split and retry on overflow and guardrail errors, skip what cannot be read,
   count what was skipped, and stop on a deadline with a partial answer.
9. **Cache by content.** The same input gives the same answer under greedy sampling, so a rerun can cost nothing.

## 6. What was not verified

- The papers' headline numbers are from their abstracts. None of them was run on Apple's model, and the abstracts
  mostly measure much larger models. Treat the techniques as well-founded, and the percentages as theirs.
- The Cormack, Clarke and Büttcher PDF would not extract as text, so the RRF details (sum of 1/(k + rank), k = 60) are
  confirmed from the paper's listing and several independent summaries, not from its pages.
- Apple's technote says nothing about speed. Timings in this repo are from one Mac and will differ on an iPhone.
