# Security Policy

## Reporting a vulnerability

Report a security vulnerability through GitHub's private vulnerability reporting
on the Weir repository. Open the Security tab and choose "Report a
vulnerability". Do not open a public issue for a security vulnerability.

We review each report and respond as soon as we can.

## What counts as a security bug

A security bug weakens the security of the firmware or of the system it boots.
For example, a bug that lets an attacker bypass measured boot, forge a
measurement, or, once Weir supports secure boot, run an image that failed
authentication.

A bug that does not affect security is not a security bug. Report those through
the normal issue tracker.

## Scope

Weir measures the boot chain into a TPM 2.0 today, described in
[docs/measured-boot.md](docs/measured-boot.md). Secure boot, which authenticates
each image before it runs, is planned. This policy grows in importance as that
lands.
