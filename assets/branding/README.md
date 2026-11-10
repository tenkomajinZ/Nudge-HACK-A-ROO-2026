# Nudge open book and spark

The logo is a symmetric rounded open book with a small four-point spark: study and a fresh start. Launcher assets use lavender `#CBB6FA` on deep purple `#241B45`. The transparent in-app mark is tinted with the Flutter theme primary color in light and dark appearances.

- [Editable SVG](nudge-logo.svg)
- [Transparent PNG](nudge-mark.png)
- [Launcher PNG](nudge-icon.png)

SVG and raster exports share quadratic-path geometry in `tools/export_brand.py`. Android adaptive backgrounds match the opaque exports; the foreground fits inside the central safe circle and also supplies Android's monochrome icon. iOS exports use the same symbol.

Rebuild: `python tools/export_brand.py`

Validate without writing: `python tools/export_brand.py --check`

Checks cover visible bounds centering, horizontal ink balance, vertical book/spark balance, and circular/adaptive launcher masks. The spark makes vertical ink distribution intentionally asymmetric. Inspect the mark at its actual 28px in-app size as well.

`nudge-source.png` and `generation-prompt.txt` retain an earlier concept for reference; they are not bundled app assets.
