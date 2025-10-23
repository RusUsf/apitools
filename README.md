# apitools PowerShell Module

Lightweight, dependency-free PowerShell toolkit for modern API development and database tooling!

> **Built in the spirit of dbatools** - Powerful API development capabilities with zero external PowerShell dependencies. Uses native .NET classes for maximum transparency and portability.

## Why apitools?

- **🚀 Zero Dependencies** - No dbatools, SimplySql, or other PowerShell modules required
- **🔒 Native .NET** - Uses System.Data.SqlClient and System.Data.Odbc directly
- **🌍 Cross-Platform** - Works on Windows, Linux, and macOS
- **🎯 Developer-Friendly** - Interactive modes with helpful examples
- **🛡️ Safe** - ShouldProcess and -DryRun support for testing
- **📦 Complete** - From sample databases to full CRUD APIs

## Installation

```powershell
# Install from PowerShell Gallery
Install-Module -Name apitools

# Import the module
Import-Module apitools

# Verify installation
Get-Command -Module apitools
```

## Quick Start

### Create a Sample Database

```powershell
# Interactive mode (recommended for first-time users)
New-ApiToolsHospitalDb

# Automated mode - SQL Server
New-ApiToolsHospitalDb `
  -ConnectionString "Server=localhost;Trusted_Connection=True;" `
  -DatabaseName "Hospital_db"

# Automated mode - PostgreSQL
New-ApiToolsHospitalDb `
  -ConnectionString "Server=localhost;Port=5432;Database=postgres;User Id=postgres;Password=secret" `
  -DatabaseName "hospital_db"
```

### Generate a Complete CRUD API

```powershell
# Interactive mode (recommended for first-time users)
New-ApiToolsCrudApi

# Automated mode - SQL Server
New-ApiToolsCrudApi `
  -ConnectionString "Server=localhost;Database=Hospital_db;Trusted_Connection=True;" `
  -ProjectName "HospitalAPI"

# Automated mode - PostgreSQL
New-ApiToolsCrudApi `
  -ConnectionString "Server=localhost;Port=5432;Database=hospital_db;User Id=postgres;Password=secret" `
  -ProjectName "HospitalAPI"

# Preview without creating (dry-run)
New-ApiToolsCrudApi `
  -ConnectionString "Server=localhost;Database=mydb;Trusted_Connection=True;" `
  -DryRun
```

## Features

### New-ApiToolsHospitalDb

Creates a sample "Hospital" database with realistic schema and seed data.

- ✅ **Dual Database Support** - SQL Server and PostgreSQL
- ✅ **Interactive Mode** - Helpful prompts and connection string examples
- ✅ **ODBC Auto-Discovery** - Automatically finds PostgreSQL ODBC drivers
- ✅ **Native Connectivity** - Uses System.Data.SqlClient and System.Data.Odbc
- ✅ **Force Rebuild** - Drop and recreate with `-Force` parameter
- ✅ **Dry-Run Mode** - Preview SQL script with `-DryRun`
- ✅ **ShouldProcess** - Safe execution with `-WhatIf` and `-Confirm`
- ✅ **Zero Dependencies** - No PowerShell modules required

**Sample Schema:**
- Doctors (with specialties)
- Patients (with contact info)
- Appointments (with status tracking)
- Departments (organizational structure)
- MedicalRecords (diagnosis and treatment)

### New-ApiToolsCrudApi

Generates a complete ASP.NET Core Web API with CRUD operations from an existing database.

- ✅ **Auto-Detection** - Detects SQL Server or PostgreSQL automatically
- ✅ **EF Core Scaffolding** - Generates DbContext and entity models
- ✅ **Controller Generation** - Full CRUD endpoints for every table
- ✅ **Swagger Integration** - API documentation out of the box
- ✅ **Auto-Configuration** - Program.cs and appsettings.json setup
- ✅ **Connection Validation** - Tests database connectivity before generation
- ✅ **Conflict Resolution** - Handles project naming conflicts automatically
- ✅ **Force Overwrite** - Replace existing projects with `-Force`
- ✅ **Dry-Run Preview** - See execution plan with `-DryRun`
- ✅ **Native .NET** - No external PowerShell dependencies

**Generated Structure:**
```
MyAPI/
├── Controllers/       # CRUD API controllers
├── Models/           # EF Core entities and DbContext
├── Properties/       # Launch settings
├── Program.cs        # Configured entry point
├── appsettings.json  # Connection string configured
└── *.csproj          # Ready to build
```

## Requirements

### Manual Installation Required

1. **PowerShell 7.0 or higher** - [Download here](https://github.com/PowerShell/PowerShell/releases)
2. **.NET SDK 6.0 or higher** - [Download here](https://dotnet.microsoft.com/download)

### For CRUD API Generation

Install these .NET global tools (one-time setup):

```powershell
# Entity Framework Core Tools
dotnet tool install --global dotnet-ef

# ASP.NET Core Code Generator
dotnet tool install --global dotnet-aspnet-codegenerator
```

The module automatically validates these tools and provides installation instructions if missing.

### For PostgreSQL Support

- **PostgreSQL ODBC Driver** (Windows) - [Download here](https://www.postgresql.org/ftp/odbc/versions/)
  - The module automatically discovers installed drivers
  - Linux/macOS: Use native package managers (`apt`, `yum`, `brew`)

## Connection String Examples

### SQL Server

| Authentication | Example |
|---------------|---------|
| Windows Auth | `Server=localhost;Database=mydb;Trusted_Connection=True;` |
| Windows Auth (Named Instance) | `Server=localhost\SQLEXPRESS;Database=mydb;Trusted_Connection=True;` |
| SQL Auth | `Server=localhost;Database=mydb;User Id=sa;Password=YourPassword123;` |
| SQL Auth (Named Instance) | `Server=myserver\INSTANCE01;Database=mydb;User Id=sa;Password=YourPassword123;` |

### PostgreSQL

| Scenario | Example |
|----------|---------|
| Local Default Port | `Server=localhost;Port=5432;Database=mydb;User Id=postgres;Password=secret` |
| Custom Port | `Server=localhost;Port=5433;Database=mydb;User Id=postgres;Password=secret` |
| Remote Server | `Server=192.168.1.100;Port=5432;Database=mydb;User Id=myuser;Password=secret` |
| With SSL | `Server=hostname;Port=5432;Database=mydb;User Id=user;Password=secret;SSL Mode=Require` |

## Examples

### Example 1: Complete Workflow

```powershell
# Step 1: Create a sample database
New-ApiToolsHospitalDb `
  -ConnectionString "Server=localhost;Trusted_Connection=True;" `
  -DatabaseName "Hospital_db"

# Step 2: Generate CRUD API from the database
New-ApiToolsCrudApi `
  -ConnectionString "Server=localhost;Database=Hospital_db;Trusted_Connection=True;" `
  -ProjectName "HospitalAPI"

# Step 3: Run the API
cd HospitalAPI
dotnet run

# Step 4: Open Swagger UI in browser
# Navigate to: https://localhost:7xxx/swagger
```

### Example 2: PostgreSQL Workflow

```powershell
# Create PostgreSQL database
New-ApiToolsHospitalDb `
  -ConnectionString "Server=localhost;Port=5432;Database=postgres;User Id=postgres;Password=secret" `
  -DatabaseName "hospital_db"

# Generate API
New-ApiToolsCrudApi `
  -ConnectionString "Server=localhost;Port=5432;Database=hospital_db;User Id=postgres;Password=secret"

# Module auto-names project: hospital_db_CRUD_API
```

### Example 3: Force Rebuild

```powershell
# Rebuild database (drops if exists)
New-ApiToolsHospitalDb `
  -ConnectionString "Server=localhost;Trusted_Connection=True;" `
  -DatabaseName "Hospital_db" `
  -Force

# Overwrite existing API project
New-ApiToolsCrudApi `
  -ConnectionString "Server=localhost;Database=Hospital_db;Trusted_Connection=True;" `
  -ProjectName "HospitalAPI" `
  -Force
```

### Example 4: Dry-Run Testing

```powershell
# Preview database creation
New-ApiToolsHospitalDb `
  -ConnectionString "Server=localhost;Trusted_Connection=True;" `
  -DatabaseName "Hospital_db" `
  -DryRun

# Preview API generation
New-ApiToolsCrudApi `
  -ConnectionString "Server=localhost;Database=Hospital_db;Trusted_Connection=True;" `
  -DryRun
```

## Command Reference

### New-ApiToolsHospitalDb

Creates a sample Hospital database with seed data.

```powershell
New-ApiToolsHospitalDb 
    [-ConnectionString <string>]
    [-DatabaseName <string>]
    [-Force]
    [-DryRun]
    [-WhatIf]
    [-Confirm]
```

**Returns:** PSCustomObject with Action, Engine, Database, Schema, and Created properties.

### New-ApiToolsCrudApi

Generates a complete ASP.NET Core Web API with CRUD operations.

```powershell
New-ApiToolsCrudApi 
    [-ConnectionString <string>]
    [-ProjectName <string>]
    [-OutputPath <string>]
    [-Force]
    [-DryRun]
    [-WhatIf]
    [-Confirm]
```

**Returns:** PSCustomObject with Action, Engine, Database, ProjectName, ProjectPath, ModelsGenerated, ControllersGenerated, and Created properties.

## Troubleshooting

### "No PostgreSQL ODBC driver found"

**Windows:**
1. Download psqlODBC (x64) from https://www.postgresql.org/ftp/odbc/versions/
2. Install the driver
3. Restart PowerShell and try again

**Linux (Ubuntu/Debian):**
```bash
sudo apt-get install odbc-postgresql
```

**Linux (RHEL/CentOS):**
```bash
sudo yum install postgresql-odbc
```

**macOS:**
```bash
brew install psqlodbc
```

### "dotnet-ef tool not found"

Install Entity Framework Core Tools:
```powershell
dotnet tool install --global dotnet-ef
```

Verify installation:
```powershell
dotnet ef --version
```

### "dotnet-aspnet-codegenerator tool not found"

Install ASP.NET Core Code Generator:
```powershell
dotnet tool install --global dotnet-aspnet-codegenerator
```

Verify installation:
```powershell
dotnet aspnet-codegenerator --help
```

### "Connection validation failed"

**Check your connection string:**
- SQL Server: Ensure server name and authentication are correct
- PostgreSQL: Ensure port number (default 5432) is included
- Test connectivity with native tools (ssms, psql) first

**Common fixes:**
- SQL Server: Add `TrustServerCertificate=true;Encrypt=false`
- PostgreSQL: Ensure ODBC driver is installed
- Both: Check firewall rules and server is running

### Generated API doesn't build

If the generated project has build errors:

```powershell
# Navigate to project directory
cd path/to/YourAPI

# Restore packages
dotnet restore

# Build
dotnet build

# If still failing, check for:
# - Missing NuGet packages
# - .NET SDK version compatibility
# - EF Core provider version mismatches
```

## Design Philosophy

### Why No PowerShell Dependencies?

1. **Transparency** - Native .NET classes are well-documented and predictable
2. **Portability** - Works anywhere .NET works (Windows, Linux, macOS)
3. **Reliability** - No external module version conflicts
4. **Performance** - Direct database access without abstraction layers
5. **Learning** - Users see exactly how database connections work

### Inspired by dbatools

apitools follows the dbatools philosophy of providing:
- Powerful automation capabilities
- Intuitive PowerShell interface
- Comprehensive parameter sets
- Safe execution with -WhatIf/-Confirm
- Clear, helpful error messages
- Community-focused development

## Roadmap

Future enhancements planned:

- 🔄 Additional sample databases (Northwind, AdventureWorks-lite)
- 🔄 GraphQL API generation support
- 🔄 Minimal API generation (alternative to controllers)
- 🔄 Database migration management helpers
- 🔄 API testing helpers with sample requests
- 🔄 OpenAPI/Swagger customization options
- 🔄 Docker compose file generation
- 🔄 Authentication/Authorization scaffolding
- 🔄 API versioning support

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## Support

- **Issues**: Report bugs or request features on GitHub
- **Discussions**: Ask questions or share ideas in Discussions
- **Documentation**: See full command help with `Get-Help <CommandName> -Full`

## License

MIT License - see LICENSE file for details.

## Credits

**Inspired by:**
- **dbatools** - The gold standard for PowerShell database automation
  - Repository: https://github.com/dataplat/dbatools
  - Philosophy: Community-driven, comprehensive, and reliable

**Built with:**
- Native .NET Framework classes (System.Data.SqlClient, System.Data.Odbc)
- Entity Framework Core Tools (dotnet-ef)
- ASP.NET Core Code Generator (dotnet-aspnet-codegenerator)
- PowerShell 7.0+

---

**Made with ❤️ by Ruslan Dubas**

*Bringing the dbatools spirit to API development - powerful, transparent, and dependency-free!*