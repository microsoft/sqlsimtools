-- Setup XEvent session for sqlsim replay testing
-- Usage: sqlsim -S localhost -E -app sqlsim_admin -i replay\setup-test-capture.sql
--
-- IMPORTANT: Use -app sqlsim_admin so the setup commands are excluded from capture.
-- The XEvent session only captures events from client_app_name = 'sqlsim'.

-- Clean up any existing session
IF EXISTS(SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'sqlsim_test_capture')
    ALTER EVENT SESSION sqlsim_test_capture ON SERVER STATE = STOP;
IF EXISTS(SELECT 1 FROM sys.server_event_sessions WHERE name = 'sqlsim_test_capture')
    DROP EVENT SESSION sqlsim_test_capture ON SERVER;
GO

-- Create the XEvent session
-- Only captures events from 'sqlsim' app name. Run setup/teardown with -app sqlsim_admin.
-- package0.event_sequence lets convert-xel.ps1 restore the order events occurred;
-- Extended Events does not write buffers to the .xel file in event order.
CREATE EVENT SESSION sqlsim_test_capture ON SERVER
ADD EVENT sqlserver.sql_batch_completed(
    ACTION(package0.event_sequence, sqlserver.session_id, sqlserver.database_name)
    WHERE sqlserver.client_app_name = 'sqlsim'
),
ADD EVENT sqlserver.rpc_completed(
    ACTION(package0.event_sequence, sqlserver.session_id, sqlserver.database_name)
    WHERE sqlserver.client_app_name = 'sqlsim'
),
ADD EVENT sqlserver.login(
    ACTION(package0.event_sequence, sqlserver.session_id, sqlserver.database_name)
    WHERE sqlserver.client_app_name = 'sqlsim'
),
ADD EVENT sqlserver.logout(
    ACTION(package0.event_sequence, sqlserver.session_id, sqlserver.database_name)
    WHERE sqlserver.client_app_name = 'sqlsim'
)
ADD TARGET package0.event_file(
    SET filename = N'C:\temp\sqlsim_test_capture.xel',
        max_file_size = 10
)
WITH (
    MAX_MEMORY = 4096 KB,
    MAX_DISPATCH_LATENCY = 1 SECONDS
);
GO

-- Start capturing
ALTER EVENT SESSION sqlsim_test_capture ON SERVER STATE = START;
GO

SELECT 'XEvent session sqlsim_test_capture is now running' AS status;
GO
