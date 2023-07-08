/*************************************************************************************************************
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
Set @LogToTable = 'Y' for all backup jobs! (This is the defaut).  

Created by Jared Zagelbaum, 4/13/2015, https://jaredzagelbaum.wordpress.com/
For intro / tutorial, see https://jaredzagelbaum.wordpress.com/2015/04/16/automated-restore-script-output-for-ola-hallengrens-maintenance-solution/
Follow me on Twitter!: @JaredZagelbaum

**************************************************************************************************************/
--Create restore command jobs
--User-set variables below here:
DECLARE @DatabaseName SYSNAME = N'MyDB' -- Provide db location of maintenance solution and RestoreCommand
DECLARE @RestoreScriptDir NVARCHAR(max) = 'Backup_Dir' -- Choose restore script location: 'Backup_Dir', 'Error_Log', or custom defined dir, e.g., 'C:\' . Directory must be created first if custom!

--User-set variables above here ^^^
DECLARE @ErrorMessage NVARCHAR(max);
DECLARE @JobId UNIQUEIDENTIFIER;
DECLARE @StepId INT;
DECLARE @OnSuccessAction TINYINT;
DECLARE @OnFailAction TINYINT;
DECLARE @BackupDir NVARCHAR(max);
DECLARE @RestoreScriptDirValue NVARCHAR(4000);
DECLARE @RestoreCommand NVARCHAR(max);

IF (@RestoreScriptDir IS NULL OR @RestoreScriptDir = '')
BEGIN
	SET @ErrorMessage = 'The value for the parameter @RestoreScriptDir is not supported.' + CHAR(13) + CHAR(10) + ' ';

	RAISERROR (@ErrorMessage,16,1) WITH NOWAIT;
END

IF @RestoreScriptDir NOT IN (
		'Error_Log'
		,'Backup_Dir'
		)
BEGIN
	SET @RestoreScriptDirValue = @RestoreScriptDir + '\$(ESCAPE_SQUOTE(SRVR))\$(ESCAPE_SQUOTE(SRVR))_DatabaseRestore_$(ESCAPE_SQUOTE(STRTDT))_$(ESCAPE_SQUOTE(STRTTM)).txt';
END

IF @RestoreScriptDir = 'Error_Log'
BEGIN
	SET @RestoreScriptDirValue = N'$(ESCAPE_SQUOTE(SQLLOGDIR))\DatabaseRestore_$(ESCAPE_SQUOTE(SRVR))_$(ESCAPE_SQUOTE(STRTDT))_$(ESCAPE_SQUOTE(STRTTM)).txt';
END

SET @RestoreCommand = N'sqlcmd -E -S $(ESCAPE_SQUOTE(SRVR)) -d ' + @DatabaseName + ' -Q "EXECUTE [dbo].[RestoreCommand]" -b';

DECLARE JobStepCursor CURSOR FAST_FORWARD
FOR
	SELECT JOB.job_id
		,step_id
		,on_success_action
		,on_fail_action
		,replace(replace(
			right(substring(command, charindex('@Directory = ', command), CHARINDEX(',', command, charindex('@Directory', command)) - charindex('@Directory = ', command)), len(substring(command, charindex('@Directory = ', command), CHARINDEX(',', command, charindex('@Directory', command)) - charindex('@Directory = ', command))) - 13)
			, 'N''', '')
			, '''', '') AS BackupDir
	FROM msdb.dbo.sysjobs JOB
	JOIN msdb.dbo.sysjobsteps STEP
		ON STEP.job_id = JOB.job_id
	WHERE step_name LIKE 'DatabaseBackup - %';

OPEN JobStepCursor;

FETCH NEXT
FROM JobStepCursor
INTO @JobId
	,@StepId
	,@OnSuccessAction
	,@OnFailAction
	,@BackupDir
	;

WHILE @@Fetch_Status = 0
BEGIN
	IF @RestoreScriptDir = 'Backup_Dir'
		AND @BackupDir = 'NULL'
	BEGIN
		EXECUTE [master].dbo.xp_instance_regread
			 N'HKEY_LOCAL_MACHINE'
			,N'SOFTWARE\Microsoft\MSSQLServer\MSSQLServer'
			,N'BackupDirectory'
			,@RestoreScriptDirValue OUTPUT
			;

		SET @RestoreScriptDirValue = @RestoreScriptDirValue
			+ '\$(ESCAPE_SQUOTE(SRVR))\$(ESCAPE_SQUOTE(SRVR))_DatabaseRestore_$(ESCAPE_SQUOTE(STRTDT))_$(ESCAPE_SQUOTE(STRTTM)).txt'
	END

	IF @RestoreScriptDir = 'Backup_Dir'
		AND @BackupDir <> 'NULL'
	BEGIN
		SET @RestoreScriptDirValue = @BackupDir
			+ '\$(ESCAPE_SQUOTE(SRVR))\$(ESCAPE_SQUOTE(SRVR))_DatabaseRestore_$(ESCAPE_SQUOTE(STRTDT))_$(ESCAPE_SQUOTE(STRTTM)).txt'
	END

	IF LEFT(@RestoreScriptDirValue, 2) = '\\'
	BEGIN
		SET @RestoreScriptDirValue = '\' + Replace(@RestoreScriptDirValue, '\\', '\') --check for concat errors
	END

	IF LEFT(@RestoreScriptDirValue, 2) <> '\\'
	BEGIN
		SET @RestoreScriptDirValue = Replace(@RestoreScriptDirValue, '\\', '\') --check for concat errors
	END

	DECLARE @NextStepId int = @StepId + 1;
	
	RAISERROR ('Updating existing backup job step to Go To Next Step...',0,0) WITH NOWAIT;

	EXEC msdb.dbo.sp_update_jobstep
		 @job_id = @JobId
		,@step_id = @StepId
		,@on_success_action = 3
		,@on_fail_action = 2
		;

	RAISERROR ('Adding "Generate Restore Script" job step...',0,0) WITH NOWAIT;

	EXEC msdb.dbo.sp_add_jobstep @job_id = @JobId
		,@step_name = N'Generate Restore Script'
		,@step_id = @NextStepId
		,@cmdexec_success_code = 0
		,@on_success_action = @OnSuccessAction
		,@on_fail_action = @OnFailAction
		,@retry_attempts = 0
		,@retry_interval = 0
		,@os_run_priority = 0
		,@subsystem = N'CmdExec'
		,@command = @RestoreCommand
		,@database_name = @DatabaseName
		,@output_file_name = @RestoreScriptDirValue
		,@flags = 0
		;

	FETCH NEXT
	FROM JobStepCursor
	INTO @JobId
		,@StepId
		,@OnSuccessAction
		,@OnFailAction
		,@BackupDir
		;
END

CLOSE JobStepCursor;

DEALLOCATE JobStepCursor;
