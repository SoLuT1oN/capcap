# AI Calendar Fork Changelog

Private fork changes are recorded here. Keep CHANGELOG.md identical to upstream to avoid conflicts when official releases add entries.

## [Unreleased]

## [1.7.11-ai.2] - 2026-09-05

### Added
- Add an optional reminder switch for each event in the AI Calendar confirmation panel, disabled by default

## [1.7.11-ai.1] - 2026-09-03

### Added
- Add AI Calendar to extract events from a screenshot and add them to Apple Calendar after confirmation
- Add a host-scoped ATS exception for the explicitly configured HTTP AI gateway without enabling arbitrary HTTP loads

## Release maintenance

- Sync Upstream checks the latest published stable official Release, merges only its release-vX.Y.Z tag, validates the result, and starts the private release workflow when it pushes a new release
- Resolve conflicts on a separate branch and retain both upstream behavior and private AI Calendar integration
- After a manual merge into private main, explicitly run Release AI Calendar Build if that commit has not been released; a no-change sync run does not start a release
- The private release workflow updates SoLuT1oN/homebrew-tap after publication

### Official release tracking

- `.github/upstream-release.json` records the last synchronized tag and commit; `history_commit` records the verified ancestry anchor (normally the same commit)
- No new stable version means no merge or private release; unpublished main changes are ignored
- The previous tag is fetched and checked even when there is no new release; moved or missing tags, older versions, rewritten history and conflicts stop synchronization for manual review
- The September 2026 history repair links rewritten commit `3c19b2f` to the private history without changing app files because its tree exactly matches the already synchronized `b8ecde7`; the official 1.7.14 tag still points to `b8ecde7`
- Run `python3 -B scripts/test_sync_upstream_release.py` for disposable-repository regression tests
