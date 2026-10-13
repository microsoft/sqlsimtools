-- Stop the original test capture XEvent session
-- Usage: sqlsim -S localhost -E -app sqlsim_admin -i replay\stop-test-capture.sql -q

ALTER EVENT SESSION sqlsim_test_capture ON SERVER STATE = STOP;
GO

SELECT 'XEvent session sqlsim_test_capture stopped' AS status;
GO
