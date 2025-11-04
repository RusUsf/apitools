# ============================================================================
# apitools Demo Script - Database-First API Generation
# ============================================================================
# This demo shows:
# 1. Creating a database from scratch
# 2. Generating a complete .NET API in seconds
# 3. Handling database changes without losing custom code
# ============================================================================

# Press F8 to run each section line-by-line in VS Code

# ============================================================================
# PART 1: Setup - Import the module
# ============================================================================

Import-Module apitools

# ============================================================================
# PART 2: Create Sample Database
# Creates a Hospital database with 6 tables: Patients, Doctors, etc.
# ============================================================================

New-ApiToolsHospitalDb -ConnectionString "Server=localhost\dbatools;Database=master;Trusted_Connection=True;TrustServerCertificate=True" -DatabaseName "Hospital"

# Switch to SSMS now - refresh to see the new Hospital database and tables

# ============================================================================
# PART 3: Generate Complete API from Database
# One command creates Models, Controllers, and full CRUD operations
# ============================================================================

New-ApiToolsCrudApi -ConnectionString "Server=localhost\dbatools;Database=Hospital;Trusted_Connection=True;TrustServerCertificate=True" -ProjectName "HospitalAPI"

# This created a complete .NET API project with:
# - 6 Entity Models (Patient, Doctor, Examination, etc.)
# - 6 REST Controllers with full CRUD operations
# - DbContext with all entity configurations
# - Swagger documentation built-in

# Open the HospitalAPI folder in VS Code Explorer to see the generated files

# ============================================================================
# PART 4: Run the API
# Navigate to the project and start the web server
# ============================================================================

cd HospitalAPI
dotnet run

# Copy the localhost URL from the console output
# Open it in your browser with /swagger at the end
# Example: https://localhost:5152/swagger

# You'll see all 6 controllers with GET, POST, PUT, DELETE endpoints
# This is a fully working API - generated in under a minute

# Press Ctrl+C to stop the API when you're done exploring Swagger

# ============================================================================
# PART 5: The Real-World Problem - Database Schema Changes
# Switch to SSMS and run this SQL to add a new table
# ============================================================================

<#
Run this in SSMS:

USE Hospital;

CREATE TABLE Invoices (
    InvoiceId INT IDENTITY PRIMARY KEY,
    PatientId INT,
    Amount DECIMAL(10,2),
    InvoiceDate DATETIME DEFAULT GETDATE()
);
#>

# After running the SQL above, go back to Swagger and refresh
# Notice: There's no Invoices controller yet - the API is out of sync

# ============================================================================
# PART 6: Add Custom Code (The Developer's Dilemma)
# Open Models/HospitalContext.cs in VS Code
# Scroll to the OnModelCreating method
# Add this comment to simulate custom business logic:
# ============================================================================

<#
Add this inside OnModelCreating method in HospitalContext.cs:

// CUSTOM LOGIC - Don't lose this!
// modelBuilder.Entity<Patient>().HasIndex(p => p.Name);

Save the file.
#>

# This represents real custom code developers add to their projects
# Normally, re-scaffolding would DESTROY this custom code
# That's the problem apitools solves

# ============================================================================
# PART 7: Smart Update - Preserve Custom Code While Updating
# This command detects schema changes and regenerates only what's needed
# Your custom code in OnModelCreating will be preserved!
# ============================================================================

Update-ApiToolsFromDatabase -ProjectPath . -ConnectionString "Server=localhost\dbatools;Database=Hospital;Trusted_Connection=True;TrustServerCertificate=True" -RegenerateControllers

# Watch the output - it shows:
# - Models added: 1 (Invoice.cs)
# - Controllers created: 1 (InvoicesController.cs)
# - Custom OnModelCreating code: PRESERVED

# ============================================================================
# PART 8: Verify Custom Code Preserved
# Open Models/HospitalContext.cs again
# Scroll to OnModelCreating - your custom comment is still there!
# ============================================================================

# You'll see markers like:
# // <APITOOLS_CUSTOM_ONMODEL_START>
# // CUSTOM LOGIC - Don't lose this!
# // <APITOOLS_CUSTOM_ONMODEL_END>

# Your custom code is safely preserved and re-injected after generated mappings

# ============================================================================
# PART 9: Prove It Works - Run the Updated API
# ============================================================================

dotnet run

# Go back to browser, refresh Swagger
# You'll now see the new Invoices controller with all CRUD endpoints
# Your API is now in sync with the database - with zero manual work

# Expand the Invoices controller
# Click "Try it out" on GET /api/Invoices
# Execute - it works! (returns empty array since no data yet)

# ============================================================================
# Summary:
# Day 1: Generate complete API from database - 30 seconds
# Day 100: Update API when database changes - 15 seconds
# Result: Never lose custom code, never manually merge scaffolds
#
# Get apitools on PowerShell Gallery
# ============================================================================