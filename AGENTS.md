# ReTripper Project Governance for AI Coding Agents

## Overview
This document contains permanent instructions for all future AI coding agents working on the ReTripper project.

---

## 1. Application Type and Purpose
- This is a **native iOS application** using Swift and SwiftUI.
- The app is initially designed for Royal Enfield motorcycles.

---

## 2. Core Principles
Prioritize the following in all development work:
- **Security**: Protect user data, credentials, and sensitive information
- **Privacy**: Respect user privacy and follow Apple's guidelines
- **Reliability**: Ensure stable, crash-free applications
- **Maintainability**: Write clean, well-documented code that is easy to maintain

---

## 3. Security Rules (MANDATORY)

### Credentials and Secrets
- **Never expose, print, commit or upload** passwords, API keys, tokens, certificates, `.p12` files or `.mobileprovision` files.
- **Never store signing credentials** in source code or GitHub.
- Store sensitive credentials using appropriate secure storage such as iOS Keychain.

### Build Security
- **Never weaken security settings** to make a build pass.
- Always use the most secure configuration available.

---

## 4. Git and Version Control Rules

### Commit History Protection
- **Never delete, overwrite or reset existing work** without explicit user approval.
- **Never force-push, amend published commits or rewrite Git history** without approval.

### Remote Management
- Always verify the remote URL before adding or modifying it.
- Do not silently replace an unrelated remote.

---

## 5. Dependency and Permission Rules

### Dependencies
- **Never install unnecessary dependencies.**
- Only add dependencies that are required for functionality.

### Permissions
- **Never introduce unnecessary iOS permissions.**
- Request only the minimum permissions needed for app functionality.

---

## 6. Development Practices

### Input Validation
- Validate all external input to prevent injection attacks and data corruption.

### Network Communication
- Use HTTPS for network communication.
- Implement proper certificate pinning where appropriate.

### Platform Compliance
- Follow Apple's platform security and privacy practices.
- Adhere to App Store guidelines.

---

## 7. Testing Requirements

### Test Coverage
- Add tests for meaningful functionality, not just trivial cases.
- Write unit tests, integration tests, and UI tests where appropriate.

### Test Execution
- Run relevant tests and builds after changes.
- Ensure all tests pass before merging code.

---

## 8. Communication and Reporting

### Honest Reporting
- Report changes, test results, failures, and remaining risks honestly.
- Do not hide errors or downplay issues.

### User Communication
- The user is non-technical. Explain required decisions and errors in simple language.
- Avoid jargon when possible; use clear, straightforward explanations.

---

## 9. Safety Rules (MANDATORY)

### Destructive Operations
- **Stop and request approval** before any destructive, irreversible or credential-exposing action.
- Examples requiring approval: deleting files, removing branches, committing secrets, pushing to remote.

### Work Preservation
- Never delete, overwrite or reset existing work without explicit user approval.

---

## 10. Project-Specific Notes

- This project is for Royal Enfield motorcycles (initial scope).
- The workspace is at `D:\Projects\ReTripper`.
- GitHub repository: https://github.com/NoNicK20/ReTripper.git

---

*This document should be followed by all AI agents working on this project. Deviations require explicit user approval.*