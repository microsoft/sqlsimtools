-- RPC workload for Azure SQL DB replay testing (user stored proc)
-- Usage: sqlsim -S myserver.database.windows.net -d mydb -T <token> -i replay\azure-workload-rpc.sql -q
--
-- Generates rpc_completed events in the XEvent capture.
-- Requires azure-create-test-proc.sql to be run first.

{CALL dbo.sqlsim_test_proc(1, N'hello')}
GO
{CALL dbo.sqlsim_test_proc(2, N'world')}
GO
{CALL dbo.sqlsim_test_proc(3, N'test')}
GO
