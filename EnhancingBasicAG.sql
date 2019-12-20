/*
Added Template Parameters.  Use CTRL+Shift+M to specify Parameters
  -- Code will not run unless you set the template parameters
*/
USE [msdb];
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
		@owner_login_name=N'sa', @job_id = @jobId OUTPUT
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
		@command=N'Get-Service -ComputerName <ServernameWhereReportingServicesIsRunning, SYSNAME, SQL2> -Name "<ReportServiceName, Nvarchar(50), SQL Server Reporting Services (MSSQLSERVER)>" | Restart-Service', 
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

SET NOCOUNT ON

DECLARE @INTCOUNTER				INT
	,@MAXINTCOUNTER				INT
	,@CMD						VARCHAR (250)
	,@Delimiter					VARCHAR (1) = ''<Delimerter, Nvarchar(1), _>''
	,@GroupsToFail				INT = 1
	,@MaxTimeToRuninMin			INT = 15 
	,@Starttime					Datetime = getdate()
	,@EndTime					Datetime = getdate()
	,@DesiredOperationalState	INT
	,@ActualOperationalState	INT



Declare @AG_Groups Table  -- TABLE TO STORE AG''S THAT NEED TO BE MOVED TO SAME SERVER THAT HOUSES THE LISTENER
(ID INT IDENTITY (1,1)
,ag_name NVARCHAR(512)
,DBName NVARCHAR(512)
,role_Description NVARCHAR(60)
,GroupName NVARCHAR(510)
,ReadyToFail BIT
)

DECLARE @AGsToFail TAble
(ID INT IDENTITY(1,1)
,ag_name NVARCHAR(512)
,DBName NVARCHAR(512)
)

DECLARE @JobsToDelete TABLE
(ID INT IDENTITY (1,1)
,Job_id UNIQUEIDENTIFIER
)

WHILE (@GroupsToFail <> 0 OR EXISTS (SELECT * FROM @AG_Groups WHERE UPPER(Role_Description) = ''RESOLVING'')) AND datediff(mi,@Starttime, @EndTime) < @MaxTimeToRuninMin
	BEGIN
		
		SELECT @GroupsToFail = 0
		DELETE @AGsToFail
		DELETE @AG_Groups
		DELETE @JobsToDelete


		/*
		Groups to fail at the start is not the right choice.  This is because things may be resolving or completed
		wait, i need to have 1 ready to fail or 1 resolving to proceed.  This is right
		I think i need to add that it is in sync and no data loss will occur before setting ready to fail flag
		*/

		;WITH CTE_Listner_Groups (ag_name, DbName, GroupName, GroupRoleDescription /* GROUP NAME IS based off of the naming convention */)
		 AS (
		SELECT	 ag_name
				,drcs.database_name as dbname
				,LEFT(RIGHT(ag_name,Len(ag_name)-CHARINDEX(@Delimiter,ag_name)),CHARINDEX(@Delimiter,RIGHT(ag_name,Len(ag_name)-CHARINDEX(@Delimiter,ag_name)-1)))  as GroupName
				,ARS.role_desc AS GroupRoleDescription
		FROM sys.dm_hadr_name_id_map imap 
		INNER JOIN sys.availability_group_listeners agl ON imap.ag_id = agl.group_id  -- ONLY INCLUDE AG''s IF THEY HAVE A LISTENER
		INNER JOIN sys.dm_hadr_availability_replica_states ARS ON ARS.group_id = imap.ag_id 
		INNER JOIN sys.dm_hadr_database_replica_cluster_states drcs ON ARS.replica_id = drcs.replica_id
		WHERE	UPPER(ARS.role_desc) <> ''SECONDARY''--= ''PRIMARY'' -- ONLY INCLUDE AG''S THAT ARE PRIMARY ON THIS REPLICA
			AND	ARS.is_local = 1  -- ONLY CONSIDER LOCAL REPLICA''S
			)


		INSERT @AG_Groups  -- INSERT AG''S THAT ARE NOT PRIMARY ON THIS REPLICA BUT BELONG TO A GROUPING (VIA THE NAMING CONVENTION) THAT ARE PRIMARY AND HAVE A LISTENER
		SELECT	 imap.ag_name
				,cte.DbName
				,UPPER(ARS.role_desc)
				,cte.GroupName
				,CASE WHEN UPPER(cte.GroupRoleDescription) <> ''RESOLVING'' AND UPPER(ARS.role_desc) = ''SECONDARY'' AND drcs.is_failover_ready = 1 THEN 1 ELSE 0 END as ReadyToFail
		FROM sys.dm_hadr_name_id_map imap 
		INNER JOIN CTE_Listner_Groups cte ON imap.ag_name like ''%'' + cte.groupname + ''%'' -- GROUPINGS THAT HAVE THE LISTENER PRIMARY ON THIS REPLICA
		INNER JOIN sys.dm_hadr_availability_replica_states ARS ON ARS.group_id = imap.ag_id
		INNER JOIN sys.dm_hadr_database_replica_cluster_states drcs ON ARS.replica_id = drcs.replica_id
		WHERE	UPPER(ARS.role_desc) <> ''PRIMARY'' -- ONLY INCLUDE AG''S THAT ARE NOT PRIMARY ON THIS REPLICA
			AND	ARS.is_local = 1  -- ONLY CONSIDER LOCAL REPLICA''S



		SELECT @GroupsToFail = COUNT(*)
		FROM @AG_Groups
		WHERE ReadyToFail = 1

		
		SELECT	 @MAXINTCOUNTER = ISNULL(@GroupsToFail,0)
				,@INTCOUNTER = 1

		INSERT @AGsToFail
		SELECT DISTINCT ag_name,DBName
		FROM @AG_Groups
		WHERE ReadyToFail = 1

		WHILE @INTCOUNTER <= @MAXINTCOUNTER  -- BEGIN LOOP
			BEGIN

				SELECT	 @DesiredOperationalState = count(imap.ag_name)*2  /* OPERATIONAL_STATE ONLINE = 2 SO COUNT MUST BE DOUBLED*/
						,@ActualOperationalState = SUM(CASE WHEN ARS.role = 2 then operational_state ELSE 0 END )  /* ONLY CONSIDER OPERATIONAL STATE WHEN DB IS PRIMARY ON THIS NODE.  THIS IS NOT IN WHERE CLAUSE TO AVOID FALSE GOOD CRITERIA.*/
				FROM sys.dm_hadr_name_id_map imap 
				INNER JOIN sys.dm_hadr_availability_replica_states ARS ON ARS.group_id = imap.ag_id
				INNER JOIN @AGsToFail agf ON imap.ag_name = agf.ag_name 
				WHERE	ARS.is_local = 1  -- ONLY CONSIDER LOCAL REPLICAS
					AND	agf.ID = @INTCOUNTER

				SELECT @CMD = ''IF EXISTS (SELECT 1 WHERE sys.fn_hadr_is_primary_replica ('''''' + DBName + '''''') = 1) AND ISNULL('' + cast(@DesiredOperationalState as varchar)+ '',0) = ISNULL('' + cast(@ActualOperationalState as varchar) + '',0) BEGIN ALTER AVAILABILITY GROUP ['' + ag_name + ''] FAILOVER; END''
				FROM @AGsToFail
				WHERE ID = @INTCOUNTER
				
				--PRINT @cmd
				EXEC (@cmd) -- FAILOVER NON PRIMARY AG''S PREVIOUSLY DEFINED

				DELETE @AGsToFail WHERE ID = @INTCOUNTER

				SELECT @INTCOUNTER = @INTCOUNTER + 1
				
				SELECT @GroupsToFail = COUNT(1) FROM @AGsToFail WHERE ID >= @INTCOUNTER

			END



		-- REPORTING SERVICES MUST BE RESTARTED TO CREATE SUBSCRIPTIONS ON NEW REPLICA.
		-- IF REPORTSERVER GROUPING IS INCLUDED IN FAILOVERS RESTART REPORT SERVER SERVICES
		DECLARE  @ReportFailoverComplete	BIT = 0

		IF EXISTS (SELECT 1 FROM @AG_Groups where GroupName = ''<ReportGroupName, Nvarchar(50), Reports>'' AND ReadyToFail = 1) -- ''REPORTS'' IS THE GROUP NAME FOR THE AG GROUPING THAT HAS THE REPORT SERVER DATABASE
			BEGIN
				WHILE @ReportFailoverComplete = 0
					BEGIN
						SELECT	 @DesiredOperationalState = count(ag_name)*2  /* OPERATIONAL_STATE ONLINE = 2 SO COUNT MUST BE DOUBLED*/
								,@ActualOperationalState = SUM(CASE WHEN ARS.role = 1 then operational_state ELSE 0 END )  /* ONLY CONSIDER OPERATIONAL STATE WHEN DB IS PRIMARY ON THIS NODE.  THIS IS NOT IN WHERE CLAUSE TO AVOID FALSE GOOD CRITERIA.*/
						FROM sys.dm_hadr_name_id_map imap 
						INNER JOIN sys.dm_hadr_availability_replica_states ARS ON ARS.group_id = imap.ag_id 
						WHERE	ARS.is_local = 1  -- ONLY CONSIDER LOCAL REPLICA''S
							AND	LOWER(LEFT(RIGHT(ag_name,LEN(ag_name)-CHARINDEX(@Delimiter,ag_name)),CHARINDEX(@Delimiter,RIGHT(ag_name,LEN(ag_name)-CHARINDEX(@Delimiter,ag_name)-1)))) = ''<ReportGroupName, Nvarchar(50), Reports>''

						IF ISNULL(@DesiredOperationalState,0) = ISNULL(@ActualOperationalState,0)
							BEGIN
								EXEC msdb.dbo.sp_start_job N''RestartReportingServicesService''
								SELECT @ReportFailoverComplete = 1
							END
						IF @DesiredOperationalState <> @ActualOperationalState
							BEGIN
								WAITFOR DELAY ''00:00:02''
							END
					END		
			END

		-- IF ONE NODE GOES DOWN AND AUTO FAILOVER HAPPENS RESTART REPORTING SERVICES IF SERVER HAS A REPORT SERVER DATABASE.  THIS IS NEEDED FOR WHEN AN AUTOMATIC FAILOVER OCCURS.
		IF		EXISTS (SELECT 1 WHERE sys.fn_hadr_is_primary_replica (''<ReportServerDatabaseName, Nvarchar(50), ReportServer>'') = 1) 
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
				WHILE @ReportFailoverComplete = 0
					BEGIN
						SELECT	 @DesiredOperationalState = count(ag_name)*2  /* OPERATIONAL_STATE ONLINE = 2 SO COUNT MUST BE DOUBLED*/
								,@ActualOperationalState = SUM(CASE WHEN ARS.role = 1 then operational_state ELSE 0 END )  /* ONLY CONSIDER OPERATIONAL STATE WHEN DB IS PRIMARY ON THIS NODE.  THIS IS NOT IN WHERE CLAUSE TO AVOID FALSE GOOD CRITERIA.*/
						FROM sys.dm_hadr_name_id_map imap 
						INNER JOIN sys.dm_hadr_availability_replica_states ARS ON ARS.group_id = imap.ag_id 
						WHERE	ARS.is_local = 1  -- ONLY CONSIDER LOCAL REPLICA''S
							AND	LOWER(LEFT(RIGHT(ag_name,LEN(ag_name)-CHARINDEX(@Delimiter,ag_name)),CHARINDEX(@Delimiter,RIGHT(ag_name,LEN(ag_name)-CHARINDEX(@Delimiter,ag_name)-1)))) = ''<ReportGroupName, Nvarchar(50), Reports>''

						IF ISNULL(@DesiredOperationalState,0) = ISNULL(@ActualOperationalState,0)
							BEGIN
								EXEC msdb.dbo.sp_start_job N''RestartReportingServicesService''
								SELECT @ReportFailoverComplete = 1
							END
						IF @DesiredOperationalState <> @ActualOperationalState
							BEGIN
								WAITFOR DELAY ''00:00:02''
							END
					END		
			END

		-- IF A SUBSCRIPTION IS CREATED AND AND A FAILOVER OCCURS THE SUBSCRIPTION WILL THEN EXIST ON BOTH NODES.  
		-- IF THE SUBSCRIPTION IS DELETED ON THE NEW REPLICA AND THEN FAILS BACK TO THE ORIGINAL REPLICA THE DELETED SUBSCRIPTION WILL STILL EXIST ON THE NOW PRIMARY REPLICA
		-- THIS SNIPPET OF CODE WILL DELETE ALL OF THE JOBS IN THE REPORT SERVER CATEGORY (THE DEFAULT CATEGORY FOR ALL CREATED SUBSCRIPTIONS).
		-- SINCE THE SUBSCRIPTIONS GET RECREATED ON FAILOVER, THIS SOLVES THE DELETE ISSUE AND ALLOWS US TO NOT EITHER DISABLE THE JOBS, HAVE FAILED JOBS, OR HAVE TO HAVE A PROCESS TO INJECT A PRIMARY NODE CHECK.
		IF		EXISTS (SELECT 1 WHERE sys.fn_hadr_is_primary_replica (''<ReportServerDatabaseName, Nvarchar(50), ReportServer>'') = 0) 
		
			BEGIN

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
		
		SELECT @EndTime = getdate()
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
		@delay_between_responses=60, 
		@include_event_description_in=0, 
		@category_name=N'[Uncategorized]', 
		@job_id= @NewJobID
GO

