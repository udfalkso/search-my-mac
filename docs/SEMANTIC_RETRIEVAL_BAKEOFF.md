# Semantic retrieval bake-off

## Focused regression case

Query: `home buying related`

Document: `Falkson and Davis 4600 Overbrook Road $1.5M and $700k to close MoCo MD.pdf`

The benchmark reads the exact PDF text stored in the live Search My Mac manifest. It does not use a cleaned-up replacement. The source is a structured mortgage estimate whose extraction mixes descriptive language with names, addresses, rates, amounts, and table labels.

## Findings

Removing numbers is not a useful general solution. On the installed Qwen3 Embedding 0.6B model, cosine similarity fell from `0.3792` to `0.3472` after numeric stripping. Financial values can also be meaningful search evidence.

Embedding the full noisy passage is insufficient for broad intent queries. Adding the filename to the passage did not reliably improve it.

A local generative model can infer retrieval-oriented concepts from the exact extraction. Qwen3 0.6B generated several candidates, including `loan estimate for home purchase`, in about 2.6 seconds with Metal acceleration. Qwen3 Embedding 4B produced these 1,024-dimension cosine scores:

| Representation | Cosine |
| --- | ---: |
| Exact extracted passage | 0.4679 |
| Automatically generated `loan estimate for home purchase` | 0.5797 |
| Hand-authored ideal document card | 0.5937 |
| Irrelevant settings/screenshot control | 0.2838 |

The 1,024-dimension prefix of Qwen3 Embedding 4B retained the quality of its full 2,560-dimension output for this case, allowing vector storage to remain approximately the same width as the current index.

The installed Qwen3 Embedding 0.6B model gave weaker separation. Its automatic topics score was `0.5647`, but the irrelevant control was also high at `0.4839`. The larger embedding model's discrimination—not merely a higher absolute cosine—is the important improvement.

## Architecture decision

Do not replace passage embeddings with a single full-document vector. Use multiple semantic units per source:

1. Passage vectors preserve pinpoint retrieval and useful snippets.
2. Document-level topic and likely-search vectors capture broad intent and life-event queries.
3. Retrieval groups all matching units by source and uses the best unit score, while displayed snippets always come from original extracted text.
4. Generated concepts are derived index data. They must be versioned, replaceable, and excluded from lexical search and user-visible snippets.
5. Store semantic units in their own manifest table and key namespace instead of overloading passage rows.

The proposed local model pair is Qwen3 0.6B Q8 for document concept generation and Qwen3 Embedding 4B Q4_K_M with 1,024-dimensional Matryoshka truncation. Before shipping the pair, run it against a judged multi-domain corpus; this one-file regression proves the mechanism, not general relevance quality.

## Reproduction

The experimental `semantic-benchmark` product accepts the embedding model, output dimensions, and generator model as arguments, and reads exact extracted text on standard input. The GGUF files used during development live under the ignored `.build/semantic-spike` directory and are not application resources.
