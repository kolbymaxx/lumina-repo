# Lattice — layout surfaces

Same rule as Glyph's `SURFACES.md`: a surface is only touched once its shape is
confirmed on the firmware in question. Guessing at a private class is how a
layout tweak earns a Safe Mode, and the icon grid is the single most dangerous
place in SpringBoard to guess.

Status legend:

- `SHIPPED` — hooked in 0.1.0, selector existence verified at runtime before `%init`
- `NEEDS DUMP` — plausible, but the shape is unconfirmed on 16.7 and/or 17.x; **not** implemented
- `OUT OF SCOPE` — deliberately not Lattice's job

## Shipped

| Capability | Hook | Risk | Notes |
|-----------|------|------|-------|
| Rows / columns per page | `-[SBIconListGridLayoutConfiguration numberOfPortrait{Rows,Columns}]` | Low | Returns an integer. Worst case is an ugly grid. |
| Landscape rows / columns | `…numberOfLandscape{Rows,Columns}` | Low | Defaults to portrait, swapped. |
| Dock width | Same class, discriminated by row count | Low | See below. |
| Hide icon labels | `-[SBIconView layoutSubviews]` → `labelView.hidden` | Low | Reversible; a respring restores it. |

### Telling the dock apart from a page

The dock is laid out by the same `SBIconListGridLayoutConfiguration` class as
the icon pages, so an unconditional override stretches the page grid across the
dock and deforms it. Lattice discriminates on the configuration's **own** row
count — a dock is one row, an icon page never is:

```objc
NSUInteger orig = %orig;
if (orig <= 1) return orig;   // dock
```

That asks the object what it already is, rather than matching against a private
dock-specific class name that may be spelled differently across releases.

## Needs a dump before implementation

| Capability | Why it is not shipped |
|-----------|----------------------|
| Icon scale | Needs `-[SBIconListGridLayoutConfiguration iconImageInfo]`, which returns an `SBIconImageInfo` **struct**. Hooking a struct return with the wrong field layout is an immediate crash, and the layout is unverified on 16.7 vs 17.x. |
| Icon / row spacing | Same configuration object, same struct-shape question. |
| Blank slots, free placement | Requires inserting placeholder icons into `SBIconListModel` — i.e. **mutating the icon model**. That is a different risk class from returning a number: a bad write persists to the icon state file and survives a respring, so a mistake is not self-healing. Gated on a confirmed dump plus a backup/restore path for the icon state. |
| Per-page grids | Needs a reliable page index at configuration time. The configuration object does not carry one, so this needs a confirmed relationship between `SBIconListView` and its configuration. |

## How to confirm a row

1. Enable SwiftPeek with `enabled` + `targetSpringBoard` + `sbScanWindows`.
2. Pull `$jbroot/var/mobile/Library/SwiftPeek/dumps/SpringBoard_<ts>.json`.
3. For struct-returning selectors, a dump is not enough on its own — check the
   field layout against the headers for that exact firmware before writing the
   hook.
4. Record the evidence here, then implement.
