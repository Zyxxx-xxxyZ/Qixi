# Board localization support set

## In scope
- **easy1–easy7** only
- Goal: outermost 19×19 **grid intersections** (not wood frame corners, not UI chrome)
- Target: ≥95% overall; **100%** on easy1–7 for platform screenshots

## Out of scope
- **medium1** (physical photo, strong perspective, stone occlusion at TR) — removed from the active set. Source kept under `excluded/` for possible future work only. Do **not** use it as a locator regression fixture.

## Anti-cheating / anti-overfitting rules
1. **Do not hardcode** coordinates, image hashes, filenames, or sizes for `needsupport` fixtures in the app locator.
2. **Do not** add special-case branches that only fire on these screenshots.
3. Locator changes must be **general geometry/vision** improvements (grid lines, dual-board main-board selection, UI margin rejection, etc.).
4. When measuring quality, compare predicted quads to `annotations/ground_truth.json` for **easy1–7 only** — never tune to pass a single image at the expense of the others.
5. If a case is too hard for a general method, **exclude it** (like medium1) rather than overfitting.
