# sqlsimtools Assets

This folder contains shared visual assets for the sqlsimtools repository and
its tools.

## Files

| File | Use case |
| --- | --- |
| `sqlsim-icon.svg` | Studio favicon, app icon, small displays |
| `sqlsim-logo.svg` | Generated sqlsim HTML documentation |
| `sqlsimtools-logo.svg` | Root README and project branding |
| `sqlsimstudio-demo.gif` | Click-to-play Studio walkthrough on the landing page; blog and social posts |
| `sqlsimstudio-blog-hero.png` | Landing-page walkthrough poster; blog and social posts |
| `sqlsimtools-four-ways.png` | Root README; four-quadrant Studio, CLI, and GitHub Copilot overview |
| `sqlsimtools-four-ways-blog.png` | 2.4:1 four-quadrant blog banner |
| `sqlsimtools-social-preview.png` | 1280x640 GitHub social preview (Settings > General > Social preview); the four-quadrant banner padded to 2:1. Also copied to `docs/assets/` for the GitHub Pages link-preview image |
| `querystats-report.png` | sqlsim manual |

The GitHub Pages site serves only `docs/`, so `docs/assets/` keeps copies of
`sqlsimtools-logo.svg`, `sqlsim-icon.svg` (site icon), and
`sqlsimtools-social-preview.png`, `sqlsimstudio-demo.gif`, and
`sqlsimstudio-blog-hero.png`. Update those copies when you change the originals.
The landing page does not load the animated GIF until the visitor plays it.
When publishing a new release, update the versioned Windows bundle download
link and version label in `docs/index.html`.

## Design Elements

- **Navy and blue database cylinder** - Represents SQL Server / database
- **"SQL" text** - Prominent white text inside cylinder for instant recognition
- **Silver forward arrows** - Represents workload simulation and performance testing
- **Color scheme**:
  - Blue (#1268a8 / #4a91c7) - SQL and database
  - Navy (#0b2f5b) - Product identity and depth
  - Silver (#d9e0e6) - Performance and motion
  - White - SQL text and arrow contrast

The icon is intentionally theme-neutral. Applications may provide their own
theme colors around it without changing the sqlsim product mark.

## Converting to Other Formats

### PNG (using Inkscape CLI)

```powershell
inkscape sqlsim-icon.svg -o sqlsim-icon-128.png -w 128 -h 128
inkscape sqlsim-icon.svg -o sqlsim-icon-256.png -w 256 -h 256
inkscape sqlsim-logo.svg -o sqlsim-logo.png -w 400 -h 120
```

### ICO for Windows (using ImageMagick)

```powershell
magick sqlsim-icon.svg -define icon:auto-resize=256,128,64,48,32,16 sqlsim.ico
```

## Usage from the repository root

```markdown
![sqlsim logo](assets/sqlsim-logo.svg)
```

## Rebuilding the Studio demo GIF

Build Studio first, then capture the real packaged UI against a local SQL
Server and assemble the frames:

```powershell
Set-Location sqlsimstudio
.\build.ps1 -Runtime win-x64
node .\gui-tests\capture-demo.cjs
python .\gui-tests\assemble-demo-gif.py `
  .\build\demo-gif-frames `
  ..\assets\sqlsimstudio-demo.gif
```

The capture runs real query, SQL file, workload, replay, monitoring, results,
comparison, console-output, and PowerShell scenarios. It also shows Studio
themes and closes with the Agent Plugins and installed-skills workflow. Review
the generated GIF before committing it.
