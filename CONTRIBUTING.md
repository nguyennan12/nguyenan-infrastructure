# Contributing

This project manages infrastructure and backups. Please keep changes small, explain operational impact, and avoid changing production paths or credentials without a migration plan.

1. Open an issue for substantial changes. For vulnerabilities, follow [the security policy](SECURITY.md) instead of a public issue.
2. Fork the repository and submit a pull request against `main`. Describe the affected deployment mode, compatibility impact, and rollback considerations.
3. Run Bash syntax, ShellCheck, registry validation, and the relevant regression tests listed in [the CI workflow](.github/workflows/infrastructure-ci.yml). For new service adapters, follow [the service guide](docs/ADD-SERVICE.md). Include results and identify checks you could not run.
4. Use fixtures and redacted logs. Never commit live secrets, backup data, private domains, personal IPs, or credentials.

Contributions are submitted under the repository's [MIT License](LICENSE). External software retains its own licenses.
