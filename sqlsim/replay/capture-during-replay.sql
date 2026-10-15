-- Start XEvent capture to record what sqlsim replays
-- Usage: sqlsim -S localhost -E -app sqlsim_admin -i replay\capture-during-replay.sql -q
--
-- This creates a separate XEvent session that captures events during replay.
-- After replaying, use compare-traces.ps1 to compare original vs replayed traces.
-- Use -app sqlsim_admin so this setup command is NOT captured.

-- Clean up any existing replay capture session
IF EXISTS(SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'sqlsim_replay_capture')
    ALTER EVENT SESSION sqlsim_replay_capture ON SERVER STATE = STOP;
IF EXISTS(SELECT 1 FROM sys.server_event_sessions WHERE name = 'sqlsim_replay_capture')
    DROP EVENT SESSION sqlsim_replay_capture ON SERVER;
GO

-- Create the replay capture session
-- Only captures events from 'sqlsim' app name (same filter as original capture)
CREATE EVENT SESSION sqlsim_replay_capture ON SERVER
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
    SET filename = N'C:\temp\sqlsim_replay_capture.xel',
        max_file_size = 10
)
WITH (
    MAX_MEMORY = 4096 KB,
    MAX_DISPATCH_LATENCY = 1 SECONDS
);
GO

-- Start capturing
ALTER EVENT SESSION sqlsim_replay_capture ON SERVER STATE = START;
GO

SELECT 'XEvent session sqlsim_replay_capture is now running - ready for replay' AS status;
GO
