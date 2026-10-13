-- SQL batch workload for Azure SQL DB replay testing
-- Usage: sqlsim -S myserver.database.windows.net -d mydb -T <token> -i replay\azure-workload-batches.sql -q
--
-- Generates sql_batch_completed events in the XEvent capture.

SELECT @@VERSION
GO
SELECT name, database_id FROM sys.databases
GO
SELECT @@SERVERNAME
GO
