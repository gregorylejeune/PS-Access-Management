# Plan

This is the working plan for PS access management. The repo already contains the foundation and the actions below. Items marked **decision** are not built yet.

## What this tool is

An operator runs a Windows form on a domain workstation. The form does not ask for the service-account password. It reads AWS Secrets Manager secret `HH_PS_AccessManagement`, normalizes the JSON, and connects.

The Windows user running the form is the operator. The service account is only the directory credential. Both are written on the audit session row. The password is not.

## Secret shape

Loose input is accepted (`upn`, `Pw`). The canonical shape is:

- `OnPremAD.UserPrincipalName`, `Password`, `Purpose`, optional `Server`, optional `SearchBase`
- `GraphApi.TenantId`, `ClientId`, and either `ClientSecret` or `CertificateThumbprint`
- `ConnectionStrings.Audit`, optional `Catalog` (defaults to the audit database)

If the names are wrong but the values are present, the form shows the rename list with no values. The operator can keep the repair in memory, or type the secret id and write the canonical JSON back to Secrets Manager.

The workstation can remember the secret **name** and region with DPAPI for the current user. It does not remember the secret value.

Environment-variable dropdowns show names and scope. Values are shown only for region, profile, and computer identity. Credential values are never shown. The operator can load `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_SESSION_TOKEN` from Process, User, or Machine scope into the session.

## Where a change is written

| Account | Name, alias, email, username, OU, enable | MFA |
| --- | --- | --- |
| On-prem only | On-prem AD | Not available |
| Synced to Entra | On-prem AD. Entra follows sync. | Entra |
| Cloud only | Entra / Graph | Entra |

The tool refuses to change its own service account. Privileged accounts (`adminCount` or a privileged group) need an extra confirmation.

No write happens unless the audit database accepts a pending row first.

## Actions in this repo

1. **Add an alias.** Adds `smtp:`. Optional promotion to primary `SMTP:`.
2. **Change first or last name.** Updates `givenName` and `sn`. Display name updates by default. Renaming the AD common name is off unless checked.
3. **Re-enable.** Clears the disabled flag and a lockout. Does **not** set a password. The person uses the existing self-service portal. If the password is expired, the form says so and still does not change it.
4. **Unblock.** Clears a bad-password lockout only. A disabled account is left disabled so this is not confused with re-enable.
5. **Multi-factor.** Either the legacy per-user MFA state (`disabled`, `enabled`, `enforced`) or one on-prem `extensionAttribute1`–`15`. This does not delete registered authentication methods.
6. **Regenerate email.** Builds a new primary SMTP address, keeps the old one as an alias by default, and updates `mail` and `mailNickname`. Default pattern is `given.surname` at the current primary domain. Collisions get a numeric suffix.
7. **Move OU.** On-prem only. The new distinguished name is read back into the audit row.
8. **Change username.** `sAMAccountName` and/or user principal name. Old UPN is kept as an alias by default. Mail is not changed unless checked. Profile paths and home folders are not renamed.

Every changed attribute is a row: system (`OnPremAD` or `Entra`), attribute, value before, value after, and decoded flags where that applies (enabled, disabled, lockout, password-does-not-expire, and the rest of the account-control bits).

## Audit schema

SQL Server temporal tables:

- `dbo.OperatorSession` — who ran it, which service account, which machine, hash of the secret name
- `dbo.InteractionLog` — searches, connects, and each directory call
- `dbo.DirectoryChange` — before/after values, with `dbo.DirectoryChangeHistory`

Password-like values are stored as `[REDACTED]`.

If the tables are missing, connect creates them.

## Identity catalog

`scripts/Invoke-HybridIdentityCatalog.ps1` is separate from the form.

- One `dbo.IdentityRecord` per person.
- `Alignment = AlignedUpn` when the on-prem and Entra user principal names match. The row stores `OnPremObjectGuid` and `EntraObjectId` separately.
- Immutable ID or sAMAccountName matches with a different UPN are still one row, labeled `AlignedImmutableId` or `AlignedSam`.
- Accounts that do not sync are `OnPremOnly` or `EntraOnly`.
- `dbo.IdentityAttribute` stores standard, extended (`msExch*`, `msDS-*`), `extensionAttribute1`–`15`, and custom attributes.
- The table is system-versioned, so each catalog run keeps history when a value actually changes.
- Binary attributes (photos, certificates, hashes) store length and a SHA-256, not the bytes.
- Password-like attribute names are redacted here too.

## Decisions still open

These are not in the form yet.

1. **MFA methods.** Do you also want to remove a phone, authenticator, or email method, or only the per-user state and extension attributes above?
2. **Email pattern.** Is `given.surname@current-domain` the real standard, or do you want a different pattern and a fixed domain list?
3. **Username.** Should a UPN change also rename the common name, mail nickname, and primary SMTP by default? Right now only the UPN and optional alias change unless you check the mail box.
4. **Name.** Should the common name follow the display name by default? Right now it does not.
5. **Entra Connect.** After an on-prem write, should this start a delta sync? If yes, which server, and is that account allowed to start it?
6. **Privileged accounts.** Extra confirmation is the current behavior. Should these be a hard stop instead?
7. **Forest.** The form uses one domain, the PDC emulator, unless the secret sets `OnPremAD.Server`. Are there other domains?
8. **Exchange beyond SMTP.** Aliases are `proxyAddresses`. Do you also need Send As, Full Access, hide from GAL, or a remote-mailbox `targetAddress` change in the first release?
9. **Public secret name.** The default id `HH_PS_AccessManagement` is in this public repo. Say if you want that default removed.
10. **Catalog database.** Catalog uses `ConnectionStrings.Catalog` when set, otherwise the audit database. Do you want them split?
11. **Proposed next actions.** Hide or unhide from the GAL, set or clear manager, add or remove one group, revoke Entra sessions after a re-enable or rename, edit title / department / phone. Bulk CSV is intentionally not included.

## Explicitly out of scope until you say otherwise

- Setting, rotating, or viewing passwords
- Bulk changes
- Creating or deleting accounts
- Changing membership of Domain Admins, Enterprise Admins, Schema Admins, or the other built-in privileged groups
- Writing a change when the audit insert fails
