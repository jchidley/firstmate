# Task-quality prototype

The opt-in task-quality prototype is a sequential control-plane experiment for one bounded coding task.

It is not a new agent framework, an official pi-workflow bundle, a replacement for no-mistakes, or an automatic model router.

## Owner and invocation

`bin/fm-task-quality.sh` is the single owner of the `fm-task-quality-contract.v1` contract and `fm-task-quality-evidence.v1` evidence formats.

The operator creates a contract and evidence record before dispatch:

```text
bin/fm-task-quality.sh init contract.json evidence.json
```

The contract must name the `no-mistakes` delivery path, the repository primary root, an isolated worktree, the exact 40-character base SHA, immutable operator intent, non-goals, constraints, consequence, uncertainty, allowed paths, execution limits, and mandatory commands.

Each check has an id, a phase, an operator-authored command, a mandatory flag, and an independent-evidence flag.

The contract must contain exactly one mandatory baseline check, at least one mandatory post-patch check, and at least one mandatory independent post-patch check.

Commands are executed sequentially in the named worktree with the declared wall limit.

The baseline runs only on a clean isolated worktree at the recorded base SHA.

The worker must then produce a committed patch before post-patch checks and patch assessment can run.

The normal sequence is:

```text
bin/fm-task-quality.sh init contract.json evidence.json
bin/fm-task-quality.sh run-check evidence.json baseline
bin/fm-task-quality.sh run-check evidence.json feature
bin/fm-task-quality.sh assess-patch evidence.json
bin/fm-task-quality.sh finalize evidence.json
```

The caller still launches the implementation worker with `bin/fm-spawn.sh` and sends accepted work through the existing no-mistakes validation and publication path.

The task-quality script does not duplicate no-mistakes review, test, document, lint, push, PR, or CI ownership.

## Deterministic boundaries

The route is derived before execution.

Ambiguous intent or non-empty missing-information routes to `clarify`.

A requested decomposition routes to `human-approved-decomposition`.

Otherwise the route is `single-bounded-task`.

Model confidence, issue length, prose conveniences, benchmark labels, gold patches, reference patches, hidden evaluator material, and retrospective outcome features are not contract inputs and are rejected where named as operational fields.

A worker-authored acceptance field cannot finalize a record.

Every mandatory check must have passed evidence before normal acceptance.

A failed or missing baseline blocks post-patch checks.

A changed submitted head invalidates prior patch evidence.

Patch metrics are computed only from `base_sha..head_sha` in the submitted repository.

Only paths under `allowed_paths` are ordinary scope.

Unexpected paths and material-consequence work produce `needs-human` even when checks are green.

A step budget stops execution and preserves a budget-stop event.

A timed-out command preserves its command, head, output, exit code, and status.

A decomposition validation requires independently accepted child evidence and a passed mandatory parent integration check.

The parent still requires the human-approved route and is not silently converted into an autonomous fan-out.

## Evidence record

The evidence record retains the contract path and SHA-256 digest, a copy of the contract, the derived route, repository identity, base and submitted heads, status and disposition, step count, every check command and result, output, timestamps, patch metrics, unexpected paths, decomposition validation, and event entries.

A changed contract digest, changed submitted head, missing mandatory evidence, forbidden operational fields, or incomplete patch assessment produces a blocked or human-required outcome rather than success.

The evidence record is task-local and should be retained with the task's review material.

Do not place benchmark or evaluator-side material in the operational contract or evidence record.

A separate prospective evaluation may join held-out labels after execution by task and evidence digest, under an evaluation-only owner.

## Evaluation and non-goals

Compare the prototype prospectively with the existing Firstmate plus no-mistakes path on new tasks, keeping model, budget, repository checks, and evaluator fixed in the first comparison.

Stratify and randomize using only pre-task semantic information, and hold out repository families for transfer measurement.

Measure independent acceptance with complete mandatory evidence, false acceptance, repair rate, abstention quality, review time, cost, regressions, scope crossings, and evidence completeness.

Falsify routing if it does not improve quality or repair efficiency, increases cost without compensating quality, accepts a material-consequence defect, or omits mandatory evidence.

Promotion requires held-out validation, no leakage, no self-authored acceptance, complete mandatory checks, a useful abstention path, and submitted-patch evidence.

This phase does not add automatic model switching, autonomous decomposition, parallel fan-out, hidden-test access, gold-patch use, unsupervised self-improvement, or a new pi-workflow bundle.

## Verification

Run the focused behavior suite with:

```text
bin/fm-test-run.sh tests/fm-task-quality.test.sh
```

Run the repository lint owner before delivery:

```text
bin/fm-lint.sh bin/fm-task-quality.sh tests/fm-task-quality.test.sh
```
