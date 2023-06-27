USE MyDB; --the database where you have the Ola Hallengren scripts/tables installed.
GO
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

IF NOT EXISTS (
		SELECT 1
		FROM sys.objects
		WHERE [object_id] = OBJECT_ID(N'dbo.RestoreCommand')
			AND [type] IN (N'P',N'PC')
		)
BEGIN
	EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE dbo.RestoreCommand AS';
END
GO

ALTER PROCEDURE dbo.RestoreCommand
AS
/*
*********************************************************************************************
Script for creating automated restore scripts based on Ola Hallengren's Maintenance Solution. 
Source: https://ola.hallengren.com

Create RestoreCommand s proc in location of Maintenance Solution procedures 
and CommandLog table along with creating job steps.

At least one full backup for all databases should be logged to CommandLog table (i.e., executed through Maintenance Solution
created FULL backup job) for generated restore scripts to be valid. 
Restore scripts are generated based on CommandLog table, not msdb backup history.

Restore script is created using ouput file. Each backup job creates a date / time stamped restore script file in separate step.
Add a job to manage file retention if desired (I use a modified version of Ola's Output File Cleanup job).
If possible, perform a tail log backup and add to end of restore script 
in order to avoid data loss (also remove any replace options for full backups).

Make sure sql agent has read / write to the directory that you want the restore script created.

Script will read backup file location from @Directory value used in respective DatabaseBackup job (NULL is supported). 
SET @LogToTable = 'Y' for all backup jobs! (This is the default).  

Created by Jared Zagelbaum, 2015-04-13, https://jaredzagelbaum.wordpress.com/
For intro / tutorial see: https://jaredzagelbaum.wordpress.com/2015/04/16/automated-restore-script-output-for-ola-hallengrens-maintenance-solution/
Follow me on Twitter!: @JaredZagelbaum
*********************************************************************************************
2019-09-13 - Lee Fisher - Added functionality to support Blob Storage as a backup location
*********************************************************************************************
2023-06-20 - Fixed problems when deploying to case-sensitive SQL Instance.
*********************************************************************************************
*/
SET NOCOUNT ON

DECLARE @DatabaseName SYSNAME;
DECLARE @DatabaseNamePartition SYSNAME = 'N/A';
DECLARE @Command NVARCHAR(max);
DECLARE @IncludeCopyOnly NVARCHAR(max) = 'Y';-- include copy only backups in restore script? Added for AlwaysOn support
DECLARE @message NVARCHAR(max);

DECLARE restorecursor CURSOR FAST_FORWARD
FOR
WITH completed_ola_backups
AS (
	SELECT ID
		,DatabaseName
		,SchemaName
		,ObjectName
		,ObjectType
		,IndexName
		,IndexType
		,StatisticsName
		,PartitionNumber
		,ExtendedInfo
		,Command
		,CommandType
		,StartTime
		,EndTime
		,ErrorNumber
		,ErrorMessage
		-- Identify if disk or url location 
		,CASE 
			WHEN Command LIKE '%TO URL%'
				THEN 'URL'
			ELSE 'DISK'
			END [Location]
		--Expanded to include forward slash(/) used in URL path
		,CASE 
			WHEN Command LIKE '%\LOG\%'
				THEN 'Log'
			WHEN Command LIKE '%/LOG/%'
				THEN 'Log' -- Added for URL
			WHEN @IncludeCopyOnly = 'Y'
				AND Command LIKE '%\LOG_COPY_ONLY\%'
				THEN 'Log'
			WHEN @IncludeCopyOnly = 'Y'
				AND Command LIKE '%/LOG_COPY_ONLY/%'
				THEN 'Log' -- Added for URL
			WHEN Command LIKE '%\DIFF\%'
				THEN 'Diff'
			WHEN Command LIKE '%/DIFF/%'
				THEN 'Diff' -- Added for URL
			WHEN Command LIKE '%\FULL\%'
				THEN 'Full'
			WHEN Command LIKE '%/FULL/%'
				THEN 'Full' -- Added for URL
			WHEN @IncludeCopyOnly = 'Y'
				AND Command LIKE '%\FULL_COPY_ONLY\%'
				THEN 'Full'
			WHEN @IncludeCopyOnly = 'Y'
				AND Command LIKE '%/FULL_COPY_ONLY/%'
				THEN 'Full' -- Added for URL
			END BackupType
		--Expanded to include forward slash(/) used in URL path
		,CASE 
			WHEN Command LIKE '%\LOG\%'
				THEN 3
			WHEN Command LIKE '%/LOG/%'
				THEN 3 -- Added for URL
			WHEN @IncludeCopyOnly = 'Y'
				AND Command LIKE '%\LOG_COPY_ONLY\%'
				THEN 3
			WHEN @IncludeCopyOnly = 'Y'
				AND Command LIKE '%/LOG_COPY_ONLY/%'
				THEN 3 -- Added for URL
			WHEN Command LIKE '%\DIFF\%'
				THEN 2
			WHEN Command LIKE '%/DIFF/%'
				THEN 2 -- Added for URL
			WHEN Command LIKE '%\FULL\%'
				THEN 1
			WHEN Command LIKE '%/FULL/%'
				THEN 1 -- Added for URL
			WHEN @IncludeCopyOnly = 'Y'
				AND Command LIKE '%\FULL_COPY_ONLY\%'
				THEN 1
			WHEN @IncludeCopyOnly = 'Y'
				AND Command LIKE '%/FULL_COPY_ONLY/%'
				THEN 1 -- Added for URL
			END BackupTypeOrder
		,CASE CommandType
			WHEN 'BACKUP_LOG'
				THEN CHARINDEX('.trn', Command)
			WHEN 'BACKUP_DATABASE'
				THEN CHARINDEX('.bak', Command)
			END filechar
		/* ****************************************************************************
			Get BLOCKSIZE and MAXTRANSFERSIZE IF EXISTS for Azure Blob Storage
			**************************************************************************** */
		,(
			SELECT STUFF((
						SELECT ',' + [value]
						FROM String_Split(Command, ',')
						WHERE ([value] LIKE '%BLOCKSIZE%'
							OR [value] LIKE '%MAXTRANSFERSIZE%')
						FOR XML PATH('')
						), 1, 1, '')
			) AzureBlobStorage
	FROM dbo.CommandLog
	WHERE CommandType IN (
			'BACKUP_LOG'
			,'BACKUP_DATABASE'
			)
		AND EndTime IS NOT NULL -- Completed Backups Only
		AND ErrorNumber = 0
	)
	,lastfull
AS (
	SELECT MAX(ID) FullId
		,DatabaseName
	FROM completed_ola_backups
	WHERE BackupType = 'Full'
	GROUP BY DatabaseName
	)
	,lastdiff
AS (
	SELECT MAX(ID) DiffId
		,cob.DatabaseName
	FROM completed_ola_backups cob
	JOIN lastfull lf
		ON cob.DatabaseName = lf.DatabaseName
			AND cob.ID > lf.FullId
	WHERE BackupType = 'Diff'
	GROUP BY cob.DatabaseName
	)
	,lastnonlog
AS (
	SELECT Max(ID) LogIdBoundary
		,DatabaseName
	FROM (
		SELECT FullId AS ID
			,DatabaseName
		FROM lastfull
		
		UNION ALL
		
		SELECT DiffId
			,DatabaseName
		FROM lastdiff
		) Nonlog
	GROUP BY DatabaseName
	)
	,lastlogs
AS (
	SELECT cob.ID logid
	FROM completed_ola_backups cob
	JOIN lastnonlog lnl
		ON cob.DatabaseName = lnl.DatabaseName
			AND cob.ID > lnl.LogIdBoundary
	)
	,validbackups
AS (
	SELECT FullId backupid
	FROM lastfull
	
	UNION ALL
	
	SELECT DiffId backupid
	FROM lastdiff
	
	UNION ALL
	
	SELECT logid backupid
	FROM lastlogs
	)
SELECT cob.DatabaseName
	,REPLACE(REPLACE(REPLACE(REPLACE(
		LEFT(Command, filechar + 3)
		, 'BACKUP LOG', 'RESTORE LOG')
		, 'BACKUP DATABASE', 'RESTORE DATABASE')
		, 'TO DISK', 'FROM DISK')
		, 'TO URL', 'FROM URL') -- ADDED FOR URL
		+ ''' WITH NORECOVERY, STATS = 5'
		+ CASE 
		WHEN AzureBlobStorage IS NULL
			THEN '' --- Support Blob Storage
		ELSE ', ' + AzureBlobStorage
		END
		+ CASE BackupType
		WHEN 'Full'
			THEN ', REPLACE;'
		ELSE ';'
		END
		AS RestoreCommand
FROM completed_ola_backups cob
WHERE EXISTS (
		SELECT 1
		FROM validbackups vb
		WHERE cob.ID = vb.backupid
		)
ORDER BY cob.DatabaseName
	,ID
	,BackupTypeOrder;

RAISERROR ('/*****************************************************************',10,1) WITH NOWAIT

SET @message = 'Emergency Script Restore for ' + @@Servername + CASE @@Servicename
		WHEN 'MSSQLSERVER'
			THEN ''
		ELSE '\' + @@Servicename
		END;

RAISERROR (@message,10,1) WITH NOWAIT;

SET @message = 'Generated ' + convert(NVARCHAR, getdate(), 9);

RAISERROR (@message,10,1) WITH NOWAIT;

SET @message = 'Script does not perform a tail log backup. Dataloss may occur, use only for emergency DR.';

RAISERROR (@message,10,1) WITH NOWAIT;

RAISERROR ('******************************************************************/',10,1) WITH NOWAIT;

OPEN restorecursor;

FETCH NEXT
FROM restorecursor
INTO @DatabaseName
	,@Command
	;

WHILE @@FETCH_STATUS = 0
BEGIN
	IF @DatabaseName <> @DatabaseNamePartition
		AND @DatabaseNamePartition <> 'N/A'
	BEGIN
		SET @message = 'RESTORE DATABASE ' + '[' + @DatabaseNamePartition + ']' + ' WITH RECOVERY;';

		RAISERROR (@message,10,1) WITH NOWAIT;
	END

	IF @DatabaseName <> @DatabaseNamePartition
	BEGIN
		SET @message = CHAR(13) + CHAR(10) + '--------' + @DatabaseName + '-------------';

		RAISERROR (@message,10,1) WITH NOWAIT;
	END

	RAISERROR (@Command,10,1) WITH NOWAIT;

	SET @DatabaseNamePartition = @DatabaseName;

	FETCH NEXT
	FROM restorecursor
	INTO @DatabaseName
		,@Command
		;
END

SET @message = 'RESTORE DATABASE ' + '[' + @DatabaseNamePartition + ']' + ' WITH RECOVERY;';

RAISERROR (@message,10,1) WITH NOWAIT;

CLOSE restorecursor;

DEALLOCATE restorecursor;
GO

--test the RestoreCommand sproc!
EXEC dbo.RestoreCommand;
