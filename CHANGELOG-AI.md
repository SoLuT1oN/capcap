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

- Sync Upstream merges official main, validates the result, and starts the private release workflow when it pushes new changes
- Resolve conflicts on a separate branch and retain both upstream behavior and private AI Calendar integration
- After a manual merge into private main, explicitly run Release AI Calendar Build if that commit has not been released; a no-change sync run does not start a release
- The private release workflow updates SoLuT1oN/homebrew-tap after publication
