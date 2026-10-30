# Clash Kuro icons

ayu-based black-cat icons on a 100 grid. `icon-mirage-gold.svg` is the app icon; the others are alternates, not used at runtime.

| File | Look |
| --- | --- |
| `icon-mirage-gold.svg` | App icon. Mirage gold `#ffcd66 → #eebd55`, head `#1f2430`, eyes `#ffe3ac` |
| `icon-apricot.svg` | Apricot `#ffe3ac → #ffcd66`, eyes `#f29718` |
| `icon-mirage-gold-moon.svg` | Mirage night `#282e3b → #1f2430` with a `#ffcc66` moon |
| `icon-light.svg` | ayu Light `#fcfcfc → #ebeef0`, eyes `#f29718` |

Regenerate `apps/desktop/build/icon.icns` and `icon.ico` from `icon-mirage-gold.svg` with `bun run icons` in `apps/desktop` (macOS only, needs `iconutil`). The tray icon is drawn in code from the same head and eye paths (`apps/desktop/src/main/tray-icon.ts`).

## UI colours

`apps/desktop/src/renderer/src/styles.css` uses ayu Light and ayu Mirage and follows the system appearance. Light-theme accent text uses `#995d09` (`#f29718` darkened) to reach 4.5:1 on `#fcfcfc`, `#f8f9fa` and the 12% accent tint; `#f29718` itself (2.2:1) is only used for fills and outlines. Secondary text keeps the reference values `#828e9f` (Light, 3.2:1) and `#707a8c` (Mirage, 3.4:1 on `#242936`), which are below 4.5:1 for small text.
