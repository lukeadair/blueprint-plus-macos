# Blueprint+ for macOS

Native Mac port of the Android app in `../blueprint-plus` (same features, same job file format). Cabinet takeoffs:
open a PDF plan, set the scale, click points along each run, get linear footage by room. Swift 6 + SwiftUI
(AppKit for the plan canvas), macOS 26+ (Liquid Glass), no dependencies, no network.

The Android repo's `CLAUDE.md` is the spec for all behaviour (room labels, wall finding, seeding, undo rules,
export). Read it before changing logic here; this file only covers what differs.

## Commands
```sh
xcodebuild -project BlueprintPlus.xcodeproj -scheme BlueprintPlus -destination 'platform=macOS' test   # unit tests
xcodebuild -project BlueprintPlus.xcodeproj -scheme BlueprintPlus -configuration Release build
```
Release: bump `MARKETING_VERSION`, commit, `scripts/release.sh` (tests, universal DMG, GitHub release, bumps the cask
in `../homebrew-tap`; `DRY_RUN=1` stops after the DMG). Unsigned (no Developer ID): the cask strips quarantine.
App icon: `swift scripts/make-icon.swift icons BlueprintPlus/Assets.xcassets/AppIcon.appiconset docs/images/icon.png`
draws every size (edit the style values in the script, never the PNGs).
The project uses file-system-synchronized groups: new files in `BlueprintPlus/` or `BlueprintPlusTests/` are in the
build automatically, no pbxproj edits.

UI check without Screen Recording permission (Debug builds only): `open --env BP_SNAPSHOT=1 [--env BP_TOOL=select|measure|rooms] [--env BP_HOVER=x,y] [--env BP_SELECT=1] <app>`
writes `~/Library/Containers/com.lukeadair.blueprintplus/Data/tmp/snapshot.png` (window) and `plan.png` (canvas). Liquid
Glass doesn't render in these captures (sidebar and glass HUDs come out white); `plan.png` is exact.

## Layout
- Pure, ported line for line from the Kotlin files of the same name, no AppKit/SwiftUI: `Geometry.swift` (`Offset`/`Rect`
  mirroring Compose's, incl. half-open `contains` and non-standardized rects; Kotlin's `roundToInt`), `Scale.swift`,
  `Job.swift` (Codable with Android's JSON keys), `Rooms.swift` (labels, OCR labels, `inTable`, `WallFinder`),
  `Boundaries.swift`, `Export.swift` (hand-written xlsx with a stored-ZIP writer + CRC32).
  Keep them pure. The Android app is maintained separately: never edit `../blueprint-plus`.
- `BlueprintPlusTests/`: the Android unit tests ported to Swift Testing, same cases. Doubles replace Kotlin floats,
  so exact float equality can need a 1e-9 tolerance (`moveEdgeSlidesTheWallSidewaysOnly`).
- `JobStore.swift`: `~/Library/Containers/com.lukeadair.blueprintplus/Data/Library/Application Support/Blueprint+/jobs/<id>.json|pdf`,
  atomic writes. A job file + PDF copied over from the phone opens as is.
- `PDFPages.swift`: `PlanPDF` actor (PDFKit isn't thread-safe: the Android `pdfThread`). Renders at the same scale as
  Android (≤4096 px, ≤4x) so stored run pixels mean the same thing. Text boxes come from `page.selection(for:)` bounds
  through `page.transform(for: .cropBox)`, flipped to top-left points; works on rotated pages. OCR is Vision
  (`RecognizeTextRequest`) at **5 px/pt** in 2048 px tiles with 200 pt overlap, not ML Kit's 3 px/pt: Vision misses
  small plan text at 3, and shrinks larger tiles internally. `minimumTextHeightFraction` must stay low or it skips labels.
- `JobModel.swift`: JobScreen's state and logic. `update { }` saves every change; Compose's keyed `LaunchedEffect`s
  (room re-pick, seeding) are `kick()`, which restarts a task when its inputs change.
- `PlanView.swift`: AppKit `NSView` canvas (SwiftUI has no scroll-wheel/hover/right-click precision). Draws inside
  `withObservationTracking`, so anything it reads redraws it. Room colors use Java's `String.hashCode` (Swift's
  hash is per-launch random).
- `JobView.swift` (toolbar, glass HUD, dialogs), `RunListView.swift` (inspector), `HomeView.swift` (sidebar),
  `JobConfigView.swift`, `AppState.swift`, `BlueprintPlusApp.swift` (single `Window`, menus).

## Mac interaction (vs the phone)
- Tools (toolbar, or V / M / R on the plan): Select, Measure, Rooms.
- Measure: hold Shift for the loupe (no grabber) (also while dragging a node); click adds a point, Space too; arrows nudge it 1 px
  (Shift: 10); Return or double-click finishes; Delete removes the last point; Esc cancels. Same 8 pt min gap.
- Select: hover highlights, click selects; drag a node (Shift: loupe floats above it); ⌥-click or right-click removes a node;
  double-click the selected run or click a segment's middle dot to add a node (a plain click doesn't: too easy to
  hit with a mouse). Delete removes the run.
- Rooms: click a room, drag corners and wall dots, click a wall dot to add a corner, ⌥-click/right-click a corner to
  remove it. HUD: Add Room, Redetect, Delete, Done.
- Pan: scroll, or drag empty paper. Zoom: pinch, ⌘-scroll, a mouse wheel, ⌘+/⌘−/⌘0. Smart zoom (two-finger double tap).
- Run list: drag a row onto another room's header or rows (native drag and drop); context menus for move/rename/delete.
- Focus mode: ⌘F (View menu) hides the job list and the run list; press again to bring both back.
- ⌘Z/⇧⌘Z use the job's own snapshot history (same rules as Android); in a text field they undo text instead.

## Rules
- Accuracy is the product: any parsing or math change gets a test.
- No new dependencies. Bundle id `com.lukeadair.blueprintplus`; never change it (it's the data container).
