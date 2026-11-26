# Release checklist (`v1.0`)

Work top to bottom. A box is ticked only when the step was actually done; anything skipped is written down in the release notes as unvalidated.

## Before building

- [ ] `swift build -Xswiftc -warnings-as-errors -Xcc -Werror` and `swift test` pass; CI is green on every matrix entry.
- [ ] `BuildInfo.version` is the release version; `CHANGELOG.md` has a dated section for it.
- [x] MIT `LICENSE` added (the package script includes it in the archive). Confirm the copyright holder line is what you want.

## Artifacts

- [ ] `Scripts/package.sh` run for each architecture to ship (default `arm64`; add `x86_64` only if it can be tested).
- [ ] `lipo -info` and `vtool -show-build` output reviewed (architectures, minimum macOS), and `otool -L` shows only system libraries.
- [ ] Archive contains `rtop`, `man/rtop.1`, `completions/`, `LICENSE`, and `SHA256SUMS` matches.
- [ ] Each shipped architecture was **run** on matching hardware. Others are marked unvalidated.

## Signing

- [ ] Developer ID signing and notarization done (`DEVELOPER_ID`, `NOTARY_PROFILE` set for the script), and `spctl --assess` passes on a clean Mac; **or** the release notes say plainly that the binary is unsigned and give the source-build route. Never advise disabling Gatekeeper.

## Manual matrix

Run each scenario in each terminal (record the terminal and version):

| Scenario | Terminal.app | iTerm2 | Third terminal |
|---|---|---|---|
| Start, `q` quits, terminal restored | | | |
| Ctrl-C, `kill -TERM`, `kill -HUP` restore the terminal | | | |
| Resize down to 20×5 and back | | | |
| Filter, sort, tree, details | | | |
| Signal workflow on an owned child (`sleep 600`) | | | |
| `--theme light`, `--theme mono`, `--color 256`, `--color truecolor`, `NO_COLOR=1` | | | |
| Running with stdin or stdout redirected is refused with exit 1 | | | |

Also: minimum supported macOS and a newer release; Instruments Allocations/Leaks over 30 minutes (see `Performance.md`).

## Homebrew

- [ ] Formula filled in from `Packaging/rtop.rb.template` with the real release URL and checksum.
- [ ] `brew install`, `rtop --version`, `man rtop`, completions present, `brew uninstall` leaves nothing behind.

## Publish

- [ ] Tag `v1.0`; release notes state the validation status of each artifact and the known limitations (no mouse, no suspend, per-core class labels unclassified, memory pressure `unknown` until notified).
