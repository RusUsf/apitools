function Update-ApiToolsFromDatabase {
<#
.SYNOPSIS
Safe, markerless update of EF models + DbContext. Preserves only non-entity custom code.

.DESCRIPTION
1) Scaffolds fresh models/DbContext into a temp workspace.
2) Copies entity models over the project.
3) Rebuilds OnModelCreating by taking the NEW scaffolded method body and inserting ONLY
   the user’s NON-ENTITY custom statements (from the OLD context) just before the partial call.
   - Removes any old EF entity blocks from the carry-over with brace-aware parsing.
   - Removes any old APITOOLS markers from the carry-over.
   - Removes OnModelCreatingPartial(modelBuilder) from the carry-over (let new scaffold place it).
4) Optional controller generation for newly added entities; optional migration.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [string]$ConnectionString,
        [Parameter(Mandatory=$true)][string]$ProjectPath,
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
        function _NewStamp { Get-Date -Format "yyyyMMdd_HHmmss" }

        function _EnsureDir([string]$path) { if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null } }
        function _ResolvePath([string]$p)  { if (Test-Path $p) { (Resolve-Path $p).Path } else { Join-Path (Get-Location) $p } }
        function _ReadAll([string]$f)     { if (Test-Path $f) { Get-Content $f -Raw } else { $null } }
        function _SplitCsv([string]$csv)  { if ([string]::IsNullOrWhiteSpace($csv)) { @() } else { $csv.Split(',') | % { $_.Trim() } | ? { $_ } } }

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

        function _GetProjectName([string]$projectDir){
            $csproj = Get-ChildItem -Path $projectDir -Filter "*.csproj" -File | Select-Object -First 1
            if (-not $csproj) { _Fail "Could not find .csproj in '$projectDir'." }
            [IO.Path]::GetFileNameWithoutExtension($csproj.Name)
        }

        function _FindContextFile([string]$modelsDir, [string]$explicitName) {
            if (-not (Test-Path $modelsDir)) { return $null }
            if ($explicitName) {
                $p = Join-Path $modelsDir ("{0}.cs" -f $explicitName)
                if (Test-Path $p) { return $p }
            }
            $hit = Get-ChildItem -Path $modelsDir -Filter "*.cs" -File |
                   Where-Object { (_ReadAll $_.FullName) -match '\bclass\s+\w+\s*:\s*DbContext\b' } |
                   Select-Object -First 1
            $hit?.FullName
        }

        function _EngineFromConnection([string]$cs) {
            $r = [ordered]@{}
            if ($cs -match '(?i)(npgsql|postgres|port\s*=\s*5432)') {
                $r.Engine='PostgreSQL'; $r.ScaffoldProvider='Npgsql.EntityFrameworkCore.PostgreSQL'
            } elseif ($cs -match '(?i)(server\s*=|data source\s*=|trusted_connection|sqlserver)') {
                $r.Engine='SqlServer';  $r.ScaffoldProvider='Microsoft.EntityFrameworkCore.SqlServer'
            } else { _Fail "Unable to detect database engine from connection string." }
            $r.DatabaseName = ($cs -split ';' | % { $_.Trim() } | ? { $_ -match '^(?i)(Database|Initial Catalog)\s*=' } | Select-Object -First 1) -replace '^(?i).+=\s*',''
            $r
        }

        function _ReadConnectionFromAppSettings([string]$projectRoot, [string]$appSettingsRel, [string]$name){
            $p = Join-Path $projectRoot $appSettingsRel
            if (-not (Test-Path $p)) { return $null }
            try { (Get-Content $p -Raw | ConvertFrom-Json -Depth 64).ConnectionStrings.$name } catch { $null }
        }

        function _ExtractOnModelCreating([string]$content) {
            $sig = [regex]::Match($content, 'protected\s+override\s+void\s+OnModelCreating\s*\(\s*ModelBuilder\s+\w+\s*\)', 'Singleline')
            if (-not $sig.Success) { return $null }
            $openIdx  = $content.IndexOf('{', $sig.Index)
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
            $null
        }

        function _RemovePartialCall([string]$body){
            [regex]::Replace($body, '\bOnModelCreatingPartial\s*\(\s*modelBuilder\s*\)\s*;\s*', '', 'Singleline').Trim()
        }

        # Remove any region between APITOOLS markers from the carry-over to avoid nesting old runs.
        function _StripOldMarkers([string]$body) {
            $b = $body
            $b = [regex]::Replace($b, '\/\/\s*<APITOOLS_CUSTOM_ONMODEL_START>.*?\/\/\s*<APITOOLS_CUSTOM_ONMODEL_END>\s*', '', 'Singleline')
            $b = [regex]::Replace($b, '\/\/\s*APITOOLS[^\r\n]*', '', 'Singleline')
            $b.Trim()
        }

        # Brace-aware stripper for EF entity blocks: modelBuilder.Entity<...>(entity => { ... });
        function _StripEntityBlocks([string]$body) {
            if ([string]::IsNullOrWhiteSpace($body)) { return "" }

            $text = $body
            $cursor = 0
            $sb = New-Object System.Text.StringBuilder

            while ($cursor -lt $text.Length) {
                $idx = [cultureinfo]::InvariantCulture.CompareInfo.IndexOf($text, 'modelBuilder.Entity<', $cursor, [System.Globalization.CompareOptions]::IgnoreCase)
                if ($idx -lt 0) {
                    [void]$sb.Append($text.Substring($cursor))
                    break
                }

                # Append everything before the entity block
                [void]$sb.Append($text.Substring($cursor, $idx - $cursor))

                # Find the opening brace of the lambda body "{"
                $parenDepth = 0
                $i = $idx
                $openBrace = -1
                while ($i -lt $text.Length) {
                    $ch = $text[$i]
                    if ($ch -eq '(') { $parenDepth++ }
                    elseif ($ch -eq ')') { $parenDepth-- }
                    elseif ($ch -eq '{') { $openBrace = $i; break }
                    $i++
                }
                if ($openBrace -lt 0) {
                    # malformed; bail out and append remainder
                    [void]$sb.Append($text.Substring($idx))
                    $cursor = $text.Length
                    break
                }

                # Walk braces to the matching "}" and trailing ");"
                $braceDepth = 0
                $j = $openBrace
                while ($j -lt $text.Length) {
                    $ch = $text[$j]
                    if ($ch -eq '{') { $braceDepth++ }
                    elseif ($ch -eq '}') {
                        $braceDepth--
                        if ($braceDepth -eq 0) {
                            # move past closing brace and any whitespace/comments to the following semicolon
                            $j++
                            while ($j -lt $text.Length -and [char]::IsWhiteSpace($text[$j])) { $j++ }
                            if ($j -lt $text.Length -and $text[$j] -eq ')') {
                                # close the .Entity(... ) ; sequence
                                $j++
                                while ($j -lt $text.Length -and [char]::IsWhiteSpace($text[$j])) { $j++ }
                                if ($j -lt $text.Length -and $text[$j] -eq ';') { $j++ }
                            }
                            break
                        }
                    }
                    $j++
                }

                # Skip the whole entity block
                $cursor = $j
            }

            $out = $sb.ToString()
            # Normalize leftover excessive blank lines
            $out = [regex]::Replace($out, "(`r?`n){3,}", "`r`n`r`n")
            $out.Trim()
        }

        # Extract ONLY safe custom statements from old context: strip markers, partial call, and EF entity blocks.
        function _ExtractCarryOver([string]$existingCtxContent) {
            $parsed = _ExtractOnModelCreating $existingCtxContent
            if ($null -eq $parsed) { return "" }
            $body = $parsed.Body
            $body = _StripOldMarkers $body
            $body = _RemovePartialCall $body
            $body = _StripEntityBlocks $body
            $body.Trim()
        }

        # Insert carry-over before the partial call in the NEW context (or append if missing)
        function _InsertCarryOver([string]$newCtxContent, [string]$carryOver) {
            if ([string]::IsNullOrWhiteSpace($carryOver)) { return $newCtxContent }
            $parsedNew = _ExtractOnModelCreating $newCtxContent
            if ($null -eq $parsedNew) { return $null }

            $bodyNew = $parsedNew.Body
            $partial = [regex]::Match($bodyNew, '\bOnModelCreatingPartial\s*\(\s*modelBuilder\s*\)\s*;', 'Singleline')

            $insertion =
                "`r`n        // --- apitools: carried-over custom configuration (non-entity) ---`r`n" +
                ($carryOver.TrimEnd()) + "`r`n" +
                "        // --- end carried-over custom configuration ---`r`n"

            $updatedBody = if ($partial.Success) {
                $bodyNew.Substring(0, $partial.Index) + $insertion + $bodyNew.Substring($partial.Index)
            } else {
                ($bodyNew.TrimEnd()) + "`r`n" + $insertion
            }

            $newCtxContent.Substring(0, $parsedNew.Start) + $updatedBody + $newCtxContent.Substring($parsedNew.End)
        }

        function _PropertySig($line){
            $m = [regex]::Match($line, 'public\s+([\w<>\?\[\]]+)\s+(\w+)\s*\{\s*get;\s*set;\s*\}')
            if ($m.Success) { @{ Type=$m.Groups[1].Value; Name=$m.Groups[2].Value } } else { $null }
        }
        function _ModelDiffReport([string]$oldFile,[string]$newFile){
            $old = if ($oldFile -and (Test-Path $oldFile)) { Get-Content $oldFile } else { @() }
            $new = if ($newFile -and (Test-Path $newFile)) { Get-Content $newFile } else { @() }
            $oldProps=@{}; foreach($l in $old){ $sig=_PropertySig $l; if($sig){ $oldProps[$sig.Name]=$sig.Type } }
            $newProps=@{}; foreach($l in $new){ $sig=_PropertySig $l; if($sig){ $newProps[$sig.Name]=$sig.Type } }
            $added=@(); $removed=@(); $changed=@()
            foreach($k in $newProps.Keys){
                if(-not $oldProps.ContainsKey($k)){ $added += @{ Name=$k; Type=$newProps[$k] } }
                elseif($oldProps[$k] -ne $newProps[$k]){ $changed += @{ Name=$k; From=$oldProps[$k]; To=$newProps[$k] } }
            }
            foreach($k in $oldProps.Keys){ if(-not $newProps.ContainsKey($k)){ $removed += @{ Name=$k; Type=$oldProps[$k] } }
            }
            [pscustomobject]@{ Added=$added; Removed=$removed; Changed=$changed }
        }

        function _FindControllersPath([string]$proj){
            $p = Join-Path $proj "Controllers"; _EnsureDir $p; $p
        }
        function _EnsureSqlServerPkgForPgWhenCodegen([string]$projectDir, [string]$engineName){
            if ($engineName -ne 'PostgreSQL') { return }
            _Note "Ensuring Microsoft.EntityFrameworkCore.SqlServer for aspnet-codegenerator..."
            Push-Location $projectDir
            try {
                $packagesList = dotnet list package 2>&1
                if (-not ($packagesList -match 'Microsoft\.EntityFrameworkCore\.SqlServer')) {
                    $null = dotnet add package Microsoft.EntityFrameworkCore.SqlServer 2>&1
                }
            } finally { Pop-Location }
        }
    }

    process {
        _EnsureDotnetTools

        $ProjectPath = _ResolvePath $ProjectPath
        if (-not (Test-Path $ProjectPath)) { _Fail "ProjectPath not found: $ProjectPath" }

        if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
            $ConnectionString = _ReadConnectionFromAppSettings -projectRoot $ProjectPath -appSettingsRel $AppSettingsPath -name $ConnectionStringName
            if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
                _Fail "ConnectionString not provided and not found in '$AppSettingsPath' (key '$ConnectionStringName')."
            }
        }

        $engine = _EngineFromConnection $ConnectionString
        $modelsDir = Join-Path $ProjectPath $ModelsPath
        $ctxPathExisting = _FindContextFile -modelsDir $modelsDir -explicitName $ContextName
        if (-not $ctxPathExisting) { _Fail "Could not locate existing DbContext in '$modelsDir'." }

        $existingCtxContent = _ReadAll $ctxPathExisting
        $existingParsed     = _ExtractOnModelCreating $existingCtxContent
        if ($null -eq $existingParsed) { _Fail "Could not parse OnModelCreating in existing DbContext." }

        $ctxClassName = if ($ContextName) { $ContextName } else {
            $m = [regex]::Match($existingCtxContent, '\bclass\s+(\w+)\s*:\s*DbContext'); if ($m.Success) { $m.Groups[1].Value } else { "ApplicationDbContext" }
        }

        # Carry over only SAFE custom statements.
        $carryOver = _ExtractCarryOver $existingCtxContent

        $projName = _GetProjectName $ProjectPath

        # Prepare temp scaffold workspace (relative paths for dotnet ef)
        $stamp          = _NewStamp
        $tempRunRel     = Join-Path $TempRoot ("scaffold_{0}" -f $stamp)
        $tempRunAbs     = Join-Path $ProjectPath $tempRunRel
        $tempModelsRel  = Join-Path $tempRunRel $ModelsPath
        $tempModelsAbs  = Join-Path $ProjectPath $tempModelsRel
        _EnsureDir $tempRunAbs
        _EnsureDir $tempModelsAbs

        Push-Location $ProjectPath
        try {
            _Note "Scaffolding fresh models/context to: $tempRunRel"
            $args = @(
                'ef','dbcontext','scaffold',
                $ConnectionString,
                $engine.ScaffoldProvider,
                '--output-dir', $tempModelsRel,
                '--context', $ctxClassName,
                '--namespace', "$projName.Models",
                '--force'
            )
            if ($IncludeTables) { _SplitCsv $IncludeTables | % { $args += @('--table', $_) } }
            if ($ExcludeTables) { _SplitCsv $ExcludeTables | % { $args += @('--exclude-tables', $_) } }

            $output = dotnet @args 2>&1
            if ($LASTEXITCODE -ne 0) { _Fail "dotnet ef scaffold failed.`n$($output | Out-String)" }

            if (-not (Test-Path $tempModelsAbs) -or (Get-ChildItem $tempModelsAbs -Filter "*.cs" -File).Count -eq 0) {
                _Fail "Scaffold produced no model files. Check connection and table filters."
            }

            # Diff
            $existingModelFiles = if (Test-Path $modelsDir) { Get-ChildItem -Path $modelsDir -Filter "*.cs" -File } else { @() }
            $newModelFiles      = Get-ChildItem -Path $tempModelsAbs -Filter "*.cs" -File
            $existingNames = $existingModelFiles | % { $_.Name }
            $newNames      = $newModelFiles      | % { $_.Name }
            $added   = $newNames | ? { $_ -notin $existingNames -and $_ -ne "$ctxClassName.cs" }
            $removed = $existingNames | ? { $_ -notin $newNames -and $_ -ne "$ctxClassName.cs" }
            $common  = $newNames | ? { $_ -in $existingNames  -and $_ -ne "$ctxClassName.cs" }

            $perEntityDiff = @{}
            foreach($n in $common){ $perEntityDiff[$n] = _ModelDiffReport -oldFile (Join-Path $modelsDir $n) -newFile (Join-Path $tempModelsAbs $n) }
            foreach($n in $added){  $perEntityDiff[$n] = _ModelDiffReport -oldFile $null -newFile (Join-Path $tempModelsAbs $n) }

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
                if ($added.Count -gt 0) { _Note "NEW MODELS:"; foreach($n in $added){ Write-Host ("  + {0}" -f $n) -ForegroundColor Green }; _Info "" }
                if ($removed.Count -gt 0) { _Warn "REMOVED MODELS:"; foreach($n in $removed){ Write-Host ("  - {0}" -f $n) -ForegroundColor Red }; _Info ""; _Warn "Consider manually removing corresponding controllers if they exist."; _Info "" }
                if ($common.Count -gt 0) {
                    _Note "UPDATED MODELS (Property Changes):"
                    foreach($k in $perEntityDiff.Keys) {
                        $d = $perEntityDiff[$k]
                        $has = ($d.Added.Count -or $d.Removed.Count -or $d.Changed.Count)
                        if ($has){
                            Write-Host ("  {0}:" -f $k) -ForegroundColor Yellow
                            foreach($p in $d.Added)   { Write-Host ("    + {0} : {1}" -f $p.Name, $p.Type) -ForegroundColor Green }
                            foreach($p in $d.Removed) { Write-Host ("    - {0} : {1}" -f $p.Name, $p.Type) -ForegroundColor Red }
                            foreach($p in $d.Changed) { Write-Host ("    ~ {0} : {1} -> {2}" -f $p.Name, $p.From, $p.To) -ForegroundColor Cyan }
                        }
                    }
                }
                return [pscustomobject]@{
                    Action='PreviewUpdateFromDatabase'; Engine=$engine.Engine; Database=$engine.DatabaseName
                    Context=$ctxClassName; ProjectPath=$ProjectPath; ModelsPath=$ModelsPath
                    AddedModels=$added; RemovedModels=$removed; Overwritten=$common; Diff=$perEntityDiff; DryRun=$true
                }
            }

            if ($PSCmdlet.ShouldProcess("$($engine.Engine)::$($engine.DatabaseName)", "Apply Smart Update")) {

                if ($BackupBeforeApply) {
                    $backupDir = Join-Path $ProjectPath ".apitools_backups"; _EnsureDir $backupDir
                    $backupPath = Join-Path $backupDir ("backup_{0}" -f $stamp); _EnsureDir $backupPath
                    _Note "Creating backup: $backupPath"
                    Copy-Item -Path (Join-Path $ProjectPath '*') -Destination $backupPath -Recurse -Force -Exclude $TempRoot,'.git','.vs','bin','obj'
                }

                # Copy new entity models (including the new context file), then reopen context and merge carry-over.
                _Note "Refreshing entity models..."
                _EnsureDir $modelsDir
                Copy-Item -Path (Join-Path $tempModelsAbs '*') -Destination $modelsDir -Recurse -Force

                $projCtxPath = Join-Path $modelsDir "$ctxClassName.cs"
                if (-not (Test-Path $projCtxPath)) { _Fail "Scaffold did not produce expected context '$ctxClassName.cs'." }

                $newCtxContent = _ReadAll $projCtxPath
                $mergedCtx     = _InsertCarryOver -newCtxContent $newCtxContent -carryOver $carryOver
                if ($null -eq $mergedCtx) { _Fail "Could not merge OnModelCreating in new context." }
                Set-Content -Path $projCtxPath -Value $mergedCtx -Encoding UTF8

                # Optionally generate controllers for NEW entities only
                $controllersGenerated = 0
                if ($RegenerateControllers) {
                    _EnsureCodegenTool
                    _EnsureSqlServerPkgForPgWhenCodegen -projectDir $ProjectPath -engineName $engine.Engine
                    $controllersPath = _FindControllersPath $ProjectPath
                    Push-Location $ProjectPath
                    try {
                        $null = dotnet build 2>&1
                        foreach($entityName in $added){
                            $modelName = [IO.Path]::GetFileNameWithoutExtension($entityName)
                            $controllerFile = Join-Path $controllersPath ("{0}Controller.cs" -f $modelName)
                            if (Test-Path $controllerFile) { continue }
                            $projName = _GetProjectName $ProjectPath
                            $modelFqn = "$projName.Models.$modelName"
                            $ctxFqn   = "$projName.Models.$ctxClassName"
                            $out = dotnet aspnet-codegenerator controller `
                                   -name ("{0}Controller" -f $modelName) `
                                   -async -api -m $modelFqn -dc $ctxFqn -outDir $controllersPath -f 2>&1
                            if ($LASTEXITCODE -eq 0 -and (Test-Path $controllerFile)) { $controllersGenerated++ }
                        }
                    } finally { Pop-Location }
                }

                # Optional migration (parity tracking)
                $migrationCreated = $false
                if ($CreateMigration) {
                    if ([string]::IsNullOrWhiteSpace($MigrationName)) { $MigrationName = "Update_" + (_NewStamp) }
                    $MigrationName = ($MigrationName -replace '[^\w]', '_')
                    Push-Location $ProjectPath
                    try {
                        $out = dotnet ef migrations add $MigrationName 2>&1
                        if ($LASTEXITCODE -eq 0) { $migrationCreated = $true }
                    } finally { Pop-Location }
                }

                # Report
                $reportsDir = Join-Path $ProjectPath ".apitools_reports"; _EnsureDir $reportsDir
                $reportTxt  = Join-Path $reportsDir ("update_{0}.txt" -f $stamp)
                $reportJson = Join-Path $reportsDir ("update_{0}.json" -f $stamp)

                $summary = [pscustomobject]@{
                    Action='UpdateFromDatabase'; Engine=$engine.Engine; Database=$engine.DatabaseName
                    Context=$ctxClassName; ProjectPath=$ProjectPath; ModelsPath=$ModelsPath
                    Added=$added; Removed=$removed; Overwritten=$common; PropertyDiff=$perEntityDiff
                    ControllersGenerated=$controllersGenerated; MigrationCreated=$migrationCreated
                    Timestamp=$stamp; Created=$true
                }

                $txt = @(
                    "Update-ApiToolsFromDatabase @ $stamp",
                    "Engine: $($engine.Engine)",
                    "Database: $($engine.DatabaseName)",
                    "Context: $ctxClassName",
                    "Models added:        $($added.Count)",
                    "Models removed:      $($removed.Count)",
                    "Models overwritten:  $($common.Count)",
                    ($controllersGenerated -gt 0) ? "Controllers created:  $controllersGenerated (new entities)" : $null,
                    ($migrationCreated) ? "Migration created:    $MigrationName" : $null,
                    "Custom (non-entity) statements preserved and inserted before OnModelCreatingPartial(modelBuilder)."
                ) | Where-Object { $_ -ne $null }
                $txt -join "`r`n" | Set-Content -Path $reportTxt -Encoding UTF8
                $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $reportJson -Encoding UTF8

                _Ok  "✓ Models updated and DbContext merged successfully."
                _Info ""
                _Info "CHANGES APPLIED:"
                Write-Host ("  Models added:        {0}" -f $added.Count)   -ForegroundColor Green
                Write-Host ("  Models removed:      {0}" -f $removed.Count) -ForegroundColor Red
                Write-Host ("  Models overwritten:  {0}" -f $common.Count)  -ForegroundColor Yellow
                if ($common.Count -gt 0 -or $added.Count -gt 0) {
                    $totalPropsAdded   = ($perEntityDiff.Values | % { $_.Added.Count }   | Measure-Object -Sum).Sum
                    $totalPropsRemoved = ($perEntityDiff.Values | % { $_.Removed.Count } | Measure-Object -Sum).Sum
                    $totalPropsChanged = ($perEntityDiff.Values | % { $_.Changed.Count } | Measure-Object -Sum).Sum
                    if ($totalPropsAdded -or $totalPropsRemoved -or $totalPropsChanged) {
                        Write-Host ("    Properties: +{0} / -{1} / ~{2}" -f $totalPropsAdded, $totalPropsRemoved, $totalPropsChanged) -ForegroundColor Gray
                    }
                }
                if ($removed.Count -gt 0) {
                    _Info ""; _Warn "⚠ Models removed from database:"
                    foreach($n in $removed) { Write-Host ("  - {0}" -f $n) -ForegroundColor Red }
                    _Info ""; _Warn "Consider manually removing corresponding controllers if they exist."
                }
                _Info ""; _Info "Reports saved:"; _Info ("  Text: {0}" -f $reportTxt); _Info ("  JSON: {0}" -f $reportJson)

                return $summary
            }
            else {
                return [pscustomobject]@{
                    Action='UpdateFromDatabaseCancelled'; Engine=$engine.Engine; Database=$engine.DatabaseName
                    Context=$ctxClassName; ProjectPath=$ProjectPath; WhatIf=$true
                }
            }
        }
        finally {
            Pop-Location
            # Keep temp for audit. Uncomment to auto-clean:
            # Remove-Item -Path $tempRunAbs -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
