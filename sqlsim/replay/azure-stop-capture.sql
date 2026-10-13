-- Stop the XEvent capture session on Azure SQL Database
-- Usage: sqlsim -S myserver.database.windows.net -d mydb -T <token> -app sqlsim_admin -i replay\azure-stop-capture.sql -q

IF EXISTS(SELECT 1 FROM sys.dm_xe_database_sessions WHERE name = 'sqlsim_capture')
    ALTER EVENT SESSION sqlsim_capture ON DATABASE STATE = STOP;
GO

SELECT 'XEvent session sqlsim_capture stopped' AS status;
GO
