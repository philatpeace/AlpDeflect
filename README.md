# AlpDeflect

**AlpDeflect** generates an interactive HTML deflection map for any structural timber truss job designed in ITW Alpine's intelliVIEW suite.

## Overview

Given a job number, AlpDeflect:
1. Queries the local Alpine SQL Server Express database (`Local`) for job metadata and item dimensions.
2. Scans the job directory for Alpine `.PE` (Plain English cutlist) and binary `.ENG` (engineering analysis) files.
3. Decodes Bottom Chord panel-point deflections from the proprietary `.ENG` binary format.
4. Lays out all trusses in a 2D building footprint (or schematic rack for generic jobs).
5. Generates a fully standalone, interactive HTML file with:
   - SVG deflection heatmap with color-coded nodes (green → yellow → red)
   - Hover tooltips (station, deflection, L/D ratio)
   - Filter buttons by framing type (Girders, Commons, Hips, Jacks, etc.)
   - Pulsing animation on the governing (peak deflection) node
   - Stat cards: max deflection, governing member, span fraction

## Usage

### Option 1 — Desktop batch launcher (drag-and-drop)
Drag any file from the job folder onto `Generate-DeflectionMap.bat`, or double-click it to pick a job from the database.

### Option 2 — PowerShell directly
```powershell
.\Generate-DeflectionMap.ps1 -JobNumber "00002"
.\Generate-DeflectionMap.ps1   # interactive job picker
```

### Parameters
| Parameter | Default | Description |
|---|---|---|
| `-JobNumber` | *(interactive)* | Alpine job number (e.g. `00001`) |
| `-Server` | `.\SQLEXPRESS` | SQL Server instance |
| `-Database` | `Local` | Alpine database name |
| `-BaseJobsDir` | `C:\ITWBCG\Wood\Jobs` | Root jobs directory |
| `-OpenInBrowser` | `true` | Auto-open the HTML after generation |
| `-OutputPath` | *(job directory)* | Override output file path |

## Requirements
- Windows 10/11
- PowerShell 5.1+
- SQL Server Express with Alpine `Local` database
- ODBC Driver 17 for SQL Server (or Windows ADO.NET — uses `System.Data.SqlClient` via .NET)
- Alpine intelliVIEW jobs with `.ENG` files present

## Output
The HTML file is saved alongside the job files:
```
C:\ITWBCG\Wood\Jobs\<YYYYMMDD>\<JobNumber>\<JobNumber>_DeflectionMap.html
```

## Related Projects
- **[AlpTrack](https://github.com/philatpeace/AlpTrack)** — File-change watcher, visual diff engine, and interaction telemetry for Alpine intelliVIEW.
