# Security

This repository is public on purpose. It must never contain a real secret, connection string, certificate, tenant identifier from production, or directory export.

- The AWS secret **name** is not a credential. The secret **value** stays in AWS Secrets Manager.
- The workstation stores only the secret identifier, and it stores that with Windows DPAPI for the current user.
- The tool does not set passwords. Re-enable turns the account back on. The person uses the existing self-service password portal.
- Audit rows redact values whose names look like passwords, secrets, tokens, or PINs.
- The catalog database holds directory attribute values. Treat that database as confidential and do not replicate it into this repo.
- Do not open an issue that includes a secret payload, a token, or a production user export. Use a private GitHub security advisory on this repository instead.
