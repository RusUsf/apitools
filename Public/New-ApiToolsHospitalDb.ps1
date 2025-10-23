<#
.SYNOPSIS
Creates a small "Hospital" sample database with plural tables on SQL Server or PostgreSQL.

.DESCRIPTION
New-ApiToolsHospitalDb connects to the engine, creates the target database if it does not exist, and then deploys a static ANSI-first schema with seed data. The command supports interactive mode (no parameters) with helpful connection string examples and automatic PostgreSQL ODBC driver discovery. SQL Server uses System.Data.SqlClient and runs CREATE DATABASE plus the schema batch (USE <db>; <DDL>) on the same connection. PostgreSQL transparently handles ODBC driver discovery and uses System.Data.Odbc, creates the database on the postgres catalog, then reconnects directly to the target database to apply the schema.

.PARAMETER ConnectionString
The server-level connection string. For SQL Server use Windows authentication like "Server=localhost;Trusted_Connection=True;" or SQL authentication like "Server=localhost;User Id=sa;Password=StrongPwd!". For PostgreSQL use native format like "Server=localhost;Port=5432;Database=postgres;User Id=postgres;Password=secret" (ODBC driver is auto-discovered). If omitted, interactive mode prompts with examples.

.PARAMETER DatabaseName
The database name to create and target. If omitted, the command tries to derive it from the connection string; if it cannot, it defaults to "hospital_db".

.PARAMETER Force
If supplied, the command drops the database if it exists and recreates it before deploying the schema. For SQL Server the database is set to SINGLE_USER with immediate rollback to ensure a clean drop. For PostgreSQL active backends are terminated for the named database before drop.

.PARAMETER DryRun
When present, the command prints a small plan object along with the exact SQL script that would be executed and performs no changes.

.EXAMPLE
# Interactive mode with examples
PS> New-ApiToolsHospitalDb
Prompts for connection string with SQL Server and PostgreSQL examples, auto-discovers PostgreSQL ODBC driver.

.EXAMPLE
# Create a SQL Server database using Windows authentication
PS> New-ApiToolsHospitalDb -ConnectionString "Server=localhost;Trusted_Connection=True;" -DatabaseName "Hospital_db"
Creates Hospital_db on the local SQL Server instance using Windows authentication, then deploys the Hospital schema and seed data.

.EXAMPLE
# Force rebuild a SQL Server database using SQL authentication
PS> New-ApiToolsHospitalDb -ConnectionString "Server=localhost;User Id=sa;Password=StrongPwd!" -DatabaseName "Hospital_db" -Force
Drops and recreates Hospital_db on SQL Server using SQL authentication, then redeploys the complete schema and seed rows. Use -Force when you need a clean slate.

.EXAMPLE
# Create a PostgreSQL database using native connection string (ODBC driver auto-discovered)
PS> New-ApiToolsHospitalDb -ConnectionString "Server=localhost;Port=5432;Database=postgres;User Id=postgres;Password=Secret123!" -DatabaseName "hospital_db"
Automatically discovers the 64-bit PostgreSQL Unicode ODBC driver, converts to ODBC format internally, and creates hospital_db with the Hospital schema and seed data.

.EXAMPLE
# Force rebuild a PostgreSQL database with dry-run preview
PS> New-ApiToolsHospitalDb -ConnectionString "Server=localhost;Port=5432;Database=postgres;User Id=postgres;Password=Secret123!" -DatabaseName "hospital_db" -Force -DryRun
Shows the execution plan without making changes. Remove -DryRun to drop, recreate, and redeploy hospital_db on PostgreSQL.

.INPUTS
None. You pipe nothing to this command.

.OUTPUTS
A small PSCustomObject summary with Action, Engine, Database, Schema, and Created fields when execution succeeds. In -DryRun mode the function writes a plan object and the SQL text.

.NOTES
Author: Your Name
Module: apitools
This command is intentionally dependency-free and embeds the SQL directly, so it can run anywhere PowerShell can reach the database engine. PostgreSQL ODBC driver discovery is automatic - users provide native connection strings.
#>

function New-ApiToolsHospitalDb {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConnectionString,
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
        if ($params.ContainsKey('Search Path')) {
            $odbcParts += "SearchPath=$($params['Search Path'])"
        }

        return ($odbcParts -join ';')
    }

    # =========================================================================
    # INTERACTIVE MODE: Prompt for connection string if not provided
    # =========================================================================
    if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
        Write-Host ""
        Write-Host "=== DATABASE CONNECTION SETUP ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Enter your database connection string:" -ForegroundColor White
        Write-Host ""
        Write-Host "PostgreSQL Examples:" -ForegroundColor Yellow
        Write-Host "  Server=localhost;Port=5432;Database=postgres;User Id=postgres;Password=yourpassword" -ForegroundColor Gray
        Write-Host "  Server=localhost;Port=5432;Database=postgres;User Id=postgres;Password=yourpassword;Search Path=public" -ForegroundColor Gray
        Write-Host "  Server=hostname;Port=5432;Database=postgres;User Id=postgres;Password=yourpassword;SSL Mode=Require" -ForegroundColor Gray
        Write-Host ""
        Write-Host "SQL Server Examples:" -ForegroundColor Yellow
        Write-Host "  Server=localhost;Database=master;Trusted_Connection=true" -ForegroundColor Gray
        Write-Host "  Server=localhost;Database=master;User Id=sa;Password=yourpassword" -ForegroundColor Gray
        Write-Host ""
        
        $ConnectionString = Read-Host "Connection String"
        
        if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
            throw "Connection string is required. Run the command again or provide -ConnectionString parameter."
        }
        
        Write-Host ""
    }

    # =========================================================================
    # STEP 1: Detect engine and convert PostgreSQL to ODBC if needed
    # =========================================================================
    $engine = $null
    $isPostgreSqlNative = $false
    
    # Detect PostgreSQL (native or ODBC format)
    if ($ConnectionString -match '(?i)(Host=|Username=|Port\s*=\s*5432|Postgres|Npgsql|Driver=.*PostgreSQL)') {
        $engine = 'PostgreSql'
        $isPostgreSqlNative = ($ConnectionString -notmatch '(?i)Driver\s*=')
    }
    # Detect SQL Server
    elseif ($ConnectionString -match '(?i)(Server=|Data Source=|Trusted_Connection=|Initial Catalog=|Encrypt=)') {
        $engine = 'SqlServer'
    }
    else {
        throw "Unable to detect database engine from connection string. Ensure it matches the examples shown."
    }

    # Convert PostgreSQL native to ODBC
    if ($engine -eq 'PostgreSql' -and $isPostgreSqlNative) {
        Write-Verbose "Converting PostgreSQL native connection string to ODBC format..."
        $ConnectionString = ConvertTo-PostgreSqlOdbc -NativeConnectionString $ConnectionString
        Write-Verbose "ODBC connection string: $ConnectionString"
    }

    # =========================================================================
    # STEP 2: Extract database name and build server-level connection
    # =========================================================================
    if (-not $DatabaseName) {
        $DatabaseName = ($ConnectionString -split ';' | ForEach-Object {
                $kv = $_.Trim()
                if ($kv -match '^(?i)(Database|Initial Catalog)\s*=\s*(.+)$') { $Matches[2].Trim() }
            } | Select-Object -First 1)
        if (-not $DatabaseName) { $DatabaseName = 'hospital_db' }
    }

    # Validate database name (basic SQL identifier check)
    if ($DatabaseName -notmatch '^[a-zA-Z_][a-zA-Z0-9_]*$') {
        Write-Warning "Database name '$DatabaseName' contains special characters. This may cause issues."
    }

    $serverConn = $null
    if ($engine -eq 'SqlServer') {
        $parts = @()
        foreach ($part in ($ConnectionString -split ';')) {
            $p = $part.Trim()
            if ($p -and $p -notmatch '^(?i)(Database|Initial Catalog)\s*=') { $parts += $p }
        }
        $serverConn = ($parts + 'Initial Catalog=master') -join ';'
    }
    else {
        $parts = @()
        $hadDb = $false
        foreach ($part in ($ConnectionString -split ';')) {
            $p = $part.Trim()
            if (-not $p) { continue }
            if ($p -match '^(?i)(Database|Initial Catalog)\s*=') { 
                $parts += 'Database=postgres'
                $hadDb = $true 
            }
            else { $parts += $p }
        }
        if (-not $hadDb) { $parts += 'Database=postgres' }
        $serverConn = $parts -join ';'
    }

    # =========================================================================
    # STEP 3: Define static DDL per engine
    # =========================================================================
    $ddl = $null
    if ($engine -eq 'SqlServer') {
        $ddl = @'
-- SQL Server: Hospital schema (plural) ---------------------------------------
/* drop in FK-safe order */
IF OBJECT_ID(N'[dbo].[invoice_items]', N'U')      IS NOT NULL DROP TABLE [dbo].[invoice_items];
IF OBJECT_ID(N'[dbo].[invoices]', N'U')           IS NOT NULL DROP TABLE [dbo].[invoices];
IF OBJECT_ID(N'[dbo].[prescription_items]', N'U') IS NOT NULL DROP TABLE [dbo].[prescription_items];
IF OBJECT_ID(N'[dbo].[prescriptions]', N'U')      IS NOT NULL DROP TABLE [dbo].[prescriptions];
IF OBJECT_ID(N'[dbo].[admissions]', N'U')         IS NOT NULL DROP TABLE [dbo].[admissions];
IF OBJECT_ID(N'[dbo].[appointments]', N'U')       IS NOT NULL DROP TABLE [dbo].[appointments];
IF OBJECT_ID(N'[dbo].[medications]', N'U')        IS NOT NULL DROP TABLE [dbo].[medications];
IF OBJECT_ID(N'[dbo].[rooms]', N'U')              IS NOT NULL DROP TABLE [dbo].[rooms];
IF OBJECT_ID(N'[dbo].[doctors]', N'U')            IS NOT NULL DROP TABLE [dbo].[doctors];
IF OBJECT_ID(N'[dbo].[departments]', N'U')        IS NOT NULL DROP TABLE [dbo].[departments];
IF OBJECT_ID(N'[dbo].[patients]', N'U')           IS NOT NULL DROP TABLE [dbo].[patients];

/* core reference tables */
CREATE TABLE [dbo].[departments] (
    [department_id] INT IDENTITY(1,1) PRIMARY KEY,
    [name]          VARCHAR(100) NOT NULL UNIQUE,
    [created_at]    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE [dbo].[patients] (
    [patient_id]        INT IDENTITY(1,1) PRIMARY KEY,
    [medical_record_no] VARCHAR(32) NOT NULL UNIQUE,
    [first_name]        VARCHAR(80) NOT NULL,
    [last_name]         VARCHAR(80) NOT NULL,
    [date_of_birth]     DATE NOT NULL,
    [sex]               VARCHAR(10) NULL,
    [phone]             VARCHAR(30) NULL,
    [active]            BIT NOT NULL DEFAULT 1,
    [created_at]        DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    [updated_at]        DATETIME2 NULL
);

CREATE TABLE [dbo].[doctors] (
    [doctor_id]   INT IDENTITY(1,1) PRIMARY KEY,
    [license_no]  VARCHAR(32) NOT NULL UNIQUE,
    [first_name]  VARCHAR(80) NOT NULL,
    [last_name]   VARCHAR(80) NOT NULL,
    [department_id] INT NULL,
    [created_at]  DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    [updated_at]  DATETIME2 NULL,
    CONSTRAINT [fk_doctors_department] FOREIGN KEY ([department_id]) REFERENCES [dbo].[departments]([department_id])
);

CREATE TABLE [dbo].[rooms] (
    [room_id]     INT IDENTITY(1,1) PRIMARY KEY,
    [room_number] VARCHAR(20) NOT NULL,
    [ward]        VARCHAR(50) NULL,
    [capacity]    INT NOT NULL DEFAULT 1,
    CONSTRAINT [uq_rooms_room_number] UNIQUE ([room_number])
);

/* operational tables */
CREATE TABLE [dbo].[appointments] (
    [appointment_id] INT IDENTITY(1,1) PRIMARY KEY,
    [patient_id]     INT NOT NULL,
    [doctor_id]      INT NOT NULL,
    [scheduled_at]   DATETIME2 NOT NULL,
    [status]         VARCHAR(20) NOT NULL,
    [notes]          NVARCHAR(MAX) NULL,
    CONSTRAINT [uq_appointments_patient_time] UNIQUE ([patient_id], [scheduled_at]),
    CONSTRAINT [ck_appointments_status] CHECK ([status] IN ('scheduled','completed','cancelled')),
    CONSTRAINT [fk_appointments_patient] FOREIGN KEY ([patient_id]) REFERENCES [dbo].[patients]([patient_id]),
    CONSTRAINT [fk_appointments_doctor]  FOREIGN KEY ([doctor_id])  REFERENCES [dbo].[doctors]([doctor_id])
);

CREATE TABLE [dbo].[admissions] (
    [admission_id] INT IDENTITY(1,1) PRIMARY KEY,
    [patient_id]   INT NOT NULL,
    [room_id]      INT NOT NULL,
    [admitted_at]  DATETIME2 NOT NULL,
    [discharged_at] DATETIME2 NULL,
    [diagnosis]    NVARCHAR(MAX) NULL,
    CONSTRAINT [fk_admissions_patient] FOREIGN KEY ([patient_id]) REFERENCES [dbo].[patients]([patient_id]),
    CONSTRAINT [fk_admissions_room]    FOREIGN KEY ([room_id])    REFERENCES [dbo].[rooms]([room_id])
);

CREATE TABLE [dbo].[medications] (
    [medication_id] INT IDENTITY(1,1) PRIMARY KEY,
    [name]          VARCHAR(200) NOT NULL UNIQUE,
    [dose_form]     VARCHAR(50) NULL
);

CREATE TABLE [dbo].[prescriptions] (
    [prescription_id] INT IDENTITY(1,1) PRIMARY KEY,
    [patient_id]      INT NOT NULL,
    [doctor_id]       INT NOT NULL,
    [prescribed_at]   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    [notes]           NVARCHAR(MAX) NULL,
    CONSTRAINT [fk_prescriptions_patient] FOREIGN KEY ([patient_id]) REFERENCES [dbo].[patients]([patient_id]),
    CONSTRAINT [fk_prescriptions_doctor]  FOREIGN KEY ([doctor_id])  REFERENCES [dbo].[doctors]([doctor_id])
);

CREATE TABLE [dbo].[prescription_items] (
    [prescription_item_id] INT IDENTITY(1,1) PRIMARY KEY,
    [prescription_id]      INT NOT NULL,
    [medication_id]        INT NOT NULL,
    [dosage]               VARCHAR(50) NOT NULL,
    [frequency]            VARCHAR(50) NOT NULL,
    [duration_days]        INT NULL,
    CONSTRAINT [fk_prescription_items_prescription] FOREIGN KEY ([prescription_id]) REFERENCES [dbo].[prescriptions]([prescription_id]),
    CONSTRAINT [fk_prescription_items_medication]   FOREIGN KEY ([medication_id])   REFERENCES [dbo].[medications]([medication_id])
);

CREATE TABLE [dbo].[invoices] (
    [invoice_id]   INT IDENTITY(1,1) PRIMARY KEY,
    [patient_id]   INT NOT NULL,
    [issued_at]    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    [total_amount] DECIMAL(10,2) NOT NULL,
    [status]       VARCHAR(20) NOT NULL,
    CONSTRAINT [ck_invoices_status] CHECK ([status] IN ('open','paid','cancelled')),
    CONSTRAINT [fk_invoices_patient] FOREIGN KEY ([patient_id]) REFERENCES [dbo].[patients]([patient_id])
);

CREATE TABLE [dbo].[invoice_items] (
    [invoice_item_id] INT IDENTITY(1,1) PRIMARY KEY,
    [invoice_id]      INT NOT NULL,
    [description]     VARCHAR(200) NOT NULL,
    [amount]          DECIMAL(10,2) NOT NULL,
    CONSTRAINT [fk_invoice_items_invoice] FOREIGN KEY ([invoice_id]) REFERENCES [dbo].[invoices]([invoice_id])
);

/* seed */
INSERT INTO [dbo].[departments](name) VALUES ('General Medicine'),('Pediatrics'),('Cardiology');
INSERT INTO [dbo].[patients](medical_record_no,first_name,last_name,date_of_birth,sex,phone,active) VALUES
('MRN-1001','Ada','Lovelace','1815-12-10','F','555-0101',1),
('MRN-1002','Alan','Turing','1912-06-23','M','555-0102',1);
INSERT INTO [dbo].[doctors](license_no,first_name,last_name,department_id)
SELECT 'LIC-2001','Florence','Nightingale', d.department_id FROM [dbo].[departments] d WHERE d.name='General Medicine';
INSERT INTO [dbo].[rooms](room_number,ward,capacity) VALUES ('101A','North',1);
INSERT INTO [dbo].[medications](name,dose_form) VALUES ('Amoxicillin','tablet');
INSERT INTO [dbo].[appointments](patient_id,doctor_id,scheduled_at,status,notes)
SELECT p.patient_id, d.doctor_id, DATEADD(day,1,SYSUTCDATETIME()), 'scheduled', 'Initial consult'
FROM [dbo].[patients] p CROSS APPLY (SELECT TOP 1 doctor_id FROM [dbo].[doctors]) d
WHERE p.medical_record_no='MRN-1001';
INSERT INTO [dbo].[prescriptions](patient_id,doctor_id,prescribed_at,notes)
SELECT p.patient_id, d.doctor_id, SYSUTCDATETIME(), 'Standard course'
FROM [dbo].[patients] p CROSS APPLY (SELECT TOP 1 doctor_id FROM [dbo].[doctors]) d
WHERE p.medical_record_no='MRN-1001';
INSERT INTO [dbo].[prescription_items](prescription_id,medication_id,dosage,frequency,duration_days)
SELECT TOP 1 pr.prescription_id, m.medication_id, '500 mg','BID',7
FROM [dbo].[prescriptions] pr CROSS JOIN [dbo].[medications] m
ORDER BY pr.prescription_id DESC;
INSERT INTO [dbo].[invoices](patient_id,issued_at,total_amount,status)
SELECT p.patient_id, SYSUTCDATETIME(), 150.00, 'open' FROM [dbo].[patients] p WHERE p.medical_record_no='MRN-1001';
INSERT INTO [dbo].[invoice_items](invoice_id,description,amount)
SELECT TOP 1 i.invoice_id, 'Consultation', 150.00 FROM [dbo].[invoices] i ORDER BY i.invoice_id DESC;
'@
    }
    else {
        $ddl = @'
-- PostgreSQL: Hospital schema (plural) ---------------------------------------
/* drop in FK-safe order */
DROP TABLE IF EXISTS "public"."invoice_items" CASCADE;
DROP TABLE IF EXISTS "public"."invoices" CASCADE;
DROP TABLE IF EXISTS "public"."prescription_items" CASCADE;
DROP TABLE IF EXISTS "public"."prescriptions" CASCADE;
DROP TABLE IF EXISTS "public"."admissions" CASCADE;
DROP TABLE IF EXISTS "public"."appointments" CASCADE;
DROP TABLE IF EXISTS "public"."medications" CASCADE;
DROP TABLE IF EXISTS "public"."rooms" CASCADE;
DROP TABLE IF EXISTS "public"."doctors" CASCADE;
DROP TABLE IF EXISTS "public"."departments" CASCADE;
DROP TABLE IF EXISTS "public"."patients" CASCADE;

/* core reference tables */
CREATE TABLE "public"."departments" (
    department_id SERIAL PRIMARY KEY,
    name          VARCHAR(100) NOT NULL UNIQUE,
    created_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE "public"."patients" (
    patient_id        SERIAL PRIMARY KEY,
    medical_record_no VARCHAR(32) NOT NULL UNIQUE,
    first_name        VARCHAR(80) NOT NULL,
    last_name         VARCHAR(80) NOT NULL,
    date_of_birth     DATE NOT NULL,
    sex               VARCHAR(10) NULL,
    phone             VARCHAR(30) NULL,
    active            BOOLEAN NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMP NULL
);

CREATE TABLE "public"."doctors" (
    doctor_id     SERIAL PRIMARY KEY,
    license_no    VARCHAR(32) NOT NULL UNIQUE,
    first_name    VARCHAR(80) NOT NULL,
    last_name     VARCHAR(80) NOT NULL,
    department_id INT NULL,
    created_at    TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMP NULL,
    CONSTRAINT fk_doctors_department FOREIGN KEY (department_id) REFERENCES "public"."departments"(department_id)
);

CREATE TABLE "public"."rooms" (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(20) NOT NULL UNIQUE,
    ward        VARCHAR(50) NULL,
    capacity    INT NOT NULL DEFAULT 1
);

/* operational tables */
CREATE TABLE "public"."appointments" (
    appointment_id SERIAL PRIMARY KEY,
    patient_id     INT NOT NULL,
    doctor_id      INT NOT NULL,
    scheduled_at   TIMESTAMP NOT NULL,
    status         VARCHAR(20) NOT NULL CHECK (status IN ('scheduled','completed','cancelled')),
    notes          TEXT NULL,
    CONSTRAINT uq_appointments_patient_time UNIQUE (patient_id, scheduled_at),
    CONSTRAINT fk_appointments_patient FOREIGN KEY (patient_id) REFERENCES "public"."patients"(patient_id),
    CONSTRAINT fk_appointments_doctor  FOREIGN KEY (doctor_id)  REFERENCES "public"."doctors"(doctor_id)
);

CREATE TABLE "public"."admissions" (
    admission_id  SERIAL PRIMARY KEY,
    patient_id    INT NOT NULL,
    room_id       INT NOT NULL,
    admitted_at   TIMESTAMP NOT NULL,
    discharged_at TIMESTAMP NULL,
    diagnosis     TEXT NULL,
    CONSTRAINT fk_admissions_patient FOREIGN KEY (patient_id) REFERENCES "public"."patients"(patient_id),
    CONSTRAINT fk_admissions_room    FOREIGN KEY (room_id)    REFERENCES "public"."rooms"(room_id)
);

CREATE TABLE "public"."medications" (
    medication_id SERIAL PRIMARY KEY,
    name          VARCHAR(200) NOT NULL UNIQUE,
    dose_form     VARCHAR(50) NULL
);

CREATE TABLE "public"."prescriptions" (
    prescription_id SERIAL PRIMARY KEY,
    patient_id      INT NOT NULL,
    doctor_id       INT NOT NULL,
    prescribed_at   TIMESTAMP NOT NULL DEFAULT NOW(),
    notes           TEXT NULL,
    CONSTRAINT fk_prescriptions_patient FOREIGN KEY (patient_id) REFERENCES "public"."patients"(patient_id),
    CONSTRAINT fk_prescriptions_doctor  FOREIGN KEY (doctor_id)  REFERENCES "public"."doctors"(doctor_id)
);

CREATE TABLE "public"."prescription_items" (
    prescription_item_id SERIAL PRIMARY KEY,
    prescription_id      INT NOT NULL,
    medication_id        INT NOT NULL,
    dosage               VARCHAR(50) NOT NULL,
    frequency            VARCHAR(50) NOT NULL,
    duration_days        INT NULL,
    CONSTRAINT fk_prescription_items_prescription FOREIGN KEY (prescription_id) REFERENCES "public"."prescriptions"(prescription_id),
    CONSTRAINT fk_prescription_items_medication   FOREIGN KEY (medication_id)   REFERENCES "public"."medications"(medication_id)
);

CREATE TABLE "public"."invoices" (
    invoice_id   SERIAL PRIMARY KEY,
    patient_id   INT NOT NULL,
    issued_at    TIMESTAMP NOT NULL DEFAULT NOW(),
    total_amount DECIMAL(10,2) NOT NULL,
    status       VARCHAR(20) NOT NULL CHECK (status IN ('open','paid','cancelled')),
    CONSTRAINT fk_invoices_patient FOREIGN KEY (patient_id) REFERENCES "public"."patients"(patient_id)
);

CREATE TABLE "public"."invoice_items" (
    invoice_item_id SERIAL PRIMARY KEY,
    invoice_id      INT NOT NULL,
    description     VARCHAR(200) NOT NULL,
    amount          DECIMAL(10,2) NOT NULL,
    CONSTRAINT fk_invoice_items_invoice FOREIGN KEY (invoice_id) REFERENCES "public"."invoices"(invoice_id)
);

/* seed */
INSERT INTO "public"."departments"(name) VALUES ('General Medicine'),('Pediatrics'),('Cardiology')
ON CONFLICT (name) DO NOTHING;

INSERT INTO "public"."patients"(medical_record_no,first_name,last_name,date_of_birth,sex,phone,active) VALUES
('MRN-1001','Ada','Lovelace','1815-12-10','F','555-0101',TRUE)
ON CONFLICT (medical_record_no) DO NOTHING;

INSERT INTO "public"."patients"(medical_record_no,first_name,last_name,date_of_birth,sex,phone,active) VALUES
('MRN-1002','Alan','Turing','1912-06-23','M','555-0102',TRUE)
ON CONFLICT (medical_record_no) DO NOTHING;

INSERT INTO "public"."doctors"(license_no,first_name,last_name,department_id)
SELECT 'LIC-2001','Florence','Nightingale', d.department_id
FROM "public"."departments" d WHERE d.name='General Medicine'
ON CONFLICT (license_no) DO NOTHING;

INSERT INTO "public"."rooms"(room_number,ward,capacity) VALUES ('101A','North',1)
ON CONFLICT (room_number) DO NOTHING;

INSERT INTO "public"."medications"(name,dose_form) VALUES ('Amoxicillin','tablet')
ON CONFLICT (name) DO NOTHING;

INSERT INTO "public"."appointments"(patient_id,doctor_id,scheduled_at,status,notes)
SELECT p.patient_id, d.doctor_id, NOW() + INTERVAL '1 day', 'scheduled', 'Initial consult'
FROM "public"."patients" p CROSS JOIN LATERAL (SELECT doctor_id FROM "public"."doctors" LIMIT 1) d
WHERE p.medical_record_no='MRN-1001';

INSERT INTO "public"."prescriptions"(patient_id,doctor_id,prescribed_at,notes)
SELECT p.patient_id, d.doctor_id, NOW(), 'Standard course'
FROM "public"."patients" p CROSS JOIN LATERAL (SELECT doctor_id FROM "public"."doctors" LIMIT 1) d
WHERE p.medical_record_no='MRN-1001';

INSERT INTO "public"."prescription_items"(prescription_id,medication_id,dosage,frequency,duration_days)
SELECT pr.prescription_id, m.medication_id, '500 mg','BID',7
FROM "public"."prescriptions" pr CROSS JOIN "public"."medications" m
ORDER BY pr.prescription_id DESC LIMIT 1;

INSERT INTO "public"."invoices"(patient_id,issued_at,total_amount,status)
SELECT p.patient_id, NOW(), 150.00, 'open'
FROM "public"."patients" p WHERE p.medical_record_no='MRN-1001';

INSERT INTO "public"."invoice_items"(invoice_id,description,amount)
SELECT i.invoice_id, 'Consultation', 150.00
FROM "public"."invoices" i ORDER BY i.invoice_id DESC LIMIT 1;
'@
    }

    # =========================================================================
    # STEP 4: DryRun mode - show plan and exit
    # =========================================================================
    if ($DryRun) {
        Write-Host ""
        Write-Host "=== DRY RUN MODE ===" -ForegroundColor Cyan
        Write-Host ""
        [pscustomobject]@{
            Engine   = $engine
            Database = $DatabaseName
            Plan     = if ($engine -eq 'SqlServer') { 
                'SQL Server: one connection (USE+DDL)' 
            } else { 
                'PostgreSQL: server hop then DB hop (ODBC)' 
            }
            Server   = $serverConn
        }
        Write-Host ""
        Write-Host "=== SQL SCRIPT TO BE EXECUTED ===" -ForegroundColor Yellow
        Write-Host $ddl -ForegroundColor Gray
        return
    }

    # =========================================================================
    # STEP 5: Execute database creation and schema deployment
    # =========================================================================
    if ($PSCmdlet.ShouldProcess("$engine::$DatabaseName", "Create Hospital sample database")) {

        if ($engine -eq 'SqlServer') {
            # SQL Server implementation
            $conn = $null
            try {
                $conn = New-Object System.Data.SqlClient.SqlConnection $serverConn
                $conn.Open()

                # Force drop (single-user, immediate rollback)
                if ($Force) {
                    $cmd = $conn.CreateCommand()
                    $safeDbName = $DatabaseName -replace "'", "''"
                    $cmd.CommandText = @"
IF DB_ID(N'$safeDbName') IS NOT NULL
BEGIN
    ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$DatabaseName];
END
"@
                    [void]$cmd.ExecuteNonQuery()
                    Write-Verbose "Dropped existing database: $DatabaseName"
                }

                # Always attempt a guarded CREATE
                $cmd = $conn.CreateCommand()
                $safeDbName = $DatabaseName -replace "'", "''"
                $cmd.CommandText = @"
IF DB_ID(N'$safeDbName') IS NULL
    CREATE DATABASE [$DatabaseName];
"@
                [void]$cmd.ExecuteNonQuery()
                Write-Verbose "Created database: $DatabaseName"

                # Wait until ONLINE (defensive, avoids timing races)
                $cmd = $conn.CreateCommand()
                $safeDbName = $DatabaseName -replace "'", "''"
                $cmd.CommandText = @"
DECLARE @i int=0, @s nvarchar(60);
WHILE 1=1
BEGIN
    SELECT @s = state_desc FROM sys.databases WHERE name = N'$safeDbName';
    IF (@s = 'ONLINE') BREAK;
    IF (@i >= 20) BREAK;
    WAITFOR DELAY '00:00:00.5';
    SET @i += 1;
END
"@
                [void]$cmd.ExecuteNonQuery()

                # Final guard: if still missing, error out clearly
                $cmd = $conn.CreateCommand()
                $safeDbName = $DatabaseName -replace "'", "''"
                $cmd.CommandText = "IF DB_ID(N'$safeDbName') IS NULL RAISERROR('Database ``$safeDbName`` was not created.',16,1);"
                [void]$cmd.ExecuteNonQuery()

                # Run schema on the SAME connection
                $cmd = $conn.CreateCommand()
                $cmd.CommandTimeout = 0
                $cmd.CommandText = "USE [$DatabaseName];`r`n$ddl"
                [void]$cmd.ExecuteNonQuery()
                Write-Verbose "Deployed Hospital schema to: $DatabaseName"
            }
            catch {
                throw "SQL Server error: $($_.Exception.Message)"
            }
            finally {
                if ($conn) { $conn.Close() }
            }
        }
        else {
            # PostgreSQL implementation (ODBC)
            Add-Type -AssemblyName System.Data
            $odbcSrv = $null
            $odbcDb = $null
            
            try {
                # Server-level connection (postgres catalog)
                $odbcSrv = New-Object System.Data.Odbc.OdbcConnection $serverConn
                $odbcSrv.Open()

                $cmd = $odbcSrv.CreateCommand()
                
                # Force drop (terminate backends and drop)
                if ($Force) {
                    $safeDbName = $DatabaseName -replace "'", "''"
                    $cmd.CommandText = @"
DO `$`$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_database WHERE datname = '$safeDbName') THEN
        PERFORM pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$safeDbName' AND pid <> pg_backend_pid();
        EXECUTE 'DROP DATABASE "' || replace('$safeDbName','""','""""') || '"';
    END IF;
END `$`$;
"@
                    [void]$cmd.ExecuteNonQuery()
                    Write-Verbose "Dropped existing database: $DatabaseName"
                }
                
                # Check if database exists
                $safeDbName = $DatabaseName -replace "'", "''"
                $cmd.CommandText = "SELECT 1 FROM pg_database WHERE datname='$safeDbName';"
                $exists = $cmd.ExecuteScalar()
                
                if (-not $exists) {
                    $cmd.CommandText = 'CREATE DATABASE "' + ($DatabaseName -replace '"', '""') + '";'
                    [void]$cmd.ExecuteNonQuery()
                    Write-Verbose "Created database: $DatabaseName"
                }
                
                $odbcSrv.Close()

                # Second hop: connect to target database and apply DDL
                $targetConn = ($ConnectionString -split ';' | ForEach-Object {
                        $p = $_.Trim()
                        if ($p -match '^(?i)(Database|Initial Catalog)\s*=') { 
                            "Database=$DatabaseName" 
                        } 
                        elseif ($p) { $p }
                    }) -join ';'
                
                $odbcDb = New-Object System.Data.Odbc.OdbcConnection $targetConn
                $odbcDb.Open()
                
                $cmd = $odbcDb.CreateCommand()
                $cmd.CommandText = $ddl
                $cmd.CommandTimeout = 0
                [void]$cmd.ExecuteNonQuery()
                Write-Verbose "Deployed Hospital schema to: $DatabaseName"
                
                $odbcDb.Close()
            }
            catch {
                throw "PostgreSQL error: $($_.Exception.Message)"
            }
            finally {
                if ($odbcSrv -and $odbcSrv.State -eq 'Open') { $odbcSrv.Close() }
                if ($odbcDb -and $odbcDb.State -eq 'Open') { $odbcDb.Close() }
            }
        }

        # Return success summary
        Write-Host ""
        Write-Host "✓ Database created successfully!" -ForegroundColor Green
        [pscustomobject]@{
            Action   = 'CreateSampleDb'
            Engine   = $engine
            Database = $DatabaseName
            Schema   = if ($engine -eq 'SqlServer') { 'dbo' } else { 'public' }
            Created  = $true
        }
    }
}