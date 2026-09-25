# ci-workflows

Shared GitHub Actions pipeline for my repositories. Every pull request gets:

| Check | What it does | Tool |
|---|---|---|
| **Lint** | Code-quality rules | the project's `lint` script (e.g. oxlint, ESLint) |
| **Unit, integration & regression tests** | Tests of single pieces, pieces working together, and previously fixed bugs | the project's `test:unit`, `test:integration`, `test:regression` scripts (e.g. Vitest) |
| **Build** | Proves the project still builds | the project's `build` script |
| **End-to-end tests** | Drives the real app in a browser | the project's `test:e2e` script (e.g. Playwright) |
| **CodeQL** | Static application security testing (SAST) and code-quality queries | [CodeQL](https://codeql.github.com/) |
| **Dependency review** | Blocks PRs that *add* a dependency with a known vulnerability | [dependency-review-action](https://github.com/actions/dependency-review-action) |
| **npm audit** | Checks *all* npm dependencies for known vulnerabilities | `npm audit` |
| **Dependabot** | Weekly PRs that update dependencies and actions | [Dependabot](https://docs.github.com/code-security/dependabot) |

The pipeline also runs on pushes to `main` and weekly, so new vulnerabilities in unchanged code are still found.

## How it works

The logic lives here, in two [reusable workflows](https://docs.github.com/actions/using-workflows/reusing-workflows):

- [`node-ci.yml`](.github/workflows/node-ci.yml): lint, tests, build and end-to-end tests for Node.js projects.
- [`security.yml`](.github/workflows/security.yml): CodeQL, dependency review and npm audit, for any language CodeQL supports.

Each project has one short `.github/workflows/ci.yml` that calls them. Fix or improve the pipeline here once and every project picks it up.

`node-ci.yml` works with any Node project because it reads `package.json` and runs only the scripts that exist:

| Script | Runs in job |
|---|---|
| `lint` | Lint |
| `test:unit`, `test:integration`, `test:regression` | Tests (each as its own step, so you can see which kind failed) |
| `test` | Tests (only if none of the three above exist) |
| `build` | Build |
| `test:e2e` | End-to-end tests |
| `test:e2e:install` | Installs the browsers for `test:e2e`. Defaults to `npx playwright install --with-deps` |

Anything missing is skipped. You can adopt the pipeline first and add test types over time.

## Add it to a repository

From this repo, run the setup script with the path to the other repo (Git Bash on Windows works):

```sh
scripts/add-to-repo.sh ../my-project                # project at the repo root
scripts/add-to-repo.sh ../Directors-notes --dir app # project in a subfolder
```

The script detects Node, Python or Ruby projects (override with `--type`). It writes:

- `.github/workflows/ci.yml`: calls the shared workflows. Node projects get everything. Python and Ruby projects get the security scans; add a job for their own tests.
- `.github/dependabot.yml`: weekly dependency and action updates.

For Node projects it also lists which standard scripts are present or missing. It never overwrites existing files unless you pass `--force`.

Then commit, push, and do the one-time setup below.

### One-time setup per repository

1. **Make the checks required.** A failing check is only a warning until you require it. Go to **Settings → Rules → Rulesets → New branch ruleset**:
   - Target the default branch (`main`).
   - Enable **Require a pull request before merging**.
   - Enable **Require status checks to pass**, and add the checks from a CI run on that repo, e.g. `Quality & tests / Lint`, `Quality & tests / Unit, integration & regression tests`, `Quality & tests / Build`, `Quality & tests / End-to-end tests`, `Security / npm audit`, `Security / Dependency review`.
   - Enable **Require code scanning results** with the CodeQL tool, so PRs that add high-severity security alerts can't merge.
2. **Turn on security features** in **Settings → Advanced Security** (all free for public repos): Dependency graph, Dependabot alerts, Dependabot security updates, and Secret protection (secret scanning and push protection).

## Setting up tests in a Node project

A typical setup, as used in [Directors-notes](https://github.com/CyberSinclair/Directors-notes/tree/main/app):

```sh
npm install -D vitest jsdom @testing-library/react @testing-library/jest-dom @testing-library/user-event @playwright/test
```

```json
"scripts": {
  "lint": "oxlint --deny-warnings",
  "test": "vitest run",
  "test:unit": "vitest run tests/unit",
  "test:integration": "vitest run tests/integration",
  "test:regression": "vitest run tests/regression",
  "test:e2e": "playwright test",
  "test:e2e:install": "playwright install --with-deps chromium"
}
```

- **Unit tests** (`tests/unit`): one function or component on its own, with small hand-made data.
- **Integration tests** (`tests/integration`): the whole app rendered with real data, driven by simulated clicks.
- **Regression tests** (`tests/regression`): one test per bug that was fixed, with a comment describing the original bug, so it can't come back unnoticed.
- **End-to-end tests** (`e2e/`): Playwright drives a real browser against the production build.

Lint scripts should fail on warnings (for oxlint, `--deny-warnings`). Otherwise the Lint check passes even when there are problems.

## Settings

Pass these under `with:` in a project's `ci.yml`.

**`node-ci.yml`**

| Input | Default | |
|---|---|---|
| `working-directory` | `.` | Folder with `package.json` |
| `node-version` | `lts/*` | Node.js version |
| `run-e2e` | `true` | Set `false` to skip end-to-end tests |

**`security.yml`**

| Input | Default | |
|---|---|---|
| `working-directory` | `.` | Folder with `package-lock.json` for npm audit |
| `codeql-languages` | `["javascript-typescript", "actions"]` | JSON list, e.g. `["python", "actions"]` |
| `codeql-queries` | `security-and-quality` | Or `security-extended` for security rules only |
| `dependency-review-severity` | `moderate` | Lowest severity that blocks a PR adding a dependency |
| `npm-audit-level` | `high` | Lowest severity that fails npm audit |

CodeQL runs with `build-mode: none`, which supports JavaScript/TypeScript, Python, Ruby and GitHub Actions. Compiled languages such as Go or C++ need a build step added.

## Versions

Projects call the workflows at the `v1` tag (`...node-ci.yml@v1`).

- **Compatible change** (bug fix, new optional input): merge to `main`, then move the tag so every project picks it up:
  ```sh
  git tag -f v1 && git push -f origin v1
  ```
- **Breaking change** (renamed input, different script names): tag `v2`, and update projects one at a time by changing `@v1` to `@v2` in their `ci.yml`.

Changes to this repo are checked by its own [Self-check](.github/workflows/self-check.yml) workflow. It lints the workflows with actionlint and the script with ShellCheck, and tests the setup script on sample projects.
