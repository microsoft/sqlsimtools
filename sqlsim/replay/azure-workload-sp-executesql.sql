-- RPC workload for Azure SQL DB replay testing (sp_executesql)
-- Usage: sqlsim -S myserver.database.windows.net -d mydb -T <token> -i replay\azure-workload-sp-executesql.sql -q
--
-- Generates rpc_completed events for sp_executesql in the XEvent capture.

{CALL sp_executesql(N'SELECT @p1 AS val', N'@p1 INT', 42)}
GO
{CALL sp_executesql(N'SELECT @p1 AS val, @p2 AS label', N'@p1 INT, @p2 NVARCHAR(50)', 99, N'replay_test')}
GO
