# Permissions

Delegate the on-prem service account to the OUs it is allowed to change. Do not put it in Domain Admins.

It needs rights to:

- Read user objects and all attributes you want cataloged
- Write `givenName`, `sn`, `displayName`, `mail`, `mailNickname`, `proxyAddresses`
- Write `userPrincipalName` and `sAMAccountName` where username changes are allowed
- Reset lockout and clear `ACCOUNTDISABLE` (enable and unlock)
- Move user objects between the OUs you allow
- Rename the common name, if operators use that checkbox
- Write `extensionAttribute1` through `extensionAttribute15` if you use that MFA path

The Entra app registration uses application permissions, not a delegated user.

Client secret or certificate:

- `User.ReadWrite.All`
- `Directory.ReadWrite.All` for the catalog and directory reads
- `UserAuthenticationMethod.ReadWrite.All` if you later remove authentication methods

Per-user MFA state is still a legacy Graph surface (`/users/{id}/authentication/requirements`, with a beta fallback). Confirm the tenant still uses per-user MFA before relying on that action. Authentication-method changes are a separate decision.

The audit login only needs DDL on first connect (it creates the schema if missing) and DML after that. After the schema exists you can remove DDL from the login if you prefer to ship later migrations yourself.

The catalog database holds directory values. Lock it down the same way you lock directory exports. Do not copy it into git.
