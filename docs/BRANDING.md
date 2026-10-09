# Pastrix artwork

The purple clipboard P artwork was supplied by the project maintainer. The app, website, and README use this design. The menu bar uses a separately drawn, monochrome clipboard-and-P template image so macOS can adapt it to light and dark appearances.

## Assets

- `resources/Pastrix-master.png`: the supplied square artwork, encoded in generic sRGB without source metadata.
- `resources/Pastrix.iconset`: standard and Retina app icon sizes.
- `resources/Pastrix.icns`: packaged Mac app icon.
- `docs/assets/pastrix-icon.png`: 512-pixel website and README icon.
- `docs/menu-bar-icon-preview.png`: light and dark examples of the native template glyph.

Regenerate the iconset, ICNS, and website icon from the master by running `swift scripts/make-icon.swift` from the repository root. The script uses an explicit generic sRGB context and does not copy EXIF, display-specific profiles, or other source metadata.

## Artwork preparation

The supplied artwork is preserved, including its white outer background. ImageIO converts it to generic sRGB and produces each required Mac icon size without copying source metadata. No generated replacement artwork is used in this release.

Historical Paster release notes retain their original names. The old storage folder and bundle identifier also remain deliberately unchanged for upgrade compatibility; they are not displayed as the product name.
