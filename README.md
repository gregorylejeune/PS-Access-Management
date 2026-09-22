# PS access management

Operator console for a hybrid on-prem Active Directory, Entra ID, and Exchange environment. It runs as a Windows form, talks to the directory with a service account from AWS Secrets Manager, and writes an audit row for every value it changes.

The person who opens the form is recorded separately from the service account. This tool does not set passwords. Re-enabled accounts are sent back through your existing self-service password portal.

No credentials belong in this repository. See [SECURITY.md](SECURITY.md).

## Run the form

On a domain-joined Windows workstation with the Active Directory RSAT module:

```powershell
Install-Module AWS.Tools.SecretsManager
.\Start-PSAccessManagement.ps1
```

The first screen asks for the secret identifier and region. You can type them or pick environment variables that already exist on the machine. Secret values are not displayed. You can save the identifier with DPAPI for your Windows user.

Default secret id: `HH_PS_AccessManagement`.

The secret can use the loose names or the canonical ones. Loose names are normalized in memory. You can write the canonical JSON back only by typing the secret id again. See [docs/PLAN.md](docs/PLAN.md).

Example shape, with nothing real in it: [examples/secret.example.json](examples/secret.example.json).

## What you can change

- Add an alias
- Change a first or last name
- Re-enable an account
- Unblock a locked account
- Change per-user MFA state, or one `extensionAttribute`
- Regenerate the primary email address and keep the old one as an alias
- Move a user to another OU
- Change `sAMAccountName` and/or the user principal name

Preview is required. Privileged accounts need a second confirmation. If the audit database does not have the schema, connect creates it. If the audit insert fails, the directory is not changed.

## Catalog

A separate script matches on-prem and Entra users. Matching user principal names become one person row, with the on-prem GUID and the Entra object ID both stored. Accounts that never sync stay one-sided. Attributes, including extension and custom attributes, go into a system-versioned table.

```powershell
.\scripts\Invoke-HybridIdentityCatalog.ps1 -SecretId 'HH_PS_AccessManagement' -Region 'us-east-1'
```

Use `-MaxUsers 25` for a first pass and `-WhatIf` to count without writing.

## Tests

```powershell
powershell -NoProfile -File .\tests\Invoke-NormalizeTests.ps1
```

Those tests cover secret normalization, redaction, email and alias planning, and the re-enable plan. They do not contact AWS or a directory.

## More

- [docs/PLAN.md](docs/PLAN.md) — behavior and the decisions still open
- [docs/PERMISSIONS.md](docs/PERMISSIONS.md) — service account and app registration rights
