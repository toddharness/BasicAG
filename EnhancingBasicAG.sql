USE [msdb]
GO

IF EXISTS (SELECT 1 FROM sysjobs WHERE name = 'RestartReportingServicesService')
	BEGIN
		DECLARE @jobid UNIQUEIDENTIFIER
		SELECT  @Jobid = job_id from sysjobs where name = 'RestartReportingServicesService'
		EXEC msdb.dbo.sp_delete_job @job_id=@jobid, @delete_unused_schedule=1
	END
GO


BEGIN TRANSACTION
DECLARE @ReturnCode INT
SELECT @ReturnCode = 0

IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N'AlwaysOn Maintenance' AND category_class=1)
BEGIN
EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name=N'AlwaysOn Maintenance'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

END

DECLARE @jobId BINARY(16)
EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'RestartReportingServicesService', 
		@enabled=1, 
		@notify_level_eventlog=0, 
		@notify_level_email=0, 
		@notify_level_netsend=0, 
		@notify_level_page=0, 
		@delete_level=0, 
		@description=N'Will restart Reporting services service if failover occurred for reportserver database.', 
		@category_name=N'AlwaysOn Maintenance', 
		@owner_login_name=N'SQL-Lab\administrator', @job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'Restart Reporting Services', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'PowerShell', 
		@command=N'$service = Get-WmiObject -ComputerName SQL2 -Class Win32_Service `
-Filter "Name=''ReportServer`$STANDARD2016''"
$service.stopservice()
Start-Sleep -s 15
$service.startservice()
', 
		@database_name=N'master', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
COMMIT TRANSACTION
GOTO EndSave
QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:
GO


----------------------
USE [msdb]
GO

IF EXISTS (SELECT 1 FROM sysjobs WHERE name = 'AlwaysOn Auto Failover')
	BEGIN
		DECLARE @jobid UNIQUEIDENTIFIER
		SELECT  @Jobid = job_id from sysjobs where name = 'AlwaysOn Auto Failover'
		EXEC msdb.dbo.sp_delete_job @job_id=@jobid, @delete_unused_schedule=1
	END
GO

	BEGIN TRANSACTION
	DECLARE @ReturnCode INT
	SELECT @ReturnCode = 0

	IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N'AlwaysOn Maintenance' AND category_class=1)
	BEGIN
	EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name=N'AlwaysOn Maintenance'
	IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

	END

	DECLARE @jobId BINARY(16)
	EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'AlwaysOn Auto Failover', 
			@enabled=1, 
			@notify_level_eventlog=0, 
			@notify_level_email=0, 
			@notify_level_netsend=0, 
			@notify_level_page=0, 
			@delete_level=0, 
			@description=N'Will failover all "grouped" AG''s to where the listener in the group resides.  If an AG is faileed over to a replica without the listener it will return to the listener.', 
			@category_name=N'AlwaysOn Maintenance', 
			@owner_login_name=N'sa', @job_id = @jobId OUTPUT
	IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
		
	EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'Failover AGs', 
			@step_id=1, 
			@cmdexec_success_code=0, 
			@on_success_action=1, 
			@on_success_step_id=0, 
			@on_fail_action=2, 
			@on_fail_step_id=0, 
			@retry_attempts=0, 
			@retry_interval=0, 
			@os_run_priority=0, @subsystem=N'TSQL', 
			@command=N'USE [master]
GO


DECLARE @INTCOUNTER INT = 1
	,@MAXINTCOUNTER INT
	,@CMD			VARCHAR (250)
	,@Delimiter varchar(1) = ''_''


Declare @AG_Groups Table  -- TABLE TO STORE AG''S THAT NEED TO BE MOVED TO SAME SERVER THAT HOUSES THE LISTENER
(ID INT IDENTITY (1,1)
,ag_name NVARCHAR(512)
)

WAITFOR DELAY ''00:00:30'' -- DELAY ADDED TO ALLOW FOR TIME FOR TRIGGERING FAILOVER TO COMPLETE.  (Should change this to query replica states so we won''t wait longer than needed or go earlier than desired)

;WITH CTE_Listner_Groups (ag_name, GroupName /* GROUP NAME IS based off of the naming convention */)
 AS (
SELECT	 ag_name
		,LEFT(RIGHT(ag_name,Len(ag_name)-CHARINDEX(@Delimiter,ag_name)),CHARINDEX(@Delimiter,RIGHT(ag_name,Len(ag_name)-CHARINDEX(@Delimiter,ag_name)-1)))  as GroupName
FROM sys.dm_hadr_name_id_map imap 
INNER JOIN sys.availability_group_listeners agl ON imap.ag_id = agl.group_id  -- ONLY INCLUDE AG''s IF THEY HAVE A LISTENER
INNER JOIN sys.dm_hadr_availability_replica_states ARS ON ARS.group_id = imap.ag_id 
WHERE	ARS.role_desc = ''PRIMARY'' -- ONLY INCLUDE AG''S THAT ARE PRIMARY ON THIS REPLICA
	AND	ARS.is_local = 1  -- ONLY CONSIDER LOCAL REPLICA''S
	)


INSERT @AG_Groups  -- INSERT AG''S THAT ARE NOT PRIMARY ON THIS REPLICA BUT BELONG TO A GROUPING (VIA THE NAMING CONVENTION) THAT ARE PRIMARY AND HAVE A LISTENER
SELECT	imap.ag_name
FROM sys.dm_hadr_name_id_map imap 
INNER JOIN CTE_Listner_Groups cte ON imap.ag_name like ''%'' + cte.groupname + ''%'' -- GROUPINGS THAT HAVE THE LISTENER PRIMARY ON THIS REPLICA
INNER JOIN sys.dm_hadr_availability_replica_states ARS ON ARS.group_id = imap.ag_id
WHERE	ARS.role_desc <> ''PRIMARY'' -- ONLY INCLUDE AG''S THAT ARE NOT PRIMARY ON THIS REPLICA
	AND	ARS.is_local = 1  -- ONLY CONSIDER LOCAL REPLICA''S

SELECT @MAXINTCOUNTER = @@ROWCOUNT



WHILE @INTCOUNTER <= @MAXINTCOUNTER  -- BEGIN LOOP
    BEGIN

		SELECT @CMD = ''ALTER AVAILABILITY GROUP ['' + ag_name + ''] FAILOVER;''
		FROM @AG_Groups
		WHERE ID = @INTCOUNTER
		--print @cmd
		EXEC (@cmd) -- FAILOVER NON PRIMARY AG''S PREVIOUSLY DEFINED

		SELECT @INTCOUNTER = @INTCOUNTER + 1

	END

-- REPORTING SERVICES MUST BE RESTARTED TO CREATE SUBSCRIPTIONS ON NEW REPLICA.
-- IF REPORTSERVER GROUPING IS INCLUDED IN FAILOVERS RESTART REPORT SERVER SERVICES.
IF EXISTS (SELECT 1 FROM @AG_Groups where LEFT(RIGHT(ag_name,Len(ag_name)-CHARINDEX(@Delimiter,ag_name)),CHARINDEX(@Delimiter,RIGHT(ag_name,Len(ag_name)-CHARINDEX(@Delimiter,ag_name)-1))) = ''Reports'') -- ''REPORTS'' IS THE GROUP NAME FOR THE AG GROUPING THAT HAS THE REPORT SERVER DATABASE
	BEGIN
		EXEC msdb.dbo.sp_start_job N''RestartReportingServicesService''
	END

-- IF ONE NODE GOES DOWN AND AUTO FAILOVER HAPPENS RESTART REPORTING SERVICES IF SERVER HAS A REPORT SERVER DATABASE.  THIS IS NEEDED FOR WHEN AN AUTOMATIC FAILOVER OCCURS.
IF		EXISTS (SELECT 1 WHERE sys.fn_hadr_is_primary_replica (''ReportServer'') = 1) 
	AND EXISTS (SELECT 1 
				FROM sys.dm_hadr_database_replica_cluster_states hdrcs
				INNER JOIN sys.dm_hadr_availability_replica_cluster_states dharcs ON hdrcs.replica_id = dharcs.replica_id
				INNER JOIN sys.dm_hadr_database_replica_states dhdrs ON dhdrs.replica_id = hdrcs.replica_id AND dhdrs.group_id = dharcs.group_id
				INNER JOIN sys.dm_hadr_availability_replica_states ARS ON ARS.group_id = dharcs.group_id and ARS.replica_id = dharcs.replica_id
				WHERE	hdrcs.database_name = ''reportserver''
					AND	dharcs.replica_server_name <> @@SERVERNAME
					AND synchronization_state_desc = ''NOT SYNCHRONIZING''
				)
	BEGIN
		EXEC msdb.dbo.sp_start_job N''RestartReportingServicesService''
	END

-- IF A SUBSCRIPTION IS CREATED AND AND A FAILOVER OCCURS THE SUBSCRIPTION WILL THEN EXIST ON BOTH NODES.  
-- IF THE SUBSCRIPTION IS DELETED ON THE NEW REPLICA AND THEN FAILS BACK TO THE ORIGINAL REPLICA THE DELETED SUBSCRIPTION WILL STILL EXIST ON THE NOW PRIMARY REPLICA
-- THIS SNIPPET OF CODE WILL DELETE ALL OF THE JOBS IN THE REPORT SERVER CATEGORY (THE DEFAULT CATEGORY FOR ALL CREATED SUBSCRIPTIONS).
-- SINCE THE SUBSCRIPTIONS GET RECREATED ON FAILOVER, THIS SOLVES THE DELETE ISSUE AND ALLOWS US TO NOT EITHER DISABLE THE JOBS, HAVE FAILED JOBS, OR HAVE TO HAVE A PROCESS TO INJECT A PRIMARY NODE CHECK.
IF EXISTS (
	SELECT 1 FROM master.sys.dm_hadr_availability_replica_states AS arstates
	INNER JOIN master.sys.dm_hadr_database_replica_cluster_states AS dbcs ON arstates.replica_id = dbcs.replica_id
	WHERE	ISNULL(arstates.role, 3) = 2 
		AND ISNULL(dbcs.is_database_joined, 0) = 1
		AND	dbcs.database_name = ''ReportServer'' -- DATABASE NAME OF REPORT SERVER DATABASE
		)
	BEGIN
		DECLARE @JobsToDelete TABLE
		(ID INT IDENTITY (1,1)
		,Job_id UNIQUEIDENTIFIER
		)

		DECLARE	 @Jobcount INT = 1
				,@JobID UNIQUEIDENTIFIER

		INSERT @JobsToDelete
		SELECT  sj.job_id
		FROM    msdb.dbo.sysjobs sj
				INNER JOIN msdb.dbo.syscategories sc ON sc.category_id = sj.category_id
		WHERE   sc.name = ''Report Server'' -- CATEGORY OF JOBS TO DELETE

		WHILE @Jobcount <= (SELECT max(id) from @jobstoDelete)
			BEGIN
				SELECT @JobID = Job_id from @JobsToDelete where ID = @Jobcount
		
				EXEC msdb.dbo.sp_delete_job @job_id=@JobID, @delete_unused_schedule=1

				SELECT @Jobcount = @Jobcount + 1
			END
	END
GO', 
			@database_name=N'master', 
			@flags=0
	IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
	EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
	IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
	EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
	IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
	COMMIT TRANSACTION
	GOTO EndSave
	QuitWithRollback:
		IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
	EndSave:


GO




----
USE [msdb]
GO

IF EXISTS (SELECT 1 FROM  sysalerts WHERE name = 'AlwaysOn Auto Failover Monitor')
	BEGIN
		EXEC msdb.dbo.sp_delete_alert @name=N'AlwaysOn Auto Failover Monitor'
	END
GO

DECLARE @NewJobID UNIQUEIDENTIFIER
SELECT @NewJobID = Job_id FROM sysjobs WHERE name = 'AlwaysOn Auto Failover'

EXEC msdb.dbo.sp_add_alert @name=N'AlwaysOn Auto Failover Monitor', 
		@message_id=1480, 
		@severity=0, 
		@enabled=1, 
		@delay_between_responses=30, 
		@include_event_description_in=0, 
		@category_name=N'[Uncategorized]', 
		@job_id= @NewJobID
GO
