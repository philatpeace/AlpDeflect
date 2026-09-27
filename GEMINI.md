# AlpTrack Project Guidelines & Environment Context

## Project Purpose
AlpTrack is a tracking, auditing, and integration system for structural timber truss designs created in ITW Alpine's intelliVIEW suite (iModel, View, iCommand). It tracks both database records and drawing/graphical changes made during the truss design and approval workflows.

---

## Local Database Connection Information

- **Database Engine**: Microsoft SQL Server Express (`MSSQL$SQLEXPRESS`)
- **Server Instance**: `.\SQLEXPRESS` (or `localhost\SQLEXPRESS`)
- **Authentication**: Windows Integrated Authentication (Trusted Connection, no password required)

### Connection Strings
- **C# / .NET**:
  ```text
  Server=.\SQLEXPRESS;Database=Local;Integrated Security=True;TrustServerCertificate=True;
  ```
- **Python (`pyodbc`)**:
  ```text
  DRIVER={ODBC Driver 17 for SQL Server};SERVER=.\SQLEXPRESS;DATABASE=Local;Trusted_Connection=yes;
  ```

### Primary Databases
1. **`Local`**: Active jobs, job items (trusses, panels), dimensional parameters, lumber, plates, engineering stress indices, and workflows.
2. **`Local_IS`**: Master material properties, lumber grades, plate sizes, cost groups, and pricing catalogs.

### Key Database Tables (`Local`)
- **`dbo.Job`**: Top-level job metadata (`Job_ID`, `JobNumber`, `Description`, `LastUpdated`, `Directory_ID`).
- **`dbo.Directory_ID`**: Maps `Directory_ID` to the job's directory on disk.
- **`dbo.Job_Item`**: Individual components in a job (`Job_Item_ID`, `Job_ID`, `Mark` [e.g. T2, T6, T10], `Quantity`, `ItemStatus_ID`).
- **`dbo.Job_Item_WoodTruss`**: Physical dimensions and engineering data (`Span`, `TCPitch`, `BCPitch`, `OAHeight`, `LumberBDFT`, `Price`).
- **`dbo.TrussLumber`**: Lumber pieces schedule (`2x4`, `2x6`, species, grade, lengths).
- **`dbo.TrussPlate`**: Metal connector plates schedule (`4X8`, `1.5X3`, quantities).
- **`dbo.Job_Item_AnalysisData`**: Moment, shear, and Combined Stress Index (CSI) metrics.

---

## File System & Alpine Architecture

- **Active Jobs Directory**: `C:\ITWBCG\Wood\Jobs\<YYYYMMDD>\<JobNumber>\`
- **Alpine Software Root**: `C:\intelliVIEW\` (`iCommand`, `iModel`, `iTransmit`)
- **Truss File Extensions**:
  - `*.tdimg`, `*.tdimg.1`, `*.tdimg.2`: Alpine Truss Design Graphics / vector drawing format.
  - `*.PE`: Plain-text member cutlist, lumber grades, plate schedule, reactions, and pricing export.
  - `*.ENG`: Structural engineering analysis calculations.
  - `*.dwg`: CAD drawing file.
  - `*.xtd`: Extended truss geometry and node coordinates.

---

## Architecture & Code Guidelines

- Prefer modern C# (.NET 10) with nullable reference types.
- Ensure file read/write operations handle file locks gracefully using retry/backoff (since Alpine writes files in rapid bursts).
- Keep drawing diffs registered to title-block corners to avoid screenshot misalignment.
