# Contributing to Kodachi OS

Thank you for your interest in contributing to Kodachi OS! This document provides guidelines and best practices for contributing to the project.

## Table of Contents
- [Code of Conduct](#code-of-conduct)
- [Git Workflow](#git-workflow)
- [Commit Message Guidelines](#commit-message-guidelines)
- [Branching Strategy](#branching-strategy)
- [Pull Request Process](#pull-request-process)
- [Code Style Guidelines](#code-style-guidelines)
- [Directory Structure](#directory-structure)
- [Testing](#testing)
- [Security](#security)

## Code of Conduct

- Be respectful and professional in all interactions
- Focus on constructive criticism and technical merit
- Welcome contributors of all skill levels
- Keep discussions focused on improving the project

## Git Workflow

### Setting Up Your Development Environment

1. Fork the repository on GitHub
2. Clone your fork locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/Linux-Kodachi.git
   cd Linux-Kodachi
   ```
3. Add the upstream repository:
   ```bash
   git remote add upstream https://github.com/WMAL/kodachios.git
   ```
4. Keep your fork synchronized:
   ```bash
   git fetch upstream
   git checkout main
   git merge upstream/main
   ```

### Making Changes

1. Create a feature branch from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```
2. Make your changes in logical, atomic commits
3. Test your changes thoroughly
4. Push to your fork:
   ```bash
   git push origin feature/your-feature-name
   ```
5. Create a Pull Request on GitHub

## Commit Message Guidelines

### Format

```
type(scope): brief description (max 50 chars)

Detailed explanation of the change (wrap at 72 chars)
- Why this change is necessary
- What problem it solves
- Any side effects or considerations

Fixes #issue_number (if applicable)
```

### Types

- **feat**: New feature or capability
- **fix**: Bug fix
- **docs**: Documentation changes
- **style**: Code formatting (no functional changes)
- **refactor**: Code restructuring without changing behavior
- **test**: Adding or modifying tests
- **chore**: Maintenance tasks, dependency updates
- **perf**: Performance improvements
- **security**: Security-related changes

### Examples

Good commit messages:
```
feat(tor-switch): add load balancing support for multiple instances

Implements native kernel-level load balancing using iptables/nftables
with three modes: round-robin, weighted, and consistent-hashing.
This allows better traffic distribution across Tor instances.

Fixes #123
```

```
fix(ip-fetch): handle timeout errors in geolocation API calls

Add proper error handling for network timeouts when fetching
geolocation data. Implements exponential backoff retry logic
with configurable max attempts.
```

Bad commit messages:
```
Update files
Fix bug
WIP
Changes
```

## Branching Strategy

### Branch Naming Convention

- **Feature branches**: `feature/descriptive-name`
- **Bug fixes**: `fix/issue-description`
- **Documentation**: `docs/what-is-being-documented`
- **Hotfixes**: `hotfix/critical-issue`

### Branch Rules

1. **main branch**: Production-ready code only
2. **Feature branches**: All new development
3. **No direct commits to main**: Always use Pull Requests
4. **Keep branches focused**: One feature/fix per branch
5. **Delete branches after merge**: Keep repository clean

## Pull Request Process

### Before Submitting

1. **Update your branch** with latest main:
   ```bash
   git fetch upstream
   git rebase upstream/main
   ```
2. **Run all tests** and ensure they pass
3. **Update documentation** if needed
4. **Squash related commits** for cleaner history:
   ```bash
   git rebase -i HEAD~n  # where n is number of commits
   ```

### PR Description Template

```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing
- [ ] Unit tests pass
- [ ] Integration tests pass
- [ ] Manual testing completed

## Checklist
- [ ] Code follows project style guidelines
- [ ] Self-review completed
- [ ] Documentation updated
- [ ] No hardcoded paths or credentials
- [ ] All tests passing
- [ ] No new warnings

## Related Issues
Fixes #(issue number)
```

### Review Process

1. At least one maintainer review required
2. All CI checks must pass
3. No merge conflicts
4. Approved reviews before merge
5. Squash and merge to maintain clean history

## Code Style Guidelines

### General Rules

1. **No hardcoded paths**: Always detect dynamically
2. **No credentials in code**: Use environment variables
3. **Error handling**: Never use `.unwrap()` in Rust code
4. **Consistent naming**: Use descriptive, meaningful names
5. **Documentation**: Comment complex logic
6. **Testing**: Write tests for new functionality

### Language-Specific Guidelines

#### Rust
- Follow official Rust style guide
- Use `cargo fmt` before committing
- Fix all `cargo clippy` warnings
- Proper error handling with `Result` and `?`

#### Bash
- Use shellcheck for validation
- Quote all variables: `"$var"`
- Use `set -euo pipefail` for safety
- Meaningful function and variable names

#### Gambas
- Follow existing project patterns
- Proper event handling
- Clean separation of UI and logic

## Directory Structure

### Naming Conventions

- **No spaces** in directory or file names
- Use hyphens for word separation: `my-feature-name`
- Version directories: `Kodachi-OS-<major>-<status>`, for example `Kodachi-OS-10-stable`, not `Kodachi 10`
- Descriptive names that indicate purpose

### Organization

```
kodachios/
├── Kodachi-OS-10-stable/  # Current stable version (no spaces!)
├── Kodachi-OS-9-legacy/   # Previous version (clear marking)
├── Kodachi-OS-8-EOL/      # End of life, archived
├── docs/                # Documentation
├── scripts/             # Utility scripts
└── tests/               # Test suites
```

## Testing

### Required Tests

1. **Unit tests**: For individual functions/modules
2. **Integration tests**: For component interactions
3. **Security tests**: For authentication and encryption
4. **Performance tests**: For critical paths

### Running Tests

```bash
# Rust services
cd dashboard/hooks/rust/service-name
cargo test

# Gambas applications
cd gambas/app-name
./test_app.sh
```

## Security

### Security Guidelines

1. **Never commit**:
   - API keys or tokens
   - Passwords or credentials
   - Private keys or certificates
   - Personal information

2. **Always validate**:
   - User input
   - File paths
   - Network data
   - Command arguments

3. **Report vulnerabilities**:
   - Use private disclosure
   - Contact maintainers directly through GitHub
   - Do not create public issues for vulnerabilities

### Security Checklist

- [ ] No sensitive data in code
- [ ] Input validation implemented
- [ ] Proper authentication checks
- [ ] Secure communication protocols
- [ ] Least privilege principle followed

## Getting Help

- **Documentation**: Check `/docs` directory
- **Issues**: Search existing issues before creating new ones
- **Discussions**: Use GitHub Discussions for questions
- **Email**: Contact maintainers for sensitive topics

## Recognition

Contributors are recognized in:
- The public [Kodachi OS Roll of Honor](https://kodachi.cloud/community/contributors.html) community recognition page
- CONTRIBUTORS.md file
- Release notes
- Project documentation

Thank you for contributing to making Kodachi OS better and more secure!