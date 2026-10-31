# CLAUDE.md

Guidance for Claude working in this repository. [docs/plan.md](docs/plan.md)
has the design and phases. Every pull request links the issue it
resolves (`Closes #N`) and passes CI.

## Review gate

No PR merges without an independent review. The thread or person who
wrote a PR doesn't review it.

- A scheduled review session reviews each open PR once CI is green: the
  code-review skill at high effort, the PR against its issue's
  acceptance criteria, and the PR template's Verification checklist
  against the diff. It posts one GitHub review ending in
  `Review: pass`, `Review: changes needed`, or `Review: needs Thomas`,
  and adds the `review: pass` label on a pass.
- The `review-gate` check passes only with that label. A push removes
  it, so new commits get a new review. Dependabot PRs skip review.
- The author fixes review comments the way it fixes CI failures, then
  waits for the next review. Don't add `review: pass` to your own PR.
- `Review: needs Thomas` means the PR adds a dependency, a crate or
  package, an advisory ignore or license exception, `unsafe` code, new
  network surface, or an API change. Thomas decides and
  adds the label.

## Spikes

A PR that tries an approach before committing to it gets the `spike`
label. It may merge when its new code is off by default (behind a
feature or option, or not routed) or confined to its own module or
crate, and its follow-up issues are filed. The review is lighter on
style, not on dependencies, advisory ignores, or anything on by default.
