# capcap AI CI/CD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify a gated upstream-sync, custom GitHub Release, and private Homebrew Cask pipeline for the AI Calendar fork.

**Architecture:** The capcap repository owns upstream merge validation and custom release packaging; the Tap repository owns only Cask generation and validation. Cross-repository dispatch is optional, so a missing token never invalidates a successfully built Release, while every code or Cask mutation remains behind tests.

**Tech Stack:** GitHub Actions, Bash, Swift Package Manager, AppKit/EventKit tests, GitHub CLI/API, Homebrew Cask Ruby DSL

---

### Task 1: Preserve the completed AI Calendar implementation on `main`

**Files:**
- Import: `capcap/AICalendar/*`
- Import: `Tests/capcapTests/AICalendar*Tests.swift`
- Import: `Tests/capcapTests/CalendarEventServiceTests.swift`
- Modify: `Package.swift`, `capcap/App/Info.plist`, Toolbar, Settings, Translation, Defaults, localizations and READMEs from commits `59df920..b36ec23`

- [x] **Step 1: Verify both source and destination use upstream v1.7.11 commit `ec4b221`**
- [x] **Step 2: Fetch the clean local `feat/ai-calendar` branch and cherry-pick its four commits in order**
- [x] **Step 3: Run `swift build` and confirm exit 0**
- [x] **Step 4: Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` and confirm 232 tests, 0 failures**

### Task 2: Add gated upstream synchronization

**Files:**
- Create: `.github/workflows/sync-upstream.yml`

- [ ] **Step 1: Add schedule and manual triggers with minimal write permissions**

```yaml
on:
  schedule:
    - cron: "17 3 * * *"
  workflow_dispatch:
permissions:
  contents: write
  actions: write
```

- [ ] **Step 2: Fetch `upstream/main`, detect no-op, and merge without pushing**

```bash
if git merge-base --is-ancestor upstream/main HEAD; then
  echo "No upstream changes."
  exit 0
fi
git merge --no-edit upstream/main
```

- [ ] **Step 3: On conflict, write `git diff --name-only --diff-filter=U` to `$GITHUB_STEP_SUMMARY`, abort, and fail**
- [ ] **Step 4: Before push run `swift build`, full `swift test`, AI Calendar filtered tests, and universal release build**
- [ ] **Step 5: Push `HEAD:main` without force, then dispatch `release-ai.yml --ref main`**

### Task 3: Add idempotent custom Release workflow

**Files:**
- Create: `.github/workflows/release-ai.yml`

- [ ] **Step 1: Read `CFBundleShortVersionString` and compute the next `custom-v<base>-ai.N` tag**
- [ ] **Step 2: Reuse an incomplete tag on current HEAD or skip when its Release already exists**
- [ ] **Step 3: Reproduce the official universal build, tests, bundle assembly, resource validation, signing fallback, ZIP, DMG and checksums**
- [ ] **Step 4: Create `capcap <version>` Release with all four assets and the required upstream/custom body**
- [ ] **Step 5: If `HOMEBREW_TAP_TOKEN` is set, dispatch `capcap_ai_release_published`; otherwise write a warning and succeed**

### Task 4: Add fork documentation and local validation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add `Custom Build / AI Calendar` with first install, upgrade, and official-Cask conflict instructions**
- [ ] **Step 2: Parse workflow YAML and run `git diff --check`**
- [ ] **Step 3: Test no-update merge logic in an isolated temporary branch state without changing remote main**
- [ ] **Step 4: Run debug build, full tests, filtered AI tests, compile check, and universal release build**

### Task 5: Create the private Tap automation

**Files:**
- Preserve: `Casks/capcap.rb`
- Create: `Casks/capcap-ai.rb`
- Create: `scripts/generate-capcap-ai-cask.sh`
- Create: `.github/workflows/bump-capcap-ai.yml`
- Modify: `README.md`

- [ ] **Step 1: Fork `realskyrin/homebrew-tap` as `SoLuT1oN/homebrew-tap` and clone it separately**
- [ ] **Step 2: Add a generator that validates version/SHA/tag/asset and writes only `Casks/capcap-ai.rb`**
- [ ] **Step 3: Add repository-dispatch/manual workflow with `contents: write`, syntax/style/audit checks, and exact-file commit**
- [ ] **Step 4: Document `SoLuT1oN/tap/capcap-ai` install and upgrade commands**
- [ ] **Step 5: Run generator fixtures, `ruby -c`, and `brew style`; commit and push the Tap automation**

### Task 6: Exercise GitHub workflows and publish the first private release

**Files:**
- Remote: `SoLuT1oN/capcap`
- Remote: `SoLuT1oN/homebrew-tap`

- [ ] **Step 1: Commit only the capcap CI/CD files after local verification and push `main` to `origin`**
- [ ] **Step 2: Enable/dispatch `sync-upstream.yml`, wait for completion, and confirm no Release or Tap mutation on `No upstream changes.`**
- [ ] **Step 3: Dispatch `release-ai.yml`, wait for completion, and inspect Release assets/checksums/signing log**
- [ ] **Step 4: Generate the real Cask from the published ZIP SHA256, run metadata checks, commit, and push**
- [ ] **Step 5: Verify both repository commit hashes, workflow status, Release URL, Cask version, and remaining Secret requirement**
