# Task-quality research notes

This note records the source material used to shape the prototype. The links are
the primary reading locations; the summaries are deliberately short and do not
copy source text.

## Sources

- [Shopify: Native is now the future of mobile at Shopify](https://shopify.engineering/back-to-native)
  describes Helix as a sequence of small ordered checkpoints. Each checkpoint
  must demonstrate behavior with tests, match a visual review, survive adversarial
  review, and receive human approval before the next checkpoint is committed.
  It also describes headless, agent-addressable business logic and a CLI to make
  fast feedback possible without simulator-driven iteration.
- [Bun: Rewriting Bun in Rust](https://bun.com/blog/bun-in-rust) connects recurring
  memory-safety failures to stronger enforcement. Its practices include sanitizer
  coverage, safety-checked builds, continuous fuzzing, end-to-end leak tests, and
  reusing a language-independent test suite during a large rewrite.
- [kunchenguid/no-mistakes](https://github.com/kunchenguid/no-mistakes) documents a
  disposable worktree and ordered review, test, documentation, lint, publication,
  pull-request, and CI gates, with human control over findings that are not safe
  to fix automatically.
- [Armin Ronacher: Astra for Coding](https://lucumr.pocoo.org/2026/9/7/astra-why/)
  reports that a long unsupervised software-factory run produced substantial
  activity but no useful result, and documents brittle tool-use and code-quality
  behavior. This is evidence for bounded tasks, explicit checkpoints, and
  independent acceptance rather than trusting persistence or volume of output.

## Synthesis

The shared engineering pattern is observable progress under custody: make the
task small, keep the execution environment isolated, require executable evidence,
and stop when evidence is missing or consequences are material. Additional
practices that fit this pattern are reproducible baselines, narrow change scopes,
adversarial review, provenance checks, rollback-friendly commits, sanitizer and
fuzz coverage for risky boundaries, and prospective held-out evaluation.

The prototype applies the pattern sequentially. An operator-authored contract
fixes intent, repository identity, base revision, scope, checks, and budgets;
the script runs baseline and submitted-patch checks; finalization recomputes
acceptance-critical checks; decomposition reruns child and integration checks;
and no-mistakes remains the owner of downstream review, lint, publication, and
CI. The design therefore targets measurable acceptance quality without adding
parallel fan-out or a second workflow framework.
