# Security Policy

HomeAccounting handles financial data and bank credentials, so security is core
to the product, not an afterthought. Thank you for helping keep it and its users
safe.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately via either:

- **GitHub Private Vulnerability Reporting** — the **“Report a vulnerability”**
  button under this repository’s **Security** tab (preferred).
- **Email** — `security@homeaccounting.com`.

Please include: the affected component, steps to reproduce (or a proof of
concept), the impact, and any suggested remediation.

## What to expect

- **Acknowledgement** within **3 business days**.
- An initial assessment and severity rating within **7 business days**.
- Progress updates through remediation, and a disclosure timeline coordinated
  with you.
- We practise **coordinated disclosure**: please give us reasonable time to fix
  and release before public disclosure (target **90 days**, sooner for
  actively-exploited issues).

## Scope

Highest-priority areas:

- Authentication and session handling (JWT issuance/verification)
- Bank credential / token storage and **encryption at rest**
- The statement import and bank-sync pipelines
- The managed cloud deployment

Generally out of scope: findings requiring an already-compromised host or
physical access; social engineering; volumetric denial of service; and issues in
third-party dependencies without demonstrated impact here (please report those
upstream).

## Our security posture

Rather than a one-off paid audit, we rely on an open, continuous model:

- **Open source** — the code is public and auditable.
- **Automated scanning in CI** — secret scanning (`gitleaks`) runs on every
  change.
- **Encryption at rest** — bank-connection credentials are stored as ciphertext
  only, using AES-256-GCM with a versioned, rotatable key
  (`BANKING_TOKEN_ENC_KEY`); no plaintext tokens are persisted.
- **This disclosure policy** so scrutiny has a path to responsible reporting.

## Recognition

We’re glad to credit reporters in release notes (opt-in). We do not currently
run a paid bug-bounty programme.

## Supported versions

Until the first stable release, only the latest `master` of the `web` and
`backend` repositories is supported.
