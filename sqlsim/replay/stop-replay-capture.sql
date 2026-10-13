-- Stop the replay capture XEvent session
-- Usage: sqlsim -S localhost -E -app sqlsim_admin -i replay\stop-replay-capture.sql -q

ALTER EVENT SESSION sqlsim_replay_capture ON SERVER STATE = STOP;
GO

SELECT 'XEvent session sqlsim_replay_capture stopped' AS status;
GO
