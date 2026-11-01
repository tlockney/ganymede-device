# CLAUDE.md

Guidance for Claude working in this repository. [docs/plan.md](docs/plan.md)
has the design and phases. Every pull request links the issue it
resolves (`Closes #N`) and passes CI.

## Independent review

Every PR gets a review from a Claude session that didn't write it. A
scheduled reviewer reviews each open PR once CI is green: the
code-review skill at high effort, the PR against its issue's acceptance
criteria, and the PR template's Verification checklist against the
diff. It posts one GitHub review ending in `Review: pass` or
`Review: changes needed`. The review is advisory and makes every call
itself: it never waits on a person.

- The author treats `Review: changes needed` like a CI failure: fix it,
  or answer the finding on its thread with why not.
- New dependencies, advisory ignores, license exceptions, `unsafe`, new
  network surface, and API changes must be justified in the PR; the
  reviewer fails a PR that doesn't.

## Spikes

A PR that tries an approach before committing to it gets the `spike`
label. It may merge when its new code is off by default (behind a
feature or option, or not routed) or confined to its own module or
crate, and its follow-up issues are filed. The review is lighter on
style, not on dependencies, advisory ignores, or anything on by default.
