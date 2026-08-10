# SwiftPeek — concurrent branch reconciliation

Three branches changed SwiftPeek at the same time, from three different agents.
Two of them disagree about something substantive, so this is written down rather
than resolved silently by whoever merges last.

| PR | Branch | SwiftPeek version | What it does |
|----|--------|-------------------|--------------|
| #59 | `claude/continue-1-1-21-owif9e` | **0.4.1** | Per-window level/frame/alpha dumps, depth-3 subtree, **pref-driven per-process targets**, SSH kill switch. Adds `SPKit` shared runtime. Targets Music, Podcasts, TV, Preferences, SiriViewService, assistantd. |
| (this) | `claude/swiftpeek-springboard-recon` | **0.4.0** | Icon inventory + M3 pixel signatures, hook-free hosting-view scan, **opt-in SpringBoard target**. Host analyser (`icons`, `tint-plan`) feeding Glyph. |
| #47 | `cursor/swiftpeek-host-polish-99e4` | unchanged | Host tooling only: catalog browse, richer KVC scaffold stubs. Bumps `tools/swiftpeek` to `0.6.0`. |

## The disagreement: may SwiftPeek enter SpringBoard?

**#59 says no.** Its `SPAttach.m` states SpringBoard is *deliberately absent*
and cites the 0.2.1 Safe Mode. Its filter expands sideways into other apps
instead.

**#60 says yes, behind two opt-ins.** Glyph's `docs/SURFACES.md` cannot resolve
a single `PENDING DUMP` row without a SpringBoard dump, so Phase C is blocked
forever otherwise. It argues the 0.2.1 failure was a *Swift-linked dylib* in
SpringBoard, and that an ObjC-only build installing no hooks, walking no Swift
metadata, and gated behind `targetSpringBoard` + `sbScanWindows` (both default
off) is a different proposition.

**Settled on device, 2026-08-10.** SwiftPeek 0.4.0 ran in SpringBoard on
iPhone13,1 / iOS 17.3 with `targetSpringBoard` + `sbScanWindows` +
`iconInventory`: four dumps, no Safe Mode, no respring loop. The 0.2.1 failure
was a Swift-linked dylib, and an ObjC-only build installing no hooks does not
reproduce it. That is evidence, not opinion — but it is one device on one
firmware, and 16.7 has not been tried.

## Recommended resolution

If SpringBoard recon is allowed, #59's mechanism is the better vehicle: it
already has **pref-driven per-process targets**, which is a general version of
#60's single `targetSpringBoard` boolean. The reconciliation is then:

1. Merge #59 first. It is foundational (`SPKit`) and its SwiftPeek work is the
   larger of the two.
2. Renumber #60's SwiftPeek work to **0.4.2** and express SpringBoard as one
   more entry in #59's target list, deleting `targetSpringBoard` in favour of
   it. Keep `sbScanWindows` as the separate second gate, and keep the rule that
   `dumpFieldMeta` is forced off in SpringBoard.
3. Keep #59's SSH kill switch — it is strictly better than having none, and it
   matters *most* for the SpringBoard target.
4. Carry #60's `SPIconPeek` / `SPRenderPeek` across unchanged; they are additive
   and touch nothing #59 modifies.

If SpringBoard recon is **not** allowed, drop `SPIconPeek.m`, the filter entry
and the three prefs from #60, keep `SPRenderPeek.m` (it is process-agnostic),
and accept that Glyph Phase C stays blocked until another evidence source
exists.

## Host tooling (`tools/swiftpeek`)

#47 and #60 both bump `__version__` to **0.6.0** independently, and #59 also
edits `api.py` / `cli.py` / `test_api.py`. These are ordinary textual conflicts
with no disagreement behind them. Whoever merges last should land at **0.7.0**
and keep all three feature sets: catalog browse + scaffold stubs (#47), the
api/cli additions (#59), and `icons` / `tint-plan` (#60).

## Other duplication introduced by #60

`Halo/src/HAPrefs.m` and `Lattice/src/LTPrefs.m` are two more copies of the
jbroot/prefs/kill-switch boilerplate that `SPKit`'s `SPKRuntime` exists to
replace — its header already counted six. `Halo/src/HAPresenter.m`'s `HAWindow`
is a smaller `SPKOverlayWindow`. Both should be deleted in favour of SPKit once
#59 lands; they were not written against it because SPKit is not on `main` and
depending on an unmerged branch is worse than the duplication.
