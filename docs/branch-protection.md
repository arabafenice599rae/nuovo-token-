# Branch protection

`main` is meant to be reachable only through a pull request whose three CI
checks are green. The configuration lives in the repository rather than only in
the GitHub UI, so it can be reviewed, diffed and re-applied:
[`.github/rulesets/main.json`](../.github/rulesets/main.json).

## Plan caveat: nothing is enforced here yet

This repository is **private under a personal account**, and GitHub does not
enforce either mechanism in that combination:

| | Public repo | Private repo |
| --- | --- | --- |
| Rulesets | enforced on Free | **only on a Team organization** |
| Classic branch protection | enforced on Free | **only on Pro, Team or Enterprise** |

Creating a ruleset here still succeeds — the UI accepts it and the API returns
201 — but GitHub shows *"Your rulesets won't be enforced on this private
repository until you move to a GitHub Team organization account"*, and merges
continue to go through with red or unfinished checks.

Three ways out, in order of cost:

1. **Make the repository public.** Rulesets are enforced immediately, at no
   cost. The contract is meant to be verifiable by anyone anyway, so this is
   usually the natural end state for a launch.
2. **Move it to an organization on the Team plan.** Keeps it private and makes
   this ruleset enforced as written.
3. **GitHub Pro on the personal account.** Keeps it private, but rulesets stay
   unenforced: on Pro the working mechanism is *classic branch protection*, so
   use the terminal snippet in the section below rather than the ruleset.

Until one of those is true, the ruleset in this repository is a declaration of
intent, not a gate. `.github/workflows/apply-ruleset.yml` can be run whenever
you like — the ruleset it creates simply starts being enforced the moment the
plan allows it.

## What it enforces

| Rule | Effect |
| --- | --- |
| Required status checks | `Build & test`, `Slither` and `Aderyn` must pass before a merge |
| Strict policy | the branch must be up to date with `main` before merging, so the checks run against what will actually land |
| Pull request required | no direct pushes to `main`; zero approvals required, so a solo maintainer is not blocked |
| Review thread resolution | open review threads block the merge |
| No deletion, no force push | `main` cannot be deleted or rewritten |
| Empty `bypass_actors` | admins are not exempt — this is what stops a merge before CI finishes |

The check names must match the job names in `.github/workflows/ci.yml`
character for character, `&` included. Renaming a job means updating this file
in the same commit, otherwise the required check never reports and every PR
stays blocked.

## Applying it

The ruleset is not applied automatically: GitHub has no mechanism to read a
ruleset from the repository. There are two ways to push it live.

### From the Actions tab

`.github/workflows/apply-ruleset.yml` does it for you: **Actions → Apply ruleset
→ Run workflow**. It creates the ruleset, or updates it in place if one named
`main` already exists, then prints what is live — including the three required
check names — so the run log is the receipt.

The workflow is `workflow_dispatch` only: something that can change repository
settings must never be reachable from an event an outsider can trigger.

It runs with `administration: write` on the automatic `GITHUB_TOKEN`. If that
token turns out not to carry enough scope for the rulesets API, the run fails
with a 403 and the fix is a fine-grained PAT with **Administration: read and
write** on this repository, stored as the `RULESET_TOKEN` secret — the workflow
prefers it when present.

### From a terminal

With an authenticated `gh`:

```bash
gh api -X POST repos/arabafenice599rae/nuovo-token-/rulesets \
  -H "Accept: application/vnd.github+json" \
  --input .github/rulesets/main.json
```

Updating an existing ruleset (find its id with the list command below):

```bash
gh api -X PUT repos/arabafenice599rae/nuovo-token-/rulesets/<id> \
  -H "Accept: application/vnd.github+json" \
  --input .github/rulesets/main.json
```

Verifying what is actually live:

```bash
gh api repos/arabafenice599rae/nuovo-token-/rulesets --jq '.[] | {id, name, enforcement}'
gh api repos/arabafenice599rae/nuovo-token-/rulesets/<id> --jq '.rules'
```

In the UI the same settings are under **Settings → Rules → Rulesets**.

## Classic branch protection

If you prefer the older API, this is the equivalent:

```bash
gh api -X PUT repos/arabafenice599rae/nuovo-token-/branches/main/protection \
  -H "Accept: application/vnd.github+json" --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "checks": [
      {"context": "Build & test"},
      {"context": "Slither"},
      {"context": "Aderyn"}
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {"required_approving_review_count": 0},
  "restrictions": null
}
JSON
```
