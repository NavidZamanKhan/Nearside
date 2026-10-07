# Storage Subsystem Diagnostics

## 1. Overview

The Storage subsystem manages local file access, sandboxed share extension staging, temporary disk buffers, and writes to the destination downloads folder (`Downloads` on macOS/Android, `Documents` on iOS).

## 2. Relevant Error Codes

- `NS-STORAGE-001`: Failed to open or read local source file for transfer.
- `NS-STORAGE-002`: Failed to create or write received data to destination storage.

## 3. Investigation Steps

- For `NS-STORAGE-001`:
  - Check file access permissions (sandbox security scoping, file locks).
  - Verify that the source file was not moved or deleted while staging.
- For `NS-STORAGE-002`:
  - Check available disk space in the destination filesystem (`ENOSPC`).
  - Verify application sandbox write permissions to the configured downloads folder.
