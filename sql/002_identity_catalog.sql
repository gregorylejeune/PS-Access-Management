SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

IF OBJECT_ID(N'dbo.CatalogRun', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.CatalogRun (
        CatalogRunId uniqueidentifier NOT NULL CONSTRAINT PK_CatalogRun PRIMARY KEY,
        StartedUtc datetime2(3) NOT NULL,
        FinishedUtc datetime2(3) NULL,
        StartedBy nvarchar(256) NOT NULL,
        OnPremCount int NULL,
        EntraCount int NULL,
        AlignedUpnCount int NULL,
        OnPremOnlyCount int NULL,
        EntraOnlyCount int NULL,
        OtherAlignedCount int NULL,
        Outcome nvarchar(32) NULL,
        ErrorMessage nvarchar(max) NULL
    );
END;

IF OBJECT_ID(N'dbo.IdentityRecord', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.IdentityRecord (
        IdentityId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_IdentityRecord PRIMARY KEY,
        MatchKey nvarchar(512) NOT NULL,
        Alignment nvarchar(32) NOT NULL,
        UserPrincipalName nvarchar(512) NULL,
        OnPremObjectGuid uniqueidentifier NULL,
        EntraObjectId uniqueidentifier NULL,
        OnPremSid nvarchar(184) NULL,
        ImmutableId nvarchar(256) NULL,
        OnPremSam nvarchar(256) NULL,
        DisplayName nvarchar(512) NULL,
        EnabledOnPrem bit NULL,
        EnabledEntra bit NULL,
        LastCatalogRunId uniqueidentifier NULL,
        LastCatalogedUtc datetime2(3) NOT NULL,
        SysStartTime datetime2(3) GENERATED ALWAYS AS ROW START NOT NULL,
        SysEndTime datetime2(3) GENERATED ALWAYS AS ROW END NOT NULL,
        PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime),
        CONSTRAINT UQ_IdentityRecord_MatchKey UNIQUE (MatchKey)
    ) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.IdentityRecordHistory));

    CREATE INDEX IX_IdentityRecord_OnPremGuid ON dbo.IdentityRecord (OnPremObjectGuid) WHERE OnPremObjectGuid IS NOT NULL;
    CREATE INDEX IX_IdentityRecord_EntraId ON dbo.IdentityRecord (EntraObjectId) WHERE EntraObjectId IS NOT NULL;
    CREATE INDEX IX_IdentityRecord_Upn ON dbo.IdentityRecord (UserPrincipalName);
END;

IF OBJECT_ID(N'dbo.IdentityAttribute', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.IdentityAttribute (
        IdentityId bigint NOT NULL,
        SourceSystem nvarchar(32) NOT NULL,
        AttributeName nvarchar(256) NOT NULL,
        AttributeClass nvarchar(32) NOT NULL,
        ValueJson nvarchar(max) NULL,
        ValueSha256 char(64) NULL,
        LastCatalogRunId uniqueidentifier NULL,
        SysStartTime datetime2(3) GENERATED ALWAYS AS ROW START NOT NULL,
        SysEndTime datetime2(3) GENERATED ALWAYS AS ROW END NOT NULL,
        PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime),
        CONSTRAINT PK_IdentityAttribute PRIMARY KEY (IdentityId, SourceSystem, AttributeName),
        CONSTRAINT FK_IdentityAttribute_Identity FOREIGN KEY (IdentityId) REFERENCES dbo.IdentityRecord (IdentityId)
    ) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.IdentityAttributeHistory));
END;

IF OBJECT_ID(N'dbo.IdentityAttributeStage', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.IdentityAttributeStage (
        CatalogRunId uniqueidentifier NOT NULL,
        IdentityId bigint NOT NULL,
        SourceSystem nvarchar(32) NOT NULL,
        AttributeName nvarchar(256) NOT NULL,
        AttributeClass nvarchar(32) NOT NULL,
        ValueJson nvarchar(max) NULL,
        ValueSha256 char(64) NULL
    );
    CREATE CLUSTERED INDEX IX_IdentityAttributeStage_Run
        ON dbo.IdentityAttributeStage (CatalogRunId, IdentityId, SourceSystem, AttributeName);
END;
