# B-Siri: SECURITY_POLICY.md

This document defines the security broker architecture, sandboxing boundaries, data privacy, and user authorization rules.

## Section 1: Ingestion and Input Security

### 1.1 Local-Only Speech Processing
- **[SEC-1.1.1] Zero Network Transmission**: Audio recorded via the system microphone for voice commands must never be sent to any cloud-based transcription API (e.g., Apple Cloud Siri, Google Speech-to-Text, OpenAI Whisper API).
- **[SEC-1.1.2] Local Decoupled Transcription**: `SFSpeechRecognizer` must be initialized with `requiresOnDeviceRecognition = true` to guarantee offline local transcription.

### 1.2 Ephemeral Audio Management
- **[SEC-1.2.1] In-Memory Audio Ingestion**: Captured raw audio buffers used for speech recognition must reside strictly within volatile application memory (RAM). Writing raw user audio payloads or voice snippets to persistent flash storage (SSD) is explicitly forbidden.
- **[SEC-1.2.2] Sandboxed Microphone Access**: The application must request explicit microphone permissions via Info.plist (`NSMicrophoneUsageDescription`) and macOS TCC prompts, strictly enforcing access boundaries.

## Section 2: Accessibility Browser Wrapper Security

### 2.1 Credential & Session Isolation
- **[SEC-2.1.1] No Keystroke Logging**: The browser wrapper must not log any passwords, credentials, or keys typed into browser fields. Standard password inputs (`AXTextField` with secure properties or text masks) must be treated as blind operations where payload contents are excluded from all logging and database storage.
- **[SEC-2.1.2] Sandbox Containment**: The system must operate within the boundaries of macOS Accessibility TCC permissions (`System Preferences > Security & Privacy > Accessibility`). The app must not request full disk access or system control unless explicitly needed for non-browser features.
- **[SEC-2.1.3] No Code Injection**: In accordance with REQ-2.2.2, injecting JavaScript using JXA Apple Events is strictly forbidden. This prevents potential XSS/CSRF exploits via the agent framework.

## Section 3: Ephemeral Vision Fallback Security

### 3.1 Image Data Privacy
- **[SEC-3.1.1] Zero External Transmission**: Raw screenshot images must never be transmitted to any external API, cloud service, or remote endpoint. All vision processing is strictly local (Apple Vision framework or local VLM).
- **[SEC-3.1.2] Secure Immediate Deletion**: Upon pipeline completion, raw image buffers in memory must be zeroed and released. Temp files on disk must be unlinked using secure deletion (overwrite-then-delete or `SecureEnclaveKey`-based wipe).
- **[SEC-3.1.3] No Metadata Retention**: EXIF metadata and CGImage properties must be stripped before any image is passed to the VLM pipeline. The orchestrator may only retain the extracted text/coordinates result, not the source image.

### 3.2 Screen Recording Permission
- **[SEC-3.2.1] TCC Screen Recording Entitlement**: The app must declare `NSScreenCaptureUsageDescription` in Info.plist and acquire `com.apple.security.screen-capture` entitlement approval at runtime. Screenshot capture must be disabled if the user has not explicitly granted permission.

## Section 4: Model Orchestrator Security

### 4.1 Local-Only Inference
- **[SEC-4.1.1] Zero Cloud Inference**: All LLM inference calls must terminate at a local network address (127.0.0.1 or ::1). The orchestrator must reject any configured endpoint that resolves to a public IP or external hostname.
- **[SEC-4.1.2] Prompt Injection Hardening**: User-supplied text must never be interpolated directly into the system prompt. It must be passed strictly as a `user` role message. The system prompt must be a static, developer-controlled string loaded from a sandboxed bundle resource.

### 4.2 RAG Data Security
- **[SEC-4.2.1] No PII in Embeddings**: Semantic summaries stored in SQLite-vec must be generated from abstracted intent descriptions, not raw user utterances containing names, passwords, or financial data. The summarisation step must strip identifiable literals before embedding.
- **[SEC-4.2.2] SQLite Encryption at Rest**: The SQLite database file (including the sqlite-vec embeddings table) must be encrypted using SQLCipher or an equivalent AES-256 encryption layer. The encryption key must be stored in the macOS Keychain, never on disk in plaintext.

## Section 5: Security Broker Policy Rules

### 5.1 Denylist Scope (High Tier — Hardcoded)
- **[SEC-5.1.1] Destructive Filesystem Commands**: `rm`, `rmdir`, `dd`, `mkfs`, `diskutil eraseVolume`, and any command containing `-rf` flag combinations.
- **[SEC-5.1.2] Privilege Escalation**: Any payload containing `sudo`, `su`, `doas`, or `osascript` with administrator privilege requests. This includes blocking the execution of JXA, AppleScript, or shell payloads containing the phrase 'with administrator privileges', or any automation attempt to interact with the Security & Privacy panes within System Settings.
- **[SEC-5.1.3] Protected Path Writes**: Any write action targeting `/System`, `/Library`, `/private`, `~/.ssh`, `~/.gnupg`, `/usr`, `/bin`, `/sbin`.
- **[SEC-5.1.4] Process Termination**: `kill -9`, `killall`, or `pkill` against any PID not belonging to B-Siri's own process tree.
- **[SEC-5.1.5] Network Configuration Changes**: `networksetup`, `pfctl`, `/etc/hosts` modifications, VPN config changes.

### 5.2 Allowlist Defaults (Medium Tier — User Editable)
- Default auto-approved: creating/writing files in `~/Documents`, `~/Downloads`, `~/Desktop`; opening apps via `open -a`; standard clipboard read/write; browser tab navigation.
- **[SEC-5.2.1] Allowlist Integrity**: The allowlist file must be validated against a JSON schema on load. Malformed entries must be rejected and logged; they must not silently expand permissions. The rule validation engine must inspect strings for command chaining or redirection operators (e.g., ';', '&&', '||', '|', '`', '$()'). Any Medium-tier tool call containing these execution boundaries must be instantly escalated to High security.

### 5.3 Audit Trail
- **[SEC-5.3.1] Tamper-Evident Audit Log**: The `audit_log` table must be append-only. The app must not expose any UI or API to delete audit log entries. The table is exempt from the 500MB pruning sweep.
- **[SEC-5.3.2] User Visibility**: A read-only audit log viewer must be accessible in the app's Settings panel so users can inspect all past High-tier approvals and denials.

## Section 6: Storage Security

### 6.1 Database Encryption
- **[SEC-6.1.1] SQLCipher AES-256**: The `.db` file must be opened exclusively via SQLCipher with a 256-bit AES key. Plaintext SQLite access to this file is forbidden at the code level.
- **[SEC-6.1.2] Keychain-Stored Key**: The encryption passphrase/key must be stored in the macOS Keychain under the app's bundle ID. It must never be written to `UserDefaults`, a plist, or any file on disk.
- **[SEC-6.1.3] Directory Backup Exclusion**: The entire application support data subdirectory containing the encrypted `.db` file, along with its active `.db-wal` and `.db-shm` journal structures, must be recursively excluded from iCloud and Time Machine backups using the `isExcludedFromBackupKey` URL resource attribute.

### 6.2 Pruning Data Integrity
- **[SEC-6.2.1] Cascade-Only Deletion**: Data may only be deleted via the foreign key `ON DELETE CASCADE` mechanism or explicit Phase 2 atomic transactions. No ad-hoc `DELETE FROM chat_history` without a `WHERE` clause may ever appear in the codebase.
- **[SEC-6.2.2] Audit Log Immutability**: No `DELETE`, `UPDATE`, or `DROP` statement may ever reference the `audit_log` table in production code. Compiler-enforced by routing all audit log writes through a write-only `AuditLogger` type with no delete methods.
- **[SEC-6.2.3] Engine-Enforced Audit Immutability**: The SQLite database schema must define an explicit `BEFORE UPDATE` and `BEFORE DELETE` trigger on the `audit_log` table that throws a hard SQLITE_CONSTRAINT exception, ensuring immutability at the storage engine layer.

## Section 7: UI/UX Security Policies

### 7.1 Input & Action Authorization Guardrails
- **[SEC-7.1.1] Allowlist Rule Validation**: The Settings UI must validate all user-added allowlist entries before committing them to disk. It must explicitly reject: empty commands, universal wildcard commands (`*`, `.*`, `sh`, `bash`), and root filesystem paths (`/`, `/var`, `/etc`).
- **[SEC-7.1.2] Spoofing & Clickjacking Prevention**: High-tier `NSAlert` modal dialogs must be initialized directly on the parent window sheet layer or as application-modal windows to prevent other local UI components or background threads from mimicking, hiding, or automatically dismissing them.

### 7.2 Interface Isolation & Data Leakage
- **[SEC-7.2.1] Read-Only Audit Log UI**: The audit log database connection used by the Preferences view controller must use a SQLite connection opened strictly in read-only mode (`SQLITE_OPEN_READONLY`). The view code must contain no bindings or logic capable of modifying the audit data source.
- **[SEC-7.2.2] Context Masking in Memory**: The live text input buffer and transcribed speech tokens must not be logged to system consoles, standard output streams, or crash reporting logs. Any sensitive clipboard payloads parsed by B-Siri must be held strictly in memory and cleared immediately after execution.

