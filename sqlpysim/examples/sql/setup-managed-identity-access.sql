-- ============================================
-- SETUP MANAGED IDENTITY ACCESS FOR AZURE SQL
-- ============================================
-- 
-- This script grants access to Managed Identities so they can connect
-- to Azure SQL Database using sqlpysim with -A ActiveDirectoryMsi
--
-- NOTE: This script is for AZURE SQL DATABASE only.
--       For FABRIC SQL DATABASE, you must grant permissions through the
--       Fabric portal (Manage permissions > Share > Add your Managed Identity).
--       The CREATE USER FROM EXTERNAL PROVIDER syntax does NOT work in Fabric.
--
-- PREREQUISITES:
--   1. You must be connected as an Azure AD admin on the SQL server
--   2. The Managed Identity must already exist in Azure
--   3. Run this against the target database (not master, unless testing master)
--
-- USAGE:
--   1. Replace <YourManagedIdentityName> with your VM/App Service name
--   2. Connect to your Azure SQL database as an Azure AD admin
--   3. Run the appropriate section below
--
-- ============================================

-- ============================================
-- OPTION 1: SYSTEM-ASSIGNED MANAGED IDENTITY
-- ============================================
-- For Azure VMs, App Services, Functions, etc. with System-assigned MSI
-- The identity name is the same as the Azure resource name

-- Create the user (replace with your resource name)
-- CREATE USER [<YourVMName>] FROM EXTERNAL PROVIDER;

-- Example: VM named "sqlpysim-test-vm"
-- CREATE USER [sqlpysim-test-vm] FROM EXTERNAL PROVIDER;

-- Grant permissions (choose one or more based on your needs):

-- Read-only access (recommended for testing)
-- ALTER ROLE db_datareader ADD MEMBER [<YourVMName>];

-- Read-write access
-- ALTER ROLE db_datareader ADD MEMBER [<YourVMName>];
-- ALTER ROLE db_datawriter ADD MEMBER [<YourVMName>];

-- Full access (use with caution)
-- ALTER ROLE db_owner ADD MEMBER [<YourVMName>];


-- ============================================
-- OPTION 2: USER-ASSIGNED MANAGED IDENTITY
-- ============================================
-- For User-assigned Managed Identities that can be shared across resources
-- The identity name is the name you gave the User-assigned MSI in Azure

-- Create the user (replace with your User-assigned MSI name)
-- CREATE USER [<YourUserAssignedMSIName>] FROM EXTERNAL PROVIDER;

-- Example: User-assigned MSI named "sqlpysim-shared-identity"
-- CREATE USER [sqlpysim-shared-identity] FROM EXTERNAL PROVIDER;

-- Grant permissions (same options as above):
-- ALTER ROLE db_datareader ADD MEMBER [<YourUserAssignedMSIName>];


-- ============================================
-- COMPLETE EXAMPLE: System-assigned MSI
-- ============================================
-- Uncomment and modify this block for a typical setup:

/*
-- Create user for VM named "myTestVM"
CREATE USER [myTestVM] FROM EXTERNAL PROVIDER;

-- Grant read access to run SELECT queries
ALTER ROLE db_datareader ADD MEMBER [myTestVM];

-- Verify the user was created
SELECT name, type_desc, authentication_type_desc 
FROM sys.database_principals 
WHERE name = 'myTestVM';
*/


-- ============================================
-- COMPLETE EXAMPLE: User-assigned MSI
-- ============================================
-- Uncomment and modify this block for user-assigned MSI:

/*
-- Create user for User-assigned MSI named "my-shared-identity"
CREATE USER [my-shared-identity] FROM EXTERNAL PROVIDER;

-- Grant read/write access
ALTER ROLE db_datareader ADD MEMBER [my-shared-identity];
ALTER ROLE db_datawriter ADD MEMBER [my-shared-identity];

-- Verify the user was created
SELECT name, type_desc, authentication_type_desc 
FROM sys.database_principals 
WHERE name = 'my-shared-identity';
*/


-- ============================================
-- VERIFICATION QUERIES
-- ============================================

-- List all Azure AD users in this database
SELECT 
    name AS [User/Identity Name],
    type_desc AS [Type],
    authentication_type_desc AS [Auth Type],
    create_date AS [Created]
FROM sys.database_principals 
WHERE authentication_type_desc = 'EXTERNAL'
ORDER BY name;

-- Check role memberships for a specific user
-- Replace 'YourIdentityName' with the actual name
/*
SELECT 
    r.name AS [Role],
    m.name AS [Member]
FROM sys.database_role_members rm
JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id
WHERE m.name = 'YourIdentityName';
*/


-- ============================================
-- CLEANUP (if needed)
-- ============================================
-- To remove access:

-- DROP USER [<YourManagedIdentityName>];
