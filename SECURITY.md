# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.1   | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please do not open a public issue. Instead, report it responsibly:

1. **Email**: Contact the repository maintainer at security@nexgen3dprinting.com
2. **GitHub Security**: Use GitHub's "Report a vulnerability" feature for this repository

Please include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Any potential fixes you've considered

We aim to respond to security reports within 48 hours and will keep you updated on the status of your report.

## Security Measures

This project uses:
- GitHub's secret scanning to prevent accidental commits of secrets
- Push protection to block secrets from being committed
- Regular dependency updates (when applicable)

## Best Practices

When using the scripts in this repository:
1. Review the scripts before running them
2. The scripts require root privileges - ensure you trust the source
3. No data is transmitted to external servers
4. All configurations are local to your system
