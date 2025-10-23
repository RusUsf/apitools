@{
    RootModule        = 'apitools.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '00000000-0000-4000-8000-000000000001'
    Author            = 'Ruslan Dubas'
    CompanyName       = 'Community'
    Copyright         = '(c) 2025 Ruslan Dubas'
    Description       = 'Dependency-free helpers for creating sample databases (SQL Server/PostgreSQL).'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('New-ApiToolsHospitalDb')
    CmdletsToExport   = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('database','sqlserver','postgres','sample-db','api') } }
}
