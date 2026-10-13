-- Create test stored procedure for Azure SQL DB replay testing
-- Usage: sqlsim -S myserver.database.windows.net -d mydb -T <token> -app sqlsim_admin -i replay\azure-create-test-proc.sql -q
--
-- IMPORTANT: Use -app sqlsim_admin so this is excluded from XEvent capture.
-- Azure SQL DB doesn't allow creating objects in tempdb, so we use the user database.

IF OBJECT_ID('dbo.sqlsim_test_proc', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sqlsim_test_proc;
GO

CREATE PROCEDURE dbo.sqlsim_test_proc
    @id INT,
    @name NVARCHAR(100)
AS
BEGIN
    SELECT @id AS id, @name AS name;
END
GO

SELECT 'Test stored procedure dbo.sqlsim_test_proc created' AS status;
GO
