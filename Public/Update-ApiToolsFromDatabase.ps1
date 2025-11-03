function Update-ApiToolsFromDatabase {
<#
.SYNOPSIS
Updates an existing CRUD API project when the source database schema changes.

.DESCRIPTION
Update-ApiToolsFromDatabase performs a "smart copy-paste" refresh of EF Core models without
destroying custom configuration. It scaffolds fresh models and the DbContext to a temporary
workspace, then replaces entity model files and re-injects the developer’s existing
OnModelCreating custom block into the newly scaffolded DbContext (after the generated mappings).

Key steps:
1) Validate tools and locate existing DbContext.
2) Extract custom OnModelCreating block from existing context.
3) Scaffold fresh context + models to a temp folder via dotnet ef.
4) Replace entity models and merge DbContext with custom block appended.
5) Generate a human-friendly change report and machine-readable JSON.
6) Optional controller generation for newly added entities only.
7) Optional parity migration creation for DB-first tracking.

.PARAMETER ConnectionString
Database connection string. If omitted, reads from appsettings.json using the key from -ConnectionStringName.

.PARAMETER ProjectPath
Path to the existing API project directory (must contain a .csproj file).

.PARAMETER ModelsPath
Relative path to the Models folder. Defaults to "Models".

.PARAMETER ContextName
Optional DbContext class name. Provide this in multi-context solutions.

.PARAMETER TempRoot
Root directory for the temporary scaffold workspace. Defaults to ".apitools_temp".

.PARAMETER DryRun
Preview changes without applying. Shows added/removed/updated models with property-level diffs.

.PARAMETER BackupBeforeApply
Create a backup under .apitools_backups before modifying the project.

.PARAMETER IncludeTables
Comma-separated list of table names to include.

.PARAMETER ExcludeTables
Comma-separated list of table names to exclude.

.PARAMETER RegenerateControllers
Generate CRUD controllers for brand-new entities only (existing controllers are preserved).

.PARAMETER CreateMigration
Create an EF Core migration after updating models (for parity tracking in DB-first workflows).

.PARAMETER MigrationName
Name for the migration if -CreateMigration is provided. Invalid characters are replaced with underscores.

.PARAMETER AppSettingsPath
Relative path to appsettings.json. Defaults to "appsettings.json".

.PARAMETER ConnectionStringName
Key in ConnectionStrings section of appsettings.json. Defaults to "DefaultConnection".

.EXAMPLE
Update-ApiToolsFromDatabase -ProjectPath "./HospitalAPI"

.EXAMPLE
Update-ApiToolsFromDatabase -ProjectPath "./HospitalAPI" -DryRun

.EXAMPLE
Update-ApiToolsFromDatabase `
  -ProjectPath "./HospitalAPI" `
  -BackupBeforeApply `
  -RegenerateControllers `
  -CreateMigration `
  -MigrationName "AddEmailColumn"

.EXAMPLE
Update-ApiToolsFromDatabase `
  -ProjectPath "./ComplexAPI" `
  -ContextName "CatalogContext" `
  -IncludeTables "Products,Categories"

.INPUTS
None.

.OUTPUTS
PSCustomObject with Action, Engine, Database, Context, ProjectPath, ModelsPath, Added, Removed, Overwritten,
PropertyDiff, ControllersGenerated, MigrationCreated, Timestamp, Created, and DryRun/WhatIf indicators.

.NOTES
Author: Ruslan Dubas
Module: apitools
Requires: .NET SDK, dotnet-ef
Optional: dotnet-aspnet-codegenerator (needed only when -RegenerateControllers is used)

.LINK
https://github.com/yourusername/apitools
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $false, HelpMessage = "Database connection string. If omitted, reads from appsettings.json (DefaultConnection).")]
        [string]$ConnectionString,

        [Parameter(Mandatory = $true)]
        [string]$ProjectPath,

        [string]$ModelsPath = "Models",
        [string]$ContextName,
        [string]$TempRoot = ".apitools_temp",

        [switch]$DryRun,
        [switch]$BackupBeforeApply,

        [string]$IncludeTables,
        [string]$ExcludeTables,

        [switch]$RegenerateControllers,

        [switch]$CreateMigration,
        [string]$MigrationName = $("Update_" + (Get-Date -Format "yyyyMMdd_HHmmss")),

        [string]$AppSettingsPath = "appsettings.json",
        [string]$ConnectionStringName = "DefaultConnection"
    )

    begin {
        function _Info($m){ Write-Host $m -ForegroundColor White }
        function _Note($m){ Write-Host $m -ForegroundColor Cyan }
        function _Ok($m)  { Write-Host $m -ForegroundColor Green }
        function _Warn($m){ Write-Warning $m }
        function _Fail($m){ throw $m }

        function _EnsureDotnetTools {
            $errs=@()
            try { $null = dotnet --version 2>$null } catch { $errs += ".NET SDK not found." }
            try { $null = dotnet ef --version 2>$null } catch { $errs += "dotnet-ef tool not found. Install: dotnet tool install --global dotnet-ef" }
            if ($errs.Count -gt 0) { _Fail ("Missing tools:`n" + ($errs -join "`n")) }
        }

        function _EnsureCodegenTool {
            try { $null = dotnet aspnet-codegenerator --help 2>$null }
            catch { _Fail "dotnet-aspnet-codegenerator tool not found. Install: dotnet tool install --global dotnet-aspnet-codegenerator" }
        }

        function _NewStamp { Get-Date -Format "yyyyMMdd_HHmmss" }

        function _ResolvePath([string]$p) {
            if ([string]::IsNullOrWhiteSpace($p)) { return $null }
            if (Test-Path $p) { return (Resolve-Path $p).Path }
            return (Join-Path (Get-Location) $p)
        }

        function _EnsureDir([string]$path) {
            if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
        }

        function _SplitCsv([string]$csv) {
            if ([string]::IsNullOrWhiteSpace($csv)) { @() } else { $csv.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
        }

        function _ReadAll([string]$file) { if (Test-Path $file) { Get-Content $file -Raw } else { $null } }

        function _GetProjectName([string]$projectDir){
            $csproj = Get-ChildItem -Path $projectDir -Filter "*.csproj" -File | Select-Object -First 1
            if (-not $csproj) { _Fail "Could not find .csproj file in '$projectDir'." }
            return [System.IO.Path]::GetFileNameWithoutExtension($csproj.Name)
        }

        function _FindContextFile([string]$modelsDir, [string]$explicitName) {
    if (-not (Test-Path $modelsDir)) { return $null }
    if ($explicitName) {
        $p = Join-Path $modelsDir ("{0}.cs" -f $explicitName)
        if (Test-Path $p) { return $p }
    }
    $hit = Get-ChildItem -Path $modelsDir -Filter "*.cs" -File |
           Where-Object { (_ReadAll $_.FullName) -match '\b(class|partial\s+class)\s+\w+\s*:\s*DbContext\b' } |
           Select-Object -First 1
    return $hit?.FullName
}

        function _ExtractOnModelCreating([string]$content) {
            $sig = [regex]::Match($content, 'protected\s+override\s+void\s+OnModelCreating\s*\(\s*ModelBuilder\s+\w+\s*\)', 'Singleline')
            if (-not $sig.Success) { return $null }
            $startIdx = $sig.Index
            $openIdx  = $content.IndexOf('{', $startIdx)
            if ($openIdx -lt 0) { return $null }
            $depth = 0
            for ($i=$openIdx; $i -lt $content.Length; $i++){
                $ch = $content[$i]
                if ($ch -eq '{'){ $depth++ }
                elseif ($ch -eq '}'){
                    $depth--
                    if ($depth -eq 0){
                        $bodyStart = $openIdx + 1
                        $bodyLen   = $i - $bodyStart
                        return @{ Body = $content.Substring($bodyStart, $bodyLen); Start = $bodyStart; End = $i }
                    }
                }
            }
            return $null
        }

        function _InsertCustomAfterGenerated([string]$newCtxContent, [string]$customBlock) {
            if ([string]::IsNullOrWhiteSpace($customBlock)) { return $newCtxContent }
            $markerStart = "// <APITOOLS_CUSTOM_ONMODEL_START>"
            $markerEnd   = "// <APITOOLS_CUSTOM_ONMODEL_END>"

            $s = $newCtxContent.IndexOf($markerStart)
            if ($s -ge 0) {
                $e = $newCtxContent.IndexOf($markerEnd, $s)
                if ($e -gt $s) { $newCtxContent = $newCtxContent.Remove($s, ($e + $markerEnd.Length) - $s) }
            }

            $parsed = _ExtractOnModelCreating $newCtxContent
            if ($null -eq $parsed) { return $null }

            $insertion =
                "`r`n        $markerStart`r`n" +
                "        // User custom configuration preserved by apitools`r`n" +
                ($customBlock.TrimEnd()) + "`r`n" +
                "        $markerEnd`r`n"

            $updatedBody = ($parsed.Body.TrimEnd()) + "`r`n" + $insertion
            return $newCtxContent.Substring(0, $parsed.Start) + $updatedBody + $newCtxContent.Substring($parsed.End)
        }

        function _EngineFromConnection([string]$cs) {
            $r = [ordered]@{}
            if ($cs -match '(?i)(npgsql|postgres|port\s*=\s*5432)') {
                $r.Engine           = 'PostgreSQL'
                $r.ProviderPackage  = 'Npgsql.EntityFrameworkCore.PostgreSQL'
                $r.ScaffoldProvider = 'Npgsql.EntityFrameworkCore.PostgreSQL'
                $r.DbCtxMethod      = 'UseNpgsql'
            }
            elseif ($cs -match '(?i)(server\s*=|data source\s*=|trusted_connection|sqlserver)') {
                $r.Engine           = 'SqlServer'
                $r.ProviderPackage  = 'Microsoft.EntityFrameworkCore.SqlServer'
                $r.ScaffoldProvider = 'Microsoft.EntityFrameworkCore.SqlServer'
                $r.DbCtxMethod      = 'UseSqlServer'
            }
            else { _Fail "Unable to detect database engine from the provided connection string." }

            $db = $null
            foreach ($part in ($cs -split ';')) {
                if ($part -match '(?i)^(Database|Initial Catalog)\s*=\s*(.+)$') { $db = $Matches[2].Trim(); break }
            }
            $r.DatabaseName = $db
            return $r
        }

        function _ReadConnectionFromAppSettings([string]$projectRoot, [string]$appSettingsRel, [string]$name){
            $p = Join-Path $projectRoot $appSettingsRel
            if (-not (Test-Path $p)) { return $null }
            try {
                $json = Get-Content $p -Raw | ConvertFrom-Json -Depth 64
                return $json.ConnectionStrings.$name
            } catch { return $null }
        }

        function _PropertySig($line){
            $m = [regex]::Match($line, 'public\s+([\w<>\?\[\]]+)\s+(\w+)\s*\{\s*get;\s*set;\s*\}')
            if ($m.Success) { return @{ Type=$m.Groups[1].Value; Name=$m.Groups[2].Value } }
            return $null
        }

        function _ModelDiffReport([string]$oldFile,[string]$newFile){
            $old = if ($oldFile -and (Test-Path $oldFile)) { Get-Content $oldFile } else { @() }
            $new = if ($newFile -and (Test-Path $newFile)) { Get-Content $newFile } else { @() }

            $oldProps = @{}
            foreach($l in $old){ $sig=_PropertySig $l; if($sig){ $oldProps[$sig.Name]=$sig.Type } }
            $newProps = @{}
            foreach($l in $new){ $sig=_PropertySig $l; if($sig){ $newProps[$sig.Name]=$sig.Type } }

            $added   = @()
            $removed = @()
            $changed = @()

            foreach($k in $newProps.Keys){
                if(-not $oldProps.ContainsKey($k)){ $added += @{ Name=$k; Type=$newProps[$k] } }
                elseif($oldProps[$k] -ne $newProps[$k]){ $changed += @{ Name=$k; From=$oldProps[$k]; To=$newProps[$k] } }
            }
            foreach($k in $oldProps.Keys){
                if(-not $newProps.containsKey($k)){ $removed += @{ Name=$k; Type=$oldProps[$k] } }
            }

            return [pscustomobject]@{
                Added   = $added
                Removed = $removed
                Changed = $changed
            }
        }

        function _FindControllersPath([string]$proj){
            $p = Join-Path $proj "Controllers"
            if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
            return $p
        }

        function _EnsureSqlServerPkgForPgWhenCodegen([string]$projectDir, [string]$engineName){
            if ($engineName -ne 'PostgreSQL') { return }
            _Note "Verifying Microsoft.EntityFrameworkCore.SqlServer (required by aspnet-codegenerator even for PostgreSQL)..."
            Push-Location $projectDir
            try {
                $packagesList = dotnet list package 2>&1
                $hasSqlServer = ($packagesList -match 'Microsoft\.EntityFrameworkCore\.SqlServer')
                if (-not $hasSqlServer) {
                    _Warn "Installing Microsoft.EntityFrameworkCore.SqlServer (codegen dependency)..."
                    $null = dotnet add package Microsoft.EntityFrameworkCore.SqlServer 2>&1
                }
            } finally { Pop-Location }
        }
    }

    process {
        _EnsureDotnetTools

        $ProjectPath = (_ResolvePath $ProjectPath)
        if (-not (Test-Path $ProjectPath)) { _Fail "ProjectPath not found: $ProjectPath" }

        if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
            $ConnectionString = _ReadConnectionFromAppSettings -projectRoot $ProjectPath -appSettingsRel $AppSettingsPath -name $ConnectionStringName
            if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
                _Fail "ConnectionString not provided and could not be read from '$AppSettingsPath' (key '$ConnectionStringName')."
            }
        }

        $engine = _EngineFromConnection $ConnectionString
        Write-Verbose ("Detected engine: {0}" -f $engine.Engine)

        $modelsDir = Join-Path $ProjectPath $ModelsPath
        $ctxPathExisting = _FindContextFile -modelsDir $modelsDir -explicitName $ContextName
        if (-not $ctxPathExisting) {
            $msg = "Could not locate existing DbContext in '$modelsDir'."
            if ($ContextName) {
                $msg += " The specified context name '$ContextName' was not found."
            } else {
                $msg += " Provide -ContextName if multiple contexts exist, or ensure project was scaffolded with New-ApiToolsCrudApi."
            }
            _Fail $msg
        }

        $existingCtxContent = _ReadAll $ctxPathExisting
        $existingCtxParsed  = _ExtractOnModelCreating $existingCtxContent
        if ($null -eq $existingCtxParsed) { _Fail "Could not parse OnModelCreating in existing DbContext. Aborting to avoid data loss." }

        $ctxClassName = if ($ContextName) { $ContextName } else {
            $m = [regex]::Match($existingCtxContent, '\bclass\s+(\w+)\s*:\s*DbContext')
            if ($m.Success) { $m.Groups[1].Value } else { "$($engine.DatabaseName)Context" }
        }

        Write-Verbose ("Context class: {0}" -f $ctxClassName)
        $userCustomBlock = $existingCtxParsed.Body
        Write-Verbose ("Custom OnModelCreating block length: {0} chars" -f $userCustomBlock.Length)

        $projName = _GetProjectName $ProjectPath

        $stamp     = _NewStamp
$tempBase  = Join-Path $ProjectPath $TempRoot
$tempRun   = Join-Path $tempBase "scaffold_$stamp"
$tempModelsRelative = Join-Path $TempRoot "scaffold_$stamp"
$tempModels= Join-Path $ProjectPath $tempModelsRelative
_EnsureDir $tempModels

        Push-Location $ProjectPath
try {
    _Note "Scaffolding to temporary workspace: $tempRun"

    # Create a temporary output path for models
    $tempOutputPath = Join-Path $TempRoot "scaffold_$stamp\$ModelsPath"
    
   $args = @(
    'ef','dbcontext','scaffold',
    $ConnectionString,
    $engine.ScaffoldProvider,
    '--output-dir', $tempModelsRelative,
    '--context', $ctxClassName,
    '--namespace', "$projName.Models",
    '--force'
)
    if ($IncludeTables) { _SplitCsv $IncludeTables | ForEach-Object { $args += @('--table', $_) } }
    if ($ExcludeTables) { _SplitCsv $ExcludeTables | ForEach-Object { $args += @('--exclude-tables', $_) } }

    # Run scaffold from project directory (where .csproj is)
    $output = dotnet @args 2>&1
if ($LASTEXITCODE -ne 0) { 
    _Fail "dotnet ef scaffold failed. Output: $($output | Out-String)" 
}

    # Verify files were created
    if (-not (Test-Path $tempModels) -or (Get-ChildItem $tempModels -Filter "*.cs" -File).Count -eq 0) {
        _Fail "Scaffold completed but produced no model files. Check connection string and table filters."
    }

            $existingModelFiles = if (Test-Path $modelsDir) { Get-ChildItem -Path $modelsDir -Filter "*.cs" -File } else { @() }
            $newModelFiles      = Get-ChildItem -Path $tempModels -Filter "*.cs" -File

            $existingNames = $existingModelFiles | ForEach-Object { $_.Name }
            $newNames      = $newModelFiles      | ForEach-Object { $_.Name }

            $added   = $newNames | Where-Object { $_ -notin $existingNames -and $_ -ne "$ctxClassName.cs" }
            $removed = $existingNames | Where-Object { $_ -notin $newNames -and $_ -ne "$ctxClassName.cs" }
            $common  = $newNames | Where-Object { $_ -in $existingNames -and $_ -ne "$ctxClassName.cs" }

            $perEntityDiff = @{}
            foreach($n in $common){
                $perEntityDiff[$n] = _ModelDiffReport -oldFile (Join-Path $modelsDir $n) -newFile (Join-Path $tempModels $n)
            }
            foreach($n in $added){
                $perEntityDiff[$n] = _ModelDiffReport -oldFile $null -newFile (Join-Path $tempModels $n)
            }

            if ($DryRun) {
                _Info ""
                _Info "=== DRY RUN: Update-ApiToolsFromDatabase ==="
                _Info ("Engine: {0}" -f $engine.Engine)
                _Info ("Context: {0}" -f $ctxClassName)
                _Info ("Project: {0}" -f $ProjectPath)
                _Info ""

                _Note "SUMMARY:"
                Write-Host ("  Models to ADD:       {0}" -f $added.Count)   -ForegroundColor Green
                Write-Host ("  Models to REMOVE:    {0}" -f $removed.Count) -ForegroundColor Red
                Write-Host ("  Models to UPDATE:    {0}" -f $common.Count)  -ForegroundColor Yellow
                _Info ""

                if ($added.Count -gt 0) {
                    _Note "NEW MODELS:"
                    foreach($n in $added) { Write-Host ("  + {0}" -f $n) -ForegroundColor Green }
                    _Info ""
                }
                if ($removed.Count -gt 0) {
                    _Warn "REMOVED MODELS:"
                    foreach($n in $removed) { Write-Host ("  - {0}" -f $n) -ForegroundColor Red }
                    _Info ""
                    _Warn "Consider manually removing corresponding controllers if they exist."
                    _Info ""
                }
                if ($common.Count -gt 0) {
                    _Note "UPDATED MODELS (Property Changes):"
                    foreach($k in $perEntityDiff.Keys) {
                        $d = $perEntityDiff[$k]
                        $hasChanges = ($d.Added.Count -gt 0 -or $d.Removed.Count -gt 0 -or $d.Changed.Count -gt 0)
                        if ($hasChanges) {
                            Write-Host ("  {0}:" -f $k) -ForegroundColor Yellow
                            foreach($p in $d.Added)   { Write-Host ("    + {0} : {1}" -f $p.Name, $p.Type) -ForegroundColor Green }
                            foreach($p in $d.Removed) { Write-Host ("    - {0} : {1}" -f $p.Name, $p.Type) -ForegroundColor Red }
                            foreach($p in $d.Changed) { Write-Host ("    ~ {0} : {1} -> {2}" -f $p.Name, $p.From, $p.To) -ForegroundColor Cyan }
                        }
                    }
                }

                return [pscustomobject]@{
                    Action        = 'PreviewUpdateFromDatabase'
                    Engine        = $engine.Engine
                    Database      = $engine.DatabaseName
                    Context       = $ctxClassName
                    ProjectPath   = $ProjectPath
                    ModelsPath    = $ModelsPath
                    AddedModels   = $added
                    RemovedModels = $removed
                    Overwritten   = $common
                    Diff          = $perEntityDiff
                    DryRun        = $true
                }
            }

            if ($PSCmdlet.ShouldProcess("$($engine.Engine)::$($engine.DatabaseName)", "Apply Smart Update")) {

                if ($BackupBeforeApply) {
                    $backupDir = Join-Path $ProjectPath ".apitools_backups"
                    _EnsureDir $backupDir
                    $backupStamp = Join-Path $backupDir ("backup_{0}" -f $stamp)
                    _Note "Creating backup: $backupStamp"
                    _EnsureDir $backupStamp
                    Copy-Item -Path (Join-Path $ProjectPath '*') -Destination $backupStamp -Recurse -Force -Exclude $TempRoot,'.git','.vs','bin','obj'
                }

                $reportsDir = Join-Path $ProjectPath ".apitools_reports"
                _EnsureDir $reportsDir
                $reportTxt  = Join-Path $reportsDir ("update_{0}.txt" -f $stamp)
                $reportJson = Join-Path $reportsDir ("update_{0}.json" -f $stamp)

                _Note "Refreshing entity models..."
                _EnsureDir $modelsDir
                Copy-Item -Path (Join-Path $tempModels '*') -Destination $modelsDir -Recurse -Force

                $tempCtxPath = Join-Path $tempModels "$ctxClassName.cs"
                $projCtxPath = Join-Path $modelsDir  "$ctxClassName.cs"
                if (-not (Test-Path $tempCtxPath)) { _Fail "Scaffold did not produce expected context '$ctxClassName.cs'." }

                $newBaselineCtx = _ReadAll $tempCtxPath
                $mergedCtx      = _InsertCustomAfterGenerated -newCtxContent $newBaselineCtx -customBlock $userCustomBlock
                if ($null -eq $mergedCtx) { _Fail "Could not merge OnModelCreating in new context. Aborting to avoid data loss." }
                Set-Content -Path $projCtxPath -Value $mergedCtx -Encoding UTF8

                $controllersGenerated = 0
                if ($RegenerateControllers.IsPresent) {
                    _EnsureCodegenTool
                    _EnsureSqlServerPkgForPgWhenCodegen -projectDir $ProjectPath -engineName $engine.Engine

                    $controllersPath = _FindControllersPath $ProjectPath
                    Push-Location $ProjectPath
                    try {
                        $null = dotnet build 2>&1
                        foreach($entityName in $added){
                            $modelName = [System.IO.Path]::GetFileNameWithoutExtension($entityName)
                            $controllerFile = Join-Path $controllersPath ("{0}Controller.cs" -f $modelName)
                            if (Test-Path $controllerFile) { continue }

                            $modelFqn = "$projName.Models.$modelName"
                            $ctxFqn   = "$projName.Models.$ctxClassName"

                            $out = dotnet aspnet-codegenerator controller `
                                -name ("{0}Controller" -f $modelName) `
                                -async -api `
                                -m $modelFqn `
                                -dc $ctxFqn `
                                -outDir $controllersPath `
                                -f 2>&1

                            if ($LASTEXITCODE -eq 0 -and (Test-Path $controllerFile)) { $controllersGenerated++ }
                        }
                    } finally { Pop-Location }
                }

                $migrationCreated = $false
                if ($CreateMigration.IsPresent) {
                    if ([string]::IsNullOrWhiteSpace($MigrationName)) { $MigrationName = "Update_" + (_NewStamp) }
                    $MigrationName = ($MigrationName -replace '[^\w]', '_')
                    Push-Location $ProjectPath
                    try {
                        $out = dotnet ef migrations add $MigrationName 2>&1
                        if ($LASTEXITCODE -eq 0) { $migrationCreated = $true }
                    } finally { Pop-Location }
                }

                $summary = [pscustomobject]@{
                    Action               = 'UpdateFromDatabase'
                    Engine               = $engine.Engine
                    Database             = $engine.DatabaseName
                    Context              = $ctxClassName
                    ProjectPath          = $ProjectPath
                    ModelsPath           = $ModelsPath
                    Added                = $added
                    Removed              = $removed
                    Overwritten          = $common
                    PropertyDiff         = $perEntityDiff
                    ControllersGenerated = $controllersGenerated
                    MigrationCreated     = $migrationCreated
                    Timestamp            = $stamp
                    Created              = $true
                }

                $txt = @()
                $txt += "Update-ApiToolsFromDatabase @ $stamp"
                $txt += "Engine: $($engine.Engine)"
                $txt += "Database: $($engine.DatabaseName)"
                $txt += "Context: $ctxClassName"
                $txt += "Models added:        $($added.Count)"
                $txt += "Models removed:      $($removed.Count)"
                $txt += "Models overwritten:  $($common.Count)"
                if ($controllersGenerated -gt 0) { $txt += "Controllers created:  $controllersGenerated (new entities)" }
                if ($migrationCreated)           { $txt += "Migration created:    $MigrationName" }
                $txt += "Custom OnModelCreating preserved and re-injected after generated mappings."
                Set-Content -Path $reportTxt -Value ($txt -join "`r`n") -Encoding UTF8
                $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $reportJson -Encoding UTF8

                _Ok  "✓ Models updated and DbContext merged successfully."
                _Info ""
                _Info "CHANGES APPLIED:"
                Write-Host ("  Models added:        {0}" -f $added.Count)   -ForegroundColor Green
                Write-Host ("  Models removed:      {0}" -f $removed.Count) -ForegroundColor Red
                Write-Host ("  Models overwritten:  {0}" -f $common.Count)  -ForegroundColor Yellow

                if ($common.Count -gt 0 -or $added.Count -gt 0) {
                    $totalPropsAdded   = ($perEntityDiff.Values | ForEach-Object { $_.Added.Count }   | Measure-Object -Sum).Sum
                    $totalPropsRemoved = ($perEntityDiff.Values | ForEach-Object { $_.Removed.Count } | Measure-Object -Sum).Sum
                    $totalPropsChanged = ($perEntityDiff.Values | ForEach-Object { $_.Changed.Count } | Measure-Object -Sum).Sum
                    if ($totalPropsAdded -or $totalPropsRemoved -or $totalPropsChanged) {
                        Write-Host ("    Properties: +{0} / -{1} / ~{2}" -f $totalPropsAdded, $totalPropsRemoved, $totalPropsChanged) -ForegroundColor Gray
                    }
                }

                if ($removed.Count -gt 0) {
                    _Info ""
                    _Warn "⚠ Models removed from database:"
                    foreach($n in $removed) { Write-Host ("  - {0}" -f $n) -ForegroundColor Red }
                    _Info ""
                    _Warn "Consider manually removing corresponding controllers if they exist."
                }

                if ($controllersGenerated -gt 0) {
                    Write-Host ("  Controllers created: {0}" -f $controllersGenerated) -ForegroundColor Green
                }
                if ($migrationCreated) {
                    Write-Host ("  Migration created:   {0}" -f $MigrationName) -ForegroundColor Green
                }

                _Info ""
                _Info "Reports saved:"
                _Info ("  Text: {0}" -f $reportTxt)
                _Info ("  JSON: {0}" -f $reportJson)
                if ($BackupBeforeApply) {
                    _Info ("  Backup: {0}" -f $backupStamp)
                }

                return $summary
            }
            else {
                return [pscustomobject]@{
                    Action      = 'UpdateFromDatabaseCancelled'
                    Engine      = $engine.Engine
                    Database    = $engine.DatabaseName
                    Context     = $ctxClassName
                    ProjectPath = $ProjectPath
                    WhatIf      = $true
                }
            }
        }
        finally {
            Pop-Location
            # Leave temp workspace for audit. Uncomment to auto-clean:
            # if (-not $DryRun) { Remove-Item -Path $tempRun -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
