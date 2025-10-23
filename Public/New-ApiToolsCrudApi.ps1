<#
.SYNOPSIS
Generates a complete ASP.NET Core Web API with CRUD controllers from an existing database.

.DESCRIPTION
New-ApiToolsCrudApi connects to SQL Server or PostgreSQL, scaffolds Entity Framework models from the database schema, generates CRUD controllers for each table, and configures a ready-to-run Web API project with Swagger. The command supports interactive mode with connection string examples, automatic PostgreSQL ODBC driver discovery, and requires only the .NET CLI tools (dotnet ef and aspnet-codegenerator). SQL Server uses System.Data.SqlClient and PostgreSQL uses System.Data.Odbc for connection validation before scaffolding.

.PARAMETER ConnectionString
The database connection string. For SQL Server use Windows authentication like "Server=localhost;Database=mydb;Trusted_Connection=True;" or SQL authentication like "Server=localhost;Database=mydb;User Id=sa;Password=StrongPwd!". For PostgreSQL use native format like "Server=localhost;Port=5432;Database=mydb;User Id=postgres;Password=secret". If omitted, interactive mode prompts with examples.

.PARAMETER ProjectName
The name for the generated Web API project. If omitted, defaults to "{DatabaseName}_CRUD_API". The function handles naming conflicts automatically by appending numeric suffixes.

.PARAMETER OutputPath
The directory where the project folder will be created. Defaults to the current directory.

.PARAMETER Force
If supplied, overwrites an existing project directory with the same name.

.PARAMETER DryRun
When present, validates prerequisites and connection, shows what would be generated, and performs no changes.

.EXAMPLE
# Interactive mode with examples
PS> New-ApiToolsCrudApi
Prompts for connection string with SQL Server and PostgreSQL examples, validates tools and connection.

.EXAMPLE
# Generate API from SQL Server database
PS> New-ApiToolsCrudApi -ConnectionString "Server=localhost;Database=Hospital_db;Trusted_Connection=True;"
Scaffolds models and controllers from Hospital_db, creates a complete Web API project named Hospital_db_CRUD_API.

.EXAMPLE
# Generate API from PostgreSQL with custom project name
PS> New-ApiToolsCrudApi -ConnectionString "Server=localhost;Port=5432;Database=hospital_db;User Id=postgres;Password=Secret123!" -ProjectName "HospitalAPI"
Creates HospitalAPI project with auto-discovered PostgreSQL ODBC driver, scaffolds all models and CRUD controllers.

.EXAMPLE
# Dry-run to preview what would be generated
PS> New-ApiToolsCrudApi -ConnectionString "Server=localhost;Database=mydb;Trusted_Connection=True;" -DryRun
Validates connection and tools, shows project structure that would be created without generating files.

.EXAMPLE
# Force overwrite existing project
PS> New-ApiToolsCrudApi -ConnectionString "Server=localhost;Database=mydb;Trusted_Connection=True;" -ProjectName "MyAPI" -Force
Deletes existing MyAPI folder if present and regenerates the complete project.

.INPUTS
None. You pipe nothing to this command.

.OUTPUTS
A PSCustomObject summary with Action, Engine, Database, ProjectName, ProjectPath, ModelsGenerated, ControllersGenerated, and Created fields when execution succeeds. In -DryRun mode returns a plan object.

.NOTES
Author: Your Name
Module: apitools
This command requires .NET CLI with dotnet-ef and dotnet-aspnet-codegenerator global tools installed. The function validates these prerequisites before execution. PostgreSQL ODBC driver discovery is automatic.
#>

function New-ApiToolsCrudApi {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConnectionString,
        [string]$ProjectName,
        [string]$OutputPath = (Get-Location).Path,
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

    # Check for ASP.NET Code Generator tool
    try {
        $codegenVersion = dotnet aspnet-codegenerator --help 2>$null
        if ($null -eq $codegenVersion) {
            throw "dotnet-aspnet-codegenerator tool not found"
        }
        Write-Verbose "✓ ASP.NET Code Generator tool found"
    }
    catch {
        $toolErrors += "The dotnet-aspnet-codegenerator tool is required. Install with: dotnet tool install --global dotnet-aspnet-codegenerator"
    }

    if ($toolErrors.Count -gt 0) {
        throw "Missing required tools:`n" + ($toolErrors -join "`n")
    }

    # =========================================================================
    # STEP 2: INTERACTIVE MODE - Prompt for connection string if not provided
    # =========================================================================
    if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
        Write-Host ""
        Write-Host "=== DATABASE CONNECTION SETUP ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Enter your database connection string:" -ForegroundColor White
        Write-Host ""
        Write-Host "PostgreSQL Examples:" -ForegroundColor Yellow
        Write-Host "  Server=localhost;Port=5432;Database=hospital_db;User Id=postgres;Password=yourpassword" -ForegroundColor Gray
        Write-Host "  Server=hostname;Port=5432;Database=mydb;User Id=postgres;Password=yourpassword;SSL Mode=Require" -ForegroundColor Gray
        Write-Host ""
        Write-Host "SQL Server Examples:" -ForegroundColor Yellow
        Write-Host "  Server=localhost;Database=Hospital_db;Trusted_Connection=true" -ForegroundColor Gray
        Write-Host "  Server=localhost;Database=mydb;User Id=sa;Password=YourStrong!Passw0rd" -ForegroundColor Gray
        Write-Host ""

        $ConnectionString = Read-Host "Connection String"

        if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
            throw "Connection string cannot be empty."
        }
    }

    # =========================================================================
    # STEP 3: AUTO-DETECT DATABASE ENGINE AND EXTRACT DATABASE NAME
    # =========================================================================
    Write-Verbose "Auto-detecting database engine..."

    $engine = $null
    $providerPackage = $null
    $scaffoldProvider = $null

    # PostgreSQL detection
    if ($ConnectionString -match '(?i)(npgsql|postgres|port\s*=\s*5432)') {
        $engine = 'PostgreSQL'
        $providerPackage = 'Npgsql.EntityFrameworkCore.PostgreSQL'
        $scaffoldProvider = 'Npgsql.EntityFrameworkCore.PostgreSQL'
        Write-Verbose "Detected engine: PostgreSQL"
    }
    # SQL Server detection
    elseif ($ConnectionString -match '(?i)(server\s*=|data source\s*=|trusted_connection|sqlserver)') {
        $engine = 'SqlServer'
        $providerPackage = 'Microsoft.EntityFrameworkCore.SqlServer'
        $scaffoldProvider = 'Microsoft.EntityFrameworkCore.SqlServer'
        Write-Verbose "Detected engine: SQL Server"
    }
    else {
        throw "Unable to auto-detect database engine. Ensure connection string contains 'Server=' or 'postgres'."
    }

    # Extract database name from connection string
    $DatabaseName = $null
    foreach ($part in ($ConnectionString -split ';')) {
        if ($part -match '(?i)^(Database|Initial Catalog)\s*=\s*(.+)$') {
            $DatabaseName = $Matches[2].Trim()
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($DatabaseName)) {
        throw "Could not extract database name from connection string. Ensure it includes 'Database=YourDatabaseName'."
    }

    Write-Verbose "Database name extracted: $DatabaseName"

    # Auto-fix common SQL Server connection issues
    if ($engine -eq 'SqlServer') {
        if ($ConnectionString -notmatch '(?i)TrustServerCertificate') {
            $ConnectionString = $ConnectionString + ";TrustServerCertificate=true"
        }
        if ($ConnectionString -notmatch '(?i)Encrypt') {
            $ConnectionString = $ConnectionString + ";Encrypt=false"
        }
        Write-Verbose "Modified connection string includes SSL trust settings"
    }

    # =========================================================================
    # STEP 4: VALIDATE DATABASE CONNECTION
    # =========================================================================
    Write-Verbose "Validating database connection..."

    try {
        if ($engine -eq 'SqlServer') {
            $conn = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
            $conn.Open()
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = "SELECT 1"
            [void]$cmd.ExecuteScalar()
            $conn.Close()
            Write-Verbose "✓ SQL Server connection validated"
        }
        else {
            # Convert to ODBC and test PostgreSQL connection
            $odbcConn = ConvertTo-PostgreSqlOdbc -NativeConnectionString $ConnectionString
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
        throw "Connection validation failed: $($_.Exception.Message)"
    }

    # =========================================================================
    # STEP 5: DETERMINE PROJECT NAME AND PATH
    # =========================================================================
    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        $ProjectName = "$($DatabaseName)_CRUD_API"
    }

    # Handle naming conflicts
    $finalProjectName = $ProjectName
    $counter = 1
    $projectFullPath = Join-Path $OutputPath $finalProjectName

    if (-not $Force) {
        while (Test-Path $projectFullPath) {
            $finalProjectName = "$ProjectName`_$counter"
            $projectFullPath = Join-Path $OutputPath $finalProjectName
            $counter++
        }
    }

    Write-Verbose "Project will be created at: $projectFullPath"

    # =========================================================================
    # STEP 6: DRY RUN MODE - Show plan without executing
    # =========================================================================
    if ($DryRun) {
        $plan = [pscustomobject]@{
            Action      = 'CreateCrudApi'
            Engine      = $engine
            Database    = $DatabaseName
            ProjectName = $finalProjectName
            ProjectPath = $projectFullPath
            Provider    = $providerPackage
            Steps       = @(
                "1. Create Web API project: dotnet new webapi -n $finalProjectName"
                "2. Install EF package: dotnet add package $providerPackage"
                "3. Install design package: dotnet add package Microsoft.EntityFrameworkCore.Design"
                "4. Install codegen package: dotnet add package Microsoft.VisualStudio.Web.CodeGeneration.Design"
                "5. Scaffold DbContext and models: dotnet ef dbcontext scaffold"
                "6. Generate CRUD controllers for each model"
                "7. Configure Program.cs with DbContext and Swagger"
                "8. Configure appsettings.json with connection string"
            )
            WillCreate  = $true
        }
        
        Write-Host ""
        Write-Host "=== DRY RUN - EXECUTION PLAN ===" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Engine: $($plan.Engine)" -ForegroundColor White
        Write-Host "Database: $($plan.Database)" -ForegroundColor White
        Write-Host "Project: $($plan.ProjectName)" -ForegroundColor White
        Write-Host "Path: $($plan.ProjectPath)" -ForegroundColor White
        Write-Host ""
        Write-Host "Steps that would be executed:" -ForegroundColor White
        foreach ($step in $plan.Steps) {
            Write-Host "  $step" -ForegroundColor Gray
        }
        Write-Host ""
        return $plan
    }

    # =========================================================================
    # STEP 7: CREATE WEB API PROJECT
    # =========================================================================
    if ($PSCmdlet.ShouldProcess("$engine::$DatabaseName", "Create CRUD Web API project")) {

        # Remove existing directory if Force is specified
        if ($Force -and (Test-Path $projectFullPath)) {
            Write-Verbose "Removing existing project directory..."
            Remove-Item -Path $projectFullPath -Recurse -Force
        }

        # Create project
        Write-Verbose "Creating Web API project..."
        $createResult = & dotnet new webapi -n $finalProjectName -o $projectFullPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create Web API project: $createResult"
        }
        Write-Verbose "✓ Web API project created"

        # Change to project directory
        Push-Location $projectFullPath
        try {
            # =========================================================================
            # STEP 8: INSTALL REQUIRED NUGET PACKAGES
            # =========================================================================
            Write-Verbose "Installing NuGet packages..."

            $packages = @(
                $providerPackage,
                'Microsoft.EntityFrameworkCore.Design',
                'Microsoft.VisualStudio.Web.CodeGeneration.Design'
            )

            foreach ($package in $packages) {
                Write-Verbose "Installing $package..."
                $installResult = & dotnet add package $package 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Failed to install $package : $installResult"
                }
            }
            Write-Verbose "✓ NuGet packages installed"

            # =========================================================================
            # STEP 9: SCAFFOLD DBCONTEXT AND MODELS
            # =========================================================================
            Write-Verbose "Scaffolding DbContext and models from database..."

            $dbContextName = "$($DatabaseName)Context"
            $scaffoldArgs = @(
                'dbcontext',
                'scaffold',
                "`"$ConnectionString`"",
                $scaffoldProvider,
                '--output-dir', 'Models',
                '--context', $dbContextName,
                '--force'
            )

            $scaffoldResult = & dotnet ef @scaffoldArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to scaffold DbContext: $scaffoldResult"
            }
            Write-Verbose "✓ DbContext and models scaffolded"

            # Get list of generated model files
            $modelFiles = Get-ChildItem -Path "Models" -Filter "*.cs" -File | 
            Where-Object { $_.Name -ne "$dbContextName.cs" }
            
            $modelsGenerated = $modelFiles.Count
            Write-Verbose "Generated $modelsGenerated model(s)"

            # =========================================================================
            # STEP 10: GENERATE CRUD CONTROLLERS
            # =========================================================================
            Write-Verbose "Generating CRUD controllers..."

            $controllersGenerated = 0
            foreach ($modelFile in $modelFiles) {
                $modelName = [System.IO.Path]::GetFileNameWithoutExtension($modelFile.Name)
                
                Write-Verbose "Generating controller for $modelName..."
                
                $controllerArgs = @(
                    'controller',
                    '-name', "$($modelName)Controller",
                    '-async',
                    '-api',
                    '-m', "Models.$modelName",
                    '-dc', "Models.$dbContextName",
                    '-outDir', 'Controllers'
                )

                $controllerResult = & dotnet aspnet-codegenerator @controllerArgs 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $controllersGenerated++
                    Write-Verbose "✓ Controller generated for $modelName"
                }
                else {
                    Write-Warning "Failed to generate controller for $modelName : $controllerResult"
                }
            }

            # =========================================================================
            # STEP 11: CONFIGURE PROGRAM.CS
            # =========================================================================
            Write-Verbose "Configuring Program.cs..."

            $dbContextMethod = if ($engine -eq 'SqlServer') { 'UseSqlServer' } else { 'UseNpgsql' }

            $programCsContent = @"
using Microsoft.EntityFrameworkCore;
using $finalProjectName.Models;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container
var connectionString = builder.Configuration.GetConnectionString("DefaultConnection");
builder.Services.AddDbContext<$dbContextName>(options =>
    options.$dbContextMethod(connectionString));

builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

var app = builder.Build();

// Configure the HTTP request pipeline
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseHttpsRedirection();
app.UseAuthorization();
app.MapControllers();

app.Run();
"@

            Set-Content -Path "Program.cs" -Value $programCsContent -Encoding UTF8
            Write-Verbose "✓ Program.cs configured"

            # =========================================================================
            # STEP 12: CONFIGURE APPSETTINGS.JSON
            # =========================================================================
            Write-Verbose "Configuring appsettings.json..."

            # Escape backslashes for JSON
            $escapedConnectionString = $ConnectionString -replace '\\', '\\\\'

            $appsettingsContent = @"
{
  "ConnectionStrings": {
    "DefaultConnection": "$escapedConnectionString"
  },
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "AllowedHosts": "*"
}
"@

            Set-Content -Path "appsettings.json" -Value $appsettingsContent -Encoding UTF8
            Write-Verbose "✓ appsettings.json configured"

            # =========================================================================
            # STEP 13: RETURN SUCCESS SUMMARY
            # =========================================================================
            Write-Host ""
            Write-Host "✓ CRUD API project created successfully!" -ForegroundColor Green
            Write-Host ""
            Write-Host "Project: $finalProjectName" -ForegroundColor White
            Write-Host "Location: $projectFullPath" -ForegroundColor White
            Write-Host "Models: $modelsGenerated" -ForegroundColor White
            Write-Host "Controllers: $controllersGenerated" -ForegroundColor White
            Write-Host ""
            Write-Host "To run the API:" -ForegroundColor Cyan
            Write-Host "  cd `"$projectFullPath`"" -ForegroundColor Gray
            Write-Host "  dotnet run" -ForegroundColor Gray
            Write-Host ""
            Write-Host "Swagger UI will be available at: https://localhost:7xxx/swagger" -ForegroundColor Cyan
            Write-Host ""

            return [pscustomobject]@{
                Action               = 'CreateCrudApi'
                Engine               = $engine
                Database             = $DatabaseName
                ProjectName          = $finalProjectName
                ProjectPath          = $projectFullPath
                ModelsGenerated      = $modelsGenerated
                ControllersGenerated = $controllersGenerated
                Created              = $true
            }
        }
        finally {
            Pop-Location
        }
    }
}   