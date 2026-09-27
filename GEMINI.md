# AlpDeflect Project Guidelines & Environment Context

## Project Purpose
**AlpDeflect** is an interactive structural deflection mapping tool for ITW Alpine intelliVIEW truss designs. It extracts bottom-chord panel deflection points from proprietary binary `.ENG` engineering files, queries the `Local` SQL database for job metrics, correlates truss geometry, and renders an interactive, self-contained SVG deflection heatmap report in HTML.

---

## Local Database Connection Information

- **Database Engine**: Microsoft SQL Server Express (`MSSQL$SQLEXPRESS`)
- **Server Instance**: `.\SQLEXPRESS` (or `localhost\SQLEXPRESS`)
- **Authentication**: Windows Integrated Authentication (Trusted Connection, no password required)
- **Primary Database**: `Local`

### Key Database Tables (`Local`)
- **`dbo.Job`**: Top-level job metadata (`Job_ID`, `JobNumber`, `Description`, `LastUpdated`, `Directory_ID`). Note: `JobNumber` is `CHAR(120)` — always use `RTRIM(JobNumber)`.
- **`dbo.Directory_ID`**: Maps `Directory_ID` to the job's date-based parent folder. The actual job directory is `Join-Path $Directory $JobNumber`.
- **`dbo.Job_Item`**: Individual components (`Job_Item_ID`, `Job_ID`, `Mark`, `Quantity`, `ItemStatus_ID`).
- **`dbo.Job_Item_WoodTruss`**: Physical dimensions (`Span` in decimal feet, `TCPitch`, `BCPitch`, `OAHeight`, `LumberBDFT`, `Price`).

---

## File System & Alpine Architecture

- **Active Jobs Root**: `C:\ITWBCG\Wood\Jobs\<YYYYMMDD>\<JobNumber>\`
- **Alpine Software Root**: `C:\intelliVIEW\`
- **Key Alpine Files**:
  - `T<n>.PE`: Plain-text cutlist. Line 0 has span dimension string (e.g. `24'8"8`). Line 1 has Mark name.
  - `T<n>.ENG`: Proprietary binary engineering analysis. Contains 88-byte panel point records under `.DEFLECTION 004` (Total Load) or `001` (Live Load). `PB`/`BC` records contain chord station (offset +4), LL deflection (offset +24), and TL deflection (offset +28).

---

## Development Guidelines

- Primary language: **PowerShell 5.1 / 7+**.
- Always use parameterized queries or sanitize database inputs.
- Keep the generated HTML reports completely self-contained.
- Desktop batch launcher is synchronized with `C:\Users\Dad\Desktop\Generate-DeflectionMap.bat`.
