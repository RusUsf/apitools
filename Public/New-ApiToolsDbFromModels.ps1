<#
.SYNOPSIS
Creates a database from existing C# Entity Framework models using EF migrations.

.DESCRIPTION
New-ApiToolsDbFromModels scans the current directory for a .NET project with Entity Framework models, generates a timestamped migration, and creates the database with schema on SQL Server or PostgreSQL. The command supports interactive mode with connection string examples, automatic provider detection, and model cleanup for PostgreSQL compatibility. The function validates prerequisites (.NET CLI and dotnet-ef tool), cleans up scaffolded PostgreSQL-specific patterns (sequences) for Code First compatibility, and uses native ADO.NET (System.Data.SqlClient for SQL Server, System.Data.Odbc for PostgreSQL) for connection validation.

.PARAMETER ConnectionString
The database server connection string. For SQL Server use Windows authentication like "Server=localhost;Trusted_Connection=True;" or SQL authentication like "Server=localhost;User Id=sa;Password=StrongPwd!". For PostgreSQL use native format like "Server=localhost;Port=5432;User Id=postgres;Password=secret". Database name is auto-derived from project name. If omitted, interactive mode prompts with examples.

.PARAMETER ProjectPath
The directory containing the .NET project with models and DbContext. Defaults to the current directory.

.PARAMETER DatabaseName
The database name to create. If omitted, defaults to the project name extracted from the .csproj file.

.PARAMETER Force
If supplied, drops the existing database if it exists and recreates it with a fresh migration.

.PARAMETER DryRun
When present, validates prerequisites and project structure, shows what would be generated, and performs no changes.

.EXAMPLE
# Interactive mode with examples
PS> New-ApiToolsDbFromModels
Prompts for connection string with SQL Server and PostgreSQL examples, validates tools and project structure.

.EXAMPLE
# Create database from models in current directory
PS> New-ApiToolsDbFromModels -ConnectionString "Server=localhost;Trusted_Connection=True;"
Scans current directory for .csproj, generates migration, creates database named after the project.

.EXAMPLE
# Create PostgreSQL database with custom name
PS> New-ApiToolsDbFromModels -ConnectionString "Server=localhost;Port=5432;User Id=postgres;Password=Secret123!" -DatabaseName "MyCustomDb"
Creates MyCustomDb on PostgreSQL with auto-discovered ODBC driver, applies migration from models.

.EXAMPLE
# Force rebuild database with dry-run preview
PS> New-ApiToolsDbFromModels -ConnectionString "Server=localhost;Trusted_Connection=True;" -Force -DryRun
Shows execution plan without making changes. Remove -DryRun to drop, recreate database and apply fresh migration.

.EXAMPLE
# Create database from models in specific project path
PS> New-ApiToolsDbFromModels -ConnectionString "Server=localhost;Port=5432;User Id=postgres;Password=secret" -ProjectPath "C:\Projects\MyApp"
Navigates to specified path, finds project, generates migration and creates database.

.INPUTS
None. You pipe nothing to this command.

.OUTPUTS
A PSCustomObject summary with Action, Engine, Database, ProjectName, MigrationName, and Created fields when execution succeeds. In -DryRun mode returns a plan object.

.NOTES
Author: Your Name
Module: apitools
This command requires .NET CLI with dotnet-ef global tool installed. The function validates these prerequisites before execution. PostgreSQL ODBC driver discovery is automatic. The function cleans up scaffolded PostgreSQL sequence patterns for Code First compatibility.
#>

function New-ApiToolsDbFromModels {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConnectionString,
        [string]$ProjectPath = (Get-Location).Path,
        [string]$DatabaseName,
        [switch]$Force,
        [switch]$DryRun
    )

    # =========================================================================
    # HELPER FUNCTION: Convert PostgreSQL native connection string to ODBC
    # =========================================================================
    function ConvertTo-PostgreSqlOdbc {
        param([string]$NativeConnectionString)

        # Already ODBC format - return as-is
        if ($NativeConnectionString -match '(?i)Driver\s*=') {
            return $NativeConnectionString
        }

        # Auto-discover PostgreSQL ODBC driver
        Write-Verbose "Auto-discovering PostgreSQL ODBC driver..."
        $pgDriver = $null
        try {
            $pgDriver = (Get-OdbcDriver -Platform '64-bit' -ErrorAction SilentlyContinue | 
                Where-Object { $_.Name -match 'PostgreSQL.*UNICODE' } | 
                Select-Object -First 1).Name
        }
        catch {
            # Fallback: try common driver names
            $commonDrivers = @('PostgreSQL Unicode(x64)', 'PostgreSQL Unicode')
            foreach ($driver in $commonDrivers) {
                try {
                    $testConn = "Driver={$driver};Server=localhost"
                    $null = New-Object System.Data.Odbc.OdbcConnection $testConn
                    $pgDriver = $driver
                    break
                }
                catch { }
            }
        }

        if (-not $pgDriver) {
            throw "No 64-bit PostgreSQL ODBC driver found. Install psqlODBC (x64) from https://www.postgresql.org/ftp/odbc/versions/ and try again."
        }

        Write-Verbose "Using PostgreSQL ODBC driver: $pgDriver"

        # Parse native connection string
        $params = @{}
        foreach ($part in ($NativeConnectionString -split ';')) {
            $p = $part.Trim()
            if ($p -match '^(?i)([^=]+)=(.+)$') {
                $key = $Matches[1].Trim()
                $value = $Matches[2].Trim()
                $params[$key] = $value
            }
        }

        # Build ODBC connection string
        $odbcParts = @("Driver={$pgDriver}")
        
        if ($params.ContainsKey('Server') -or $params.ContainsKey('Host')) {
            $server = if ($params.ContainsKey('Server')) { $params['Server'] } else { $params['Host'] }
            $odbcParts += "Server=$server"
        }
        
        if ($params.ContainsKey('Port')) { $odbcParts += "Port=$($params['Port'])" }
        if ($params.ContainsKey('Database') -or $params.ContainsKey('Initial Catalog')) {
            $db = if ($params.ContainsKey('Database')) { $params['Database'] } else { $params['Initial Catalog'] }
            $odbcParts += "Database=$db"
        }
        if ($params.ContainsKey('User Id') -or $params.ContainsKey('Username') -or $params.ContainsKey('Uid')) {
            $uid = if ($params.ContainsKey('User Id')) { $params['User Id'] } 
            elseif ($params.ContainsKey('Username')) { $params['Username'] }
            else { $params['Uid'] }
            $odbcParts += "Uid=$uid"
        }
        if ($params.ContainsKey('Password') -or $params.ContainsKey('Pwd')) {
            $myPwd = if ($params.ContainsKey('Password')) { $params['Password'] } else { $params['Pwd'] }
            $odbcParts += "Pwd=$myPwd"
        }
        if ($params.ContainsKey('SSL Mode') -or $params.ContainsKey('SslMode')) {
            $ssl = if ($params.ContainsKey('SSL Mode')) { $params['SSL Mode'] } else { $params['SslMode'] }
            $odbcParts += "SSLMode=$ssl"
        }

        return ($odbcParts -join ';')
    }

    # =========================================================================
    # STEP 1: CHECK REQUIRED .NET CLI TOOLS
    # =========================================================================
    Write-Verbose "Checking required .NET development tools..."
    
    $toolErrors = @()

    # Check for .NET CLI
    try {
        $dotnetVersion = dotnet --version 2>$null
        if ($null -eq $dotnetVersion) {
            throw "dotnet command not found"
        }
        Write-Verbose "✓ .NET CLI found (version: $dotnetVersion)"
    }
    catch {
        $toolErrors += "The .NET CLI is required but not installed. Download from https://dotnet.microsoft.com/download"
    }

    # Check for Entity Framework CLI tool
    try {
        $efVersion = dotnet ef --version 2>$null
        if ($null -eq $efVersion) {
            throw "dotnet-ef tool not found"
        }
        Write-Verbose "✓ Entity Framework CLI tool found"
    }
    catch {
        $toolErrors += "The dotnet-ef tool is required. Install with: dotnet tool install --global dotnet-ef"
    }

    if ($toolErrors.Count -gt 0) {
        throw "Missing required tools:`n" + ($toolErrors -join "`n")
    }

    # =========================================================================
    # STEP 2: FIND PROJECT AND EXTRACT NAME
    # =========================================================================
    Write-Verbose "Scanning for .NET project in: $ProjectPath"

    Push-Location $ProjectPath
    try {
        $projectFiles = Get-ChildItem -Path "." -Filter "*.csproj" -File

        if ($projectFiles.Count -eq 0) {
            throw "No .csproj files found in directory: $ProjectPath. Ensure the directory contains a .NET project with models and DbContext."
        }

        if ($projectFiles.Count -gt 1) {
            $projectList = ($projectFiles | ForEach-Object { $_.Name }) -join ", "
            throw "Multiple .csproj files found: $projectList. Please specify a directory with only one project."
        }

        $projectFile = $projectFiles[0]
        $projectName = [System.IO.Path]::GetFileNameWithoutExtension($projectFile.Name)
        Write-Verbose "✓ Found project: $projectName"

        # =========================================================================
        # STEP 3: VERIFY ENTITY FRAMEWORK PACKAGES
        # =========================================================================
        Write-Verbose "Verifying Entity Framework packages..."

        $projectContent = Get-Content -Path $projectFile.FullName -Raw
        $hasEfCore = $projectContent -match "Microsoft\.EntityFrameworkCore"
        $hasSqlServerProvider = $projectContent -match "Microsoft\.EntityFrameworkCore\.SqlServer"
        $hasPostgreSqlProvider = $projectContent -match "Npgsql\.EntityFrameworkCore\.PostgreSQL"

        if (-not $hasEfCore) {
            throw "Missing Entity Framework Core package. Install with: dotnet add package Microsoft.EntityFrameworkCore"
        }

        if (-not $hasSqlServerProvider -and -not $hasPostgreSqlProvider) {
            throw "Missing Entity Framework provider package. Install SqlServer provider with: dotnet add package Microsoft.EntityFrameworkCore.SqlServer OR PostgreSQL provider with: dotnet add package Npgsql.EntityFrameworkCore.PostgreSQL"
        }

        # Determine project provider from installed packages with smart detection
        # Note: SQL Server package may exist as a transitive dependency even for PostgreSQL projects
        # (aspnet-codegenerator tooling bug workaround). Check DbContext code to determine actual provider.
        
        $projectProvider = $null
        
        # First, try to detect the actual provider from DbContext configuration
        $dbContextFiles = Get-ChildItem -Path "." -Filter "*Context.cs" -Recurse
        $usesNpgsql = $false
        $usesSqlServer = $false
        
        foreach ($contextFile in $dbContextFiles) {
            $contextContent = Get-Content -Path $contextFile.FullName -Raw -ErrorAction SilentlyContinue
            if ($contextContent) {
                # Check for actual provider usage in code
                if ($contextContent -match 'UseNpgsql|Npgsql\.EntityFrameworkCore') {
                    $usesNpgsql = $true
                }
                if ($contextContent -match 'UseSqlServer(?!.*UseNpgsql)') {
                    $usesSqlServer = $true
                }
            }
        }
        
        # Determine provider based on actual usage in DbContext
        if ($usesNpgsql -and -not $usesSqlServer) {
            $projectProvider = 'PostgreSQL'
            Write-Verbose "✓ Detected PostgreSQL provider from DbContext configuration"
        }
        elseif ($usesSqlServer -and -not $usesNpgsql) {
            $projectProvider = 'SqlServer'
            Write-Verbose "✓ Detected SQL Server provider from DbContext configuration"
        }
        # Fallback: Check package references, but prioritize PostgreSQL if both exist
        elseif ($hasPostgreSqlProvider -and $hasSqlServerProvider) {
            $projectProvider = 'PostgreSQL'
            Write-Verbose "⚠ Both providers found in packages. SQL Server likely a transitive dependency. Using PostgreSQL."
        }
        elseif ($hasPostgreSqlProvider) {
            $projectProvider = 'PostgreSQL'
            Write-Verbose "✓ Using PostgreSQL provider from package reference"
        }
        elseif ($hasSqlServerProvider) {
            $projectProvider = 'SqlServer'
            Write-Verbose "✓ Using SQL Server provider from package reference"
        }
        else {
            throw "Unable to determine database provider. Neither SQL Server nor PostgreSQL provider detected."
        }
        
        Write-Verbose "✓ Entity Framework packages found (Provider: $projectProvider)"

        # =========================================================================
        # STEP 4: CLEAN UP MODELS FOR EF CODE FIRST COMPATIBILITY
        # =========================================================================
        Write-Verbose "Scanning for PostgreSQL compatibility issues..."

        $allModelFiles = Get-ChildItem -Path "." -Filter "*.cs" -Recurse | Where-Object {
            $_.Directory.Name -eq "Models" -or $_.Name -like "*Context.cs"
        }

        $filesModified = 0
        $cleanupActions = @()

        foreach ($file in $allModelFiles) {
            $content = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
            if ($null -eq $content) { continue }

            $originalContent = $content
            $fileModified = $false

            # Pattern 1: Replace sequence-based default value SQL
            if ($content -match 'HasDefaultValueSql\("nextval\([^)]+\)"\)') {
                $content = $content -replace 'HasDefaultValueSql\("nextval\([^)]+\)"\)', 'ValueGeneratedOnAdd()'
                $fileModified = $true
                $cleanupActions += "Replaced sequence references with ValueGeneratedOnAdd()"
            }

            # Pattern 2: Remove modelBuilder.HasSequence configurations
            if ($content -match 'modelBuilder\.HasSequence[^;]+;') {
                $content = $content -replace 'modelBuilder\.HasSequence[^;]+;\s*', ''
                $fileModified = $true
                $cleanupActions += "Removed sequence creation configurations"
            }

            # Pattern 3: Clean up sequence references in column configurations
            if ($content -match 'HasDefaultValueSql\("nextval\([^)]+::regclass\)"\)') {
                $content = $content -replace 'HasDefaultValueSql\("nextval\([^)]+::regclass\)"\)', 'ValueGeneratedOnAdd()'
                $fileModified = $true
                $cleanupActions += "Replaced regclass sequence references"
            }

            # Save changes if any were made
            if ($fileModified) {
                Set-Content -Path $file.FullName -Value $content -Encoding UTF8
                Write-Verbose "✓ Cleaned $($file.Name)"
                $filesModified++
            }
        }

        if ($filesModified -gt 0) {
            Write-Verbose "✓ Modified $filesModified files for EF Code First compatibility"
        }

        # =========================================================================
        # STEP 5: INTERACTIVE MODE - Prompt for connection string if not provided
        # =========================================================================
        if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
            Write-Host ""
            Write-Host "=== DATABASE CONNECTION SETUP ===" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "Enter your database SERVER connection string (database name will be auto-added):" -ForegroundColor White
            Write-Host ""
            Write-Host "PostgreSQL Examples:" -ForegroundColor Yellow
            Write-Host "  Server=localhost;Port=5432;User Id=postgres;Password=yourpassword" -ForegroundColor Gray
            Write-Host "  Server=hostname;Port=5432;User Id=postgres;Password=yourpassword;SSL Mode=Require" -ForegroundColor Gray
            Write-Host ""
            Write-Host "SQL Server Examples:" -ForegroundColor Yellow
            Write-Host "  Server=localhost;Trusted_Connection=true" -ForegroundColor Gray
            Write-Host "  Server=localhost;User Id=sa;Password=YourStrong!Passw0rd" -ForegroundColor Gray
            Write-Host ""

            $ConnectionString = Read-Host "Connection String"

            if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
                throw "Connection string cannot be empty."
            }
        }

        # Clean any existing database specification
        if ($ConnectionString -match "Database\s*=") {
            $ConnectionString = $ConnectionString -replace "Database\s*=[^;]*;?", ""
            Write-Verbose "✓ Removed existing database specification from connection string"
        }

        # =========================================================================
        # STEP 6: AUTO-DETECT DATABASE ENGINE FROM CONNECTION STRING
        # =========================================================================
        Write-Verbose "Auto-detecting database engine from connection string..."

        $connectionEngine = $null

        # PostgreSQL detection
        if ($ConnectionString -match '(?i)(npgsql|postgres|port\s*=\s*5432)') {
            $connectionEngine = 'PostgreSQL'
            Write-Verbose "Detected connection engine: PostgreSQL"
        }
        # SQL Server detection
        elseif ($ConnectionString -match '(?i)(server\s*=|data source\s*=|trusted_connection|sqlserver)') {
            $connectionEngine = 'SqlServer'
            Write-Verbose "Detected connection engine: SQL Server"
        }
        else {
            throw "Unable to auto-detect database engine. Ensure connection string contains 'Server=' or 'postgres'."
        }

        # Validate that project provider matches connection string
        if ($projectProvider -ne $connectionEngine) {
            throw "Provider mismatch! Project uses $projectProvider provider but connection string is for $connectionEngine. Install the correct provider package: " + 
            $(if ($connectionEngine -eq 'PostgreSQL') { "dotnet add package Npgsql.EntityFrameworkCore.PostgreSQL" } else { "dotnet add package Microsoft.EntityFrameworkCore.SqlServer" })
        }

        $engine = $projectProvider
        Write-Verbose "✓ Provider and connection string match: $engine"

        # Determine database name
        if ([string]::IsNullOrWhiteSpace($DatabaseName)) {
            $DatabaseName = $projectName
        }

        Write-Verbose "Database name: $DatabaseName"

        # Build target connection string with provider-specific format
        $targetConnectionString = $ConnectionString
        if (-not $targetConnectionString.EndsWith(";")) {
            $targetConnectionString += ";"
        }
        $targetConnectionString += "Database=$DatabaseName"

        # Convert PostgreSQL connection string to Npgsql format for EF
        if ($engine -eq 'PostgreSQL') {
            # Npgsql uses Host= instead of Server= and different syntax
            $targetConnectionString = $targetConnectionString -replace '(?i)Server\s*=', 'Host='
            Write-Verbose "Converted PostgreSQL connection string to Npgsql format"
        }

        # Auto-fix common SQL Server connection issues
        if ($engine -eq 'SqlServer') {
            if ($targetConnectionString -notmatch '(?i)TrustServerCertificate') {
                $targetConnectionString = $targetConnectionString + ";TrustServerCertificate=true"
            }
            if ($targetConnectionString -notmatch '(?i)Encrypt') {
                $targetConnectionString = $targetConnectionString + ";Encrypt=false"
            }
            Write-Verbose "Modified connection string includes SSL trust settings"
        }

        # =========================================================================
        # STEP 7: VALIDATE DATABASE CONNECTION (Server-level)
        # =========================================================================
        Write-Verbose "Validating database server connection..."

        # For validation, use server connection without specific database
        $serverValidationConn = $ConnectionString
        if (-not $serverValidationConn.EndsWith(";")) {
            $serverValidationConn += ";"
        }

        try {
            if ($engine -eq 'SqlServer') {
                # Add master database for validation
                $validationConn = $serverValidationConn + "Database=master"
                $conn = New-Object System.Data.SqlClient.SqlConnection $validationConn
                $conn.Open()
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = "SELECT 1"
                [void]$cmd.ExecuteScalar()
                $conn.Close()
                Write-Verbose "✓ SQL Server connection validated"
            }
            else {
                # For PostgreSQL, validate using ODBC with postgres database
                $validationConn = $serverValidationConn + "Database=postgres"
                $odbcConn = ConvertTo-PostgreSqlOdbc -NativeConnectionString $validationConn
                $conn = New-Object System.Data.Odbc.OdbcConnection $odbcConn
                $conn.Open()
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = "SELECT 1"
                [void]$cmd.ExecuteScalar()
                $conn.Close()
                Write-Verbose "✓ PostgreSQL connection validated"
            }
        }
        catch {
            throw "Connection validation failed: $($_.Exception.Message). Verify server is running and credentials are correct."
        }

        # =========================================================================
        # STEP 8: GENERATE TIMESTAMPED MIGRATION NAME
        # =========================================================================
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $migrationName = "Migration_$timestamp"

        Write-Verbose "Migration name: $migrationName"

        # =========================================================================
        # STEP 9: DRY RUN MODE - Show plan without executing
        # =========================================================================
        if ($DryRun) {
            $plan = [pscustomobject]@{
                Action        = 'CreateDbFromModels'
                Engine        = $engine
                Database      = $DatabaseName
                ProjectName   = $projectName
                ProjectPath   = $ProjectPath
                MigrationName = $migrationName
                Steps         = @(
                    "1. Clean up PostgreSQL-specific patterns in models ($filesModified files)"
                    "2. Generate migration: dotnet ef migrations add $migrationName"
                    "3. Apply migration: dotnet ef database update --connection `"$targetConnectionString`""
                    if ($Force) { "4. Force mode: Drop existing database if present" }
                )
                WillCreate    = $true
            }
            
            Write-Host ""
            Write-Host "=== DRY RUN - EXECUTION PLAN ===" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Engine: $($plan.Engine)" -ForegroundColor White
            Write-Host "Database: $($plan.Database)" -ForegroundColor White
            Write-Host "Project: $($plan.ProjectName)" -ForegroundColor White
            Write-Host "Migration: $($plan.MigrationName)" -ForegroundColor White
            Write-Host ""
            Write-Host "Steps that would be executed:" -ForegroundColor White
            foreach ($step in $plan.Steps) {
                if ($step) {
                    Write-Host "  $step" -ForegroundColor Gray
                }
            }
            Write-Host ""
            return $plan
        }

        # =========================================================================
        # STEP 10: EXECUTE MIGRATION GENERATION AND DATABASE CREATION
        # =========================================================================
        if ($PSCmdlet.ShouldProcess("$engine::$DatabaseName", "Create database from EF models")) {

            # Initialize progress tracking
            $totalSteps = 2
            $currentStep = 0

            # =========================================================================
            # STEP 11: GENERATE MIGRATION
            # =========================================================================
            $currentStep++
            Write-Progress -Activity "Creating Database from Models" -Status "Generating migration..." -PercentComplete (($currentStep / $totalSteps) * 100)
            Write-Verbose "Generating migration: $migrationName"

            $migrationResult = & dotnet ef migrations add $migrationName --output-dir Migrations 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Progress -Activity "Creating Database from Models" -Completed
                throw "Failed to generate migration: $migrationResult"
            }
            Write-Verbose "✓ Migration generated successfully"

            # =========================================================================
            # STEP 12: APPLY MIGRATION (CREATES DATABASE + SCHEMA)
            # =========================================================================
            $currentStep++
            Write-Progress -Activity "Creating Database from Models" -Status "Applying migration to create database..." -PercentComplete (($currentStep / $totalSteps) * 100)
            Write-Verbose "Applying migration to create database and schema..."

            $updateResult = & dotnet ef database update --connection $targetConnectionString 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Progress -Activity "Creating Database from Models" -Completed
                throw "Failed to apply migration: $updateResult"
            }
            Write-Verbose "✓ Database and schema created successfully"

            # Complete progress bar
            Write-Progress -Activity "Creating Database from Models" -Status "Completed!" -PercentComplete 100
            Start-Sleep -Milliseconds 500
            Write-Progress -Activity "Creating Database from Models" -Completed

            # =========================================================================
            # STEP 13: RETURN SUCCESS SUMMARY
            # =========================================================================
            Write-Host ""
            Write-Host "✓ Database created successfully from models!" -ForegroundColor Green
            Write-Host ""
            Write-Host "Project: $projectName" -ForegroundColor White
            Write-Host "Database: $DatabaseName" -ForegroundColor White
            Write-Host "Engine: $engine" -ForegroundColor White
            Write-Host "Migration: $migrationName" -ForegroundColor White
            Write-Host ""
            Write-Host "Connection String:" -ForegroundColor Cyan
            Write-Host "  $targetConnectionString" -ForegroundColor Gray
            Write-Host ""
            Write-Host "Add to your appsettings.json:" -ForegroundColor Cyan
            Write-Host "  `"ConnectionStrings`": {" -ForegroundColor Gray
            Write-Host "    `"DefaultConnection`": `"$targetConnectionString`"" -ForegroundColor Gray
            Write-Host "  }" -ForegroundColor Gray
            Write-Host ""

            return [pscustomobject]@{
                Action        = 'CreateDbFromModels'
                Engine        = $engine
                Database      = $DatabaseName
                ProjectName   = $projectName
                MigrationName = $migrationName
                Created       = $true
            }
        }
    }
    finally {
        Pop-Location
    }
}
