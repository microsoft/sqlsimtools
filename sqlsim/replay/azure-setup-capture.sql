-- Setup XEvent session for sqlsim replay testing on Azure SQL Database
-- 
-- Prerequisites:
--   1. Azure Storage account with a container (e.g., 'xevents')
--   2. SQL Server managed identity granted 'Storage Blob Data Contributor' on the storage account
--   3. Database scoped credential created (see below)
--
-- Usage:
--   sqlsim -S myserver.database.windows.net -d mydb -T <token> -app sqlsim_admin -i replay\azure-setup-capture.sql
--
-- Before running this script, create the database scoped credential:
--   CREATE DATABASE SCOPED CREDENTIAL [https://<storage>.blob.core.windows.net/<container>]
--   WITH IDENTITY = 'Managed Identity';
--
-- Then update the blob URL below to match your storage account and container.
--
-- IMPORTANT: Use -app sqlsim_admin so the setup commands are excluded from capture.
-- The XEvent session only captures events from client_app_name = 'sqlsim'.

-- *** UPDATE THIS URL to match your storage account and container ***
-- Format: https://<storageaccount>.blob.core.windows.net/<container>/sqlsim_capture.xel
DECLARE @blobUrl NVARCHAR(500) = N'https://sqlparitystorage.blob.core.windows.net/xevents/sqlsim_capture.xel';

-- Clean up any existing session
IF EXISTS(SELECT 1 FROM sys.dm_xe_database_sessions WHERE name = 'sqlsim_capture')
    ALTER EVENT SESSION sqlsim_capture ON DATABASE STATE = STOP;
IF EXISTS(SELECT 1 FROM sys.database_event_sessions WHERE name = 'sqlsim_capture')
    DROP EVENT SESSION sqlsim_capture ON DATABASE;
GO

-- Create the XEvent session on DATABASE (Azure SQL DB uses DATABASE, not SERVER)
-- Only captures events from 'sqlsim' app name. Run setup/teardown with -app sqlsim_admin.
CREATE EVENT SESSION sqlsim_capture ON DATABASE
ADD EVENT sqlserver.sql_batch_completed(
    ACTION(sqlserver.session_id, sqlserver.database_name)
    WHERE sqlserver.client_app_name = N'sqlsim'
),
ADD EVENT sqlserver.rpc_completed(
    ACTION(sqlserver.session_id, sqlserver.database_name)
    WHERE sqlserver.client_app_name = N'sqlsim'
)
ADD TARGET package0.event_file(
    SET filename = N'https://sqlparitystorage.blob.core.windows.net/xevents/sqlsim_capture.xel'
)
WITH (
    MAX_MEMORY = 4096 KB,
    MAX_DISPATCH_LATENCY = 5 SECONDS
);
GO

-- Start capturing
ALTER EVENT SESSION sqlsim_capture ON DATABASE STATE = START;
GO

SELECT 'XEvent session sqlsim_capture is now running on DATABASE' AS status;
GO
