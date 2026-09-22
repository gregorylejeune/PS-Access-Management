SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

IF OBJECT_ID(N'dbo.SchemaMigration', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.SchemaMigration (
        MigrationId nvarchar(128) NOT NULL CONSTRAINT PK_SchemaMigration PRIMARY KEY,
        AppliedUtc datetime2(3) NOT NULL CONSTRAINT DF_SchemaMigration_AppliedUtc DEFAULT SYSUTCDATETIME()
    );
END;

IF OBJECT_ID(N'dbo.OperatorSession', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.OperatorSession (
        SessionId uniqueidentifier NOT NULL CONSTRAINT PK_OperatorSession PRIMARY KEY,
        OperatorSam nvarchar(256) NOT NULL,
        OperatorUpn nvarchar(512) NULL,
        OperatorSid nvarchar(184) NULL,
        MachineName nvarchar(256) NOT NULL,
        StartedUtc datetime2(3) NOT NULL,
        AppVersion nvarchar(64) NOT NULL,
        ServiceAccountUpn nvarchar(512) NOT NULL,
        SecretIdentifierSha256 char(64) NOT NULL,
        DomainController nvarchar(256) NULL
    );
END;

IF OBJECT_ID(N'dbo.InteractionLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InteractionLog (
        InteractionId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_InteractionLog PRIMARY KEY,
        SessionId uniqueidentifier NOT NULL,
        OccurredUtc datetime2(3) NOT NULL,
        SystemName nvarchar(32) NOT NULL,
        Action nvarchar(64) NOT NULL,
        TargetRef nvarchar(1024) NULL,
        Detail nvarchar(max) NULL,
        Outcome nvarchar(32) NOT NULL,
        ErrorMessage nvarchar(max) NULL,
        CONSTRAINT FK_InteractionLog_Session FOREIGN KEY (SessionId) REFERENCES dbo.OperatorSession (SessionId)
    );
    CREATE INDEX IX_InteractionLog_Session ON dbo.InteractionLog (SessionId, OccurredUtc);
END;

IF OBJECT_ID(N'dbo.DirectoryChange', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DirectoryChange (
        ChangeId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DirectoryChange PRIMARY KEY,
        SessionId uniqueidentifier NOT NULL,
        CorrelationId uniqueidentifier NOT NULL,
        OccurredUtc datetime2(3) NOT NULL,
        SystemName nvarchar(32) NOT NULL,
        Operation nvarchar(64) NOT NULL,
        TargetUpn nvarchar(512) NULL,
        TargetOnPremGuid uniqueidentifier NULL,
        TargetEntraId uniqueidentifier NULL,
        TargetDn nvarchar(1024) NULL,
        AttributeName nvarchar(256) NOT NULL,
        ValueBefore nvarchar(max) NULL,
        ValueAfter nvarchar(max) NULL,
        FlagsBefore nvarchar(max) NULL,
        FlagsAfter nvarchar(max) NULL,
        Outcome nvarchar(32) NOT NULL,
        ErrorMessage nvarchar(max) NULL,
        SysStartTime datetime2(3) GENERATED ALWAYS AS ROW START NOT NULL,
        SysEndTime datetime2(3) GENERATED ALWAYS AS ROW END NOT NULL,
        PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime),
        CONSTRAINT FK_DirectoryChange_Session FOREIGN KEY (SessionId) REFERENCES dbo.OperatorSession (SessionId)
    ) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.DirectoryChangeHistory));

    CREATE INDEX IX_DirectoryChange_TargetUpn ON dbo.DirectoryChange (TargetUpn, OccurredUtc);
    CREATE INDEX IX_DirectoryChange_Correlation ON dbo.DirectoryChange (CorrelationId);
END;
