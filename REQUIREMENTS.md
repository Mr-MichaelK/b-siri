# B-Siri: REQUIREMENTS.md

This document serves as the uncompromised functional requirements contract for the B-Siri implementation.

## Section 1: Ingestion and the Asynchronous Interrupt Queue

### 1.1 Ingestion Interfaces
- **[REQ-1.1.1] Text Input Ingestion**: The system must provide a desktop UI text entry box allowing the user to type natural language commands.
- **[REQ-1.1.2] Local Voice Ingestion**: The system must support voice command input.
  - Speech-to-Text (STT) must run entirely on-device utilizing Apple's native `SFSpeechRecognizer` framework.
  - The voice ingestion engine must leverage Apple Silicon's neural engine for hardware-accelerated, offline speech-to-text decoding.
  - A visual waveform or indicator must display transcription feedback in real time. The speech configuration must pass an explicit domain-specific terminology array (including common terminal commands, programming terms, and project keywords) to the recognizer to optimize technical transcription accuracy.

### 1.2 Interrupt & Execution Queue
- **[REQ-1.2.1] Asynchronous Queue**: All user inputs must be ingested into a thread-safe task queue to prevent locking the main SwiftUI thread.
- **[REQ-1.2.2] Interactive Interrupt**: Users must be able to issue a new command while the agent is actively executing a task.
- **[REQ-1.2.3] Soft Cancellation at Step Boundaries**: 
  - When an interrupt is received, the active tool/script step (e.g., shell command, JXA script, or accessibility interaction) is permitted to run to completion.
  - Upon completion of the active step, the remaining execution plan is aborted.
  - The system then immediately switches context to process the new user command.
- **[REQ-1.2.4] Queue State Persistency (Hybrid)**:
  - The active execution queue remains in-memory.
  - Every incoming command, task execution state transition (Pending, Running, Aborted, Succeeded), and interrupt event must be immediately persisted to the local SQLite database.

## Section 2: Accessibility Browser Wrapper

### 2.1 Target Browser Integration
- **[REQ-2.1.1] Browser Support**: The browser wrapper must support both Safari and Google Chrome on macOS.
- **[REQ-2.1.2] State Retrieval**: The system must be able to retrieve the URL and window/tab title of the active tab in Safari and Chrome.

### 2.2 Accessibility Tree Interactivity
- **[REQ-2.2.1] Strict AXTree Interaction**: All interactions (clicking links/buttons, typing into fields, scrolling, reading text content) must be performed strictly using macOS Accessibility APIs (`AXUIElement`).
- **[REQ-2.2.2] No JXA DOM Injection**: The system must not execute JavaScript inside the web page context (no JXA script injection for DOM manipulation), preserving the browser's security boundaries.

### 2.3 Semantic Element Matching
- **[REQ-2.3.1] Role and Attribute Filtering**: Interactive elements must be discovered by querying the AX tree for elements matching roles like `AXTextField`, `AXButton`, `AXLink`, etc.
- **[REQ-2.3.2] Text/Label Matching**: Elements must be matched to user intents based on attributes such as accessibility label, title, placeholder text, and values.

## Section 3: Ephemeral Vision Fallback

### 3.1 Trigger Conditions
- **[REQ-3.1.1] Contextual Triggering**: The Model Orchestrator is responsible for evaluating whether the active application is a non-DOM, non-accessible native app. If the AX tree is too sparse or element descriptions are insufficient, it must automatically trigger a focused window screenshot — not a full-screen capture.

### 3.2 Vision Analysis Engine
- **[REQ-3.2.1] Phase 1 — Native OCR**: Use macOS Vision framework (`VNRecognizeTextRequest`) as the primary OCR/text-extraction method for captured screenshots.
- **[REQ-3.2.2] Phase 2 — Local VLM Fallback**: If native OCR is insufficient (e.g., for complex UI layout understanding), route the screenshot to a locally running multimodal endpoint (Ollama/llama.cpp serving LLaVA, Moondream, or equivalent). No external API calls are permitted.

### 3.3 Purge Policy
- **[REQ-3.3.1] Immediate Purge**: Raw screenshot data (PNG/JPEG buffer, and any temp disk write) must be securely deleted the moment the vision extraction result is returned to the orchestrator. The extracted text/metadata result may be retained in the conversation context, but the raw image must not persist.

## Section 4: Model Orchestrator

### 4.1 LLM Backend
- **[REQ-4.1.1] Primary Runtime — Apple MLX-LM**: B-Siri must connect to a locally running `mlx_lm.server` instance as its primary inference backend. This provides Apple Silicon-optimised Metal GPU acceleration.
- **[REQ-4.1.2] Fallback Runtime — Ollama**: If the MLX-LM server is unavailable or unresponsive, the orchestrator must automatically fall back to a locally running Ollama instance.
- **[REQ-4.1.3] Zero Hardcoded Models**: The active model name must be user-configurable (e.g., `mlx-community/gemma-4-it-4bit`). The orchestrator must never hardcode a model identifier.

### 4.2 Tool Call Protocol
- **[REQ-4.2.1] OpenAI-Compatible Function Calling**: All tool call requests must be structured using the OpenAI function-calling format (`tools[]` array in the chat request, `tool_calls[]` in the assistant response). This ensures portability across MLX-LM, Ollama, and any future backend.
- **[REQ-4.2.2] Security Field Mapping**: The `securityClearanceRequirement` field defined in the spec's tool schema must be injected as a metadata field within the OpenAI tool definition's `description` or a custom `metadata` property, so the Security Broker can read it before execution.

### 4.3 Local RAG
- **[REQ-4.3.1] SQLite-vec Embeddings**: All conversation semantic summaries must be embedded and stored as vector BLOBs in the existing SQLite database using the `sqlite-vec` extension. No separate vector database process is permitted.
- **[REQ-4.3.2] Embedding Model**: Embeddings must be generated by a local model (e.g., `nomic-embed-text` or `mxbai-embed-large`) running on the same Ollama or MLX-LM instance used for inference.
- **[REQ-4.3.3] RAG-Only Context Restoration**: The orchestrator must not maintain a persistent KV-cache or session between inference calls. Thread history must be restored exclusively by retrieving semantically relevant summaries from SQLite-vec at the start of each inference cycle.

### 4.4 Context Window Construction
- **[REQ-4.4.1] Stateless Per-Inference**: Every inference request must begin with a freshly constructed context containing: (1) the static system prompt, (2) RAG-retrieved relevant thread summaries, (3) the current task payload, and (4) active system state (focused app, frontmost window title).

## Section 5: Dual-Phase Security Broker

### 5.1 Tier Classification System
- **[REQ-5.1.1] Hardcoded Denylist (High)**: A compile-time, developer-audited denylist defines High security operations. Includes: destructive shell commands (`rm`, `rmdir`, `dd`, `mkfs`), privacy-affecting configs (`chmod`, `chown` on system paths), `sudo`/privilege escalation, writes to `~/.ssh`, `/System`, `/Library`, `/private`, and any `kill -9` against non-B-Siri PIDs. This list cannot be modified at runtime.
- **[REQ-5.1.2] User-Editable Allowlist (Medium)**: A user-editable plist/JSON file defines which Medium-tier operations auto-approve silently (e.g., creating files in `~/Documents`, opening specific apps). Operations not on the allowlist require UI banner confirmation as specified in [REQ-5.3.3].
- **[REQ-5.1.3] Low Security (Silent)**: Read-only operations (`ls`, `pwd`, `cat`, `open` for viewing, AX read queries) execute immediately with no user prompt.
- **[REQ-5.1.4] Secure Field Masking**: Any accessibility element resolving to a secure text field or password type role must be structurally hidden from data collection; any tool attempt to read values from an AXSecureTextField must trigger an immediate High-tier security rejection.

### 5.2 Argument-Level Inspection
- **[REQ-5.2.1] Two-Dimensional Classification**: Every tool call must be evaluated on both its tool name AND its argument values. The final assigned tier must be the maximum (highest) tier matched by either dimension.
- **[REQ-5.2.2] Pattern Matching Rules**: The broker must apply regex/glob pattern rules against payload strings and `targetApplication`, `axElementCoordinates`, and `actionType` fields before any execution.
- **[REQ-5.2.3] Escalation on Match**: If any argument substring matches a High-tier pattern, the entire tool call is escalated to High regardless of the declared `securityClearanceRequirement` field in the LLM's tool call.

### 5.3 Human-in-the-Loop Authorization
- **[REQ-5.3.1] NSAlert Modal for High-Tier**: High security operations must present a native macOS `NSAlert` modal dialog. The dialog must display: the tool name, the full argument payload, the matched denylist pattern that triggered escalation, and Approve / Deny buttons.
- **[REQ-5.3.2] Execution Block**: Execution of the tool must be fully suspended while the alert is visible. A denied action must be logged to SQLite and the orchestrator informed to abandon the current plan step.
- **[REQ-5.3.3] Medium-Tier Confirmation**: Medium-tier operations not on the user allowlist must present a lightweight, non-blocking UI banner (not a modal) requesting confirmation before execution.

## Section 6: Storage, SQLite Schema & 500MB Pruning Ring Buffer

### 6.1 Database Organisation
- **[REQ-6.1.1] Single Encrypted SQLite File**: All persistent data (chat history, embeddings, audit log, task queue log, db config) must reside in a single SQLite `.db` file encrypted with SQLCipher (AES-256). The encryption key is stored in the macOS Keychain.
- **[REQ-6.1.2] WAL Mode**: The database must operate in Write-Ahead Logging (WAL) mode to allow concurrent reads during background writes without blocking the main thread.
- **[REQ-6.1.3] Tables**: The database must contain at minimum: `chat_history`, `embeddings`, `audit_log`, `task_queue_log`, `db_config`.

### 6.2 Storage Cap Measurement
- **[REQ-6.2.1] Filesystem Stat**: Storage footprint must be measured using `FileManager.attributesOfItem(atPath:)` against the `.db` file path, capturing the true on-disk size including the WAL journal. This check runs at startup and every 30 minutes during the session.

### 6.3 Pruning Strategy
- **[REQ-6.3.1] Phase 1 (Background, Every 30 min)**: Delete orphan `chat_history` rows where `parent_context_id` references a non-existent record (broken thread roots with no children). Run as a background task; does not require the app to be closing.
- **[REQ-6.3.2] Phase 2 (Termination, Oldest-First)**: On `NSApplicationWillTerminate`, if total file size exceeds 500MB after Phase 1: identify the root `prompt_id` of each thread group, order groups ascending by their earliest `timestamp`, and issue `DELETE FROM chat_history WHERE prompt_id = ?` (cascading via foreign keys) until the cap is met. Each group deletion must be wrapped in its own `BEGIN IMMEDIATE ... COMMIT` transaction to prevent partial deletes. If a single thread group's size exceeds the 500MB boundary, the truncation loop must aggressively truncate the internal row arrays of that specific thread group by oldest message blocks first, avoiding complete history erasure.
- **[REQ-6.3.3] Audit Log Exemption**: The `audit_log` table is fully exempt from both Phase 1 and Phase 2 pruning. It must never be included in size calculations that trigger cascade deletes.
- **[REQ-6.3.4] VACUUM After Pruning**: After Phase 2 completes, the system must issue `PRAGMA wal_checkpoint(TRUNCATE)` followed by `VACUUM` to reclaim disk space before the process exits.

## Section 7: UI/UX Layer

### 7.1 Active UI Presentation
- **[REQ-7.1.1] Menu Bar Extra & Hotkey Activation**: The application must run as a macOS Menu Bar Extra with a native status icon. It must support a global hotkey activation (default `Option + Space`) to summon the primary entry window.
- **[REQ-7.1.2] Spotlight-Style Floating Entry**: The primary input interface must be a centered, translucent floating overlay panel (Spotlight-style visual layout) containing the voice activation button and text entry field.
- **[REQ-7.1.3] Dynamic Expansion**: The entry panel must expand vertically downwards to display active execution steps, feedback logs, and final natural language responses without stealing user focus from current application tasks.

### 7.2 Ingest and Visual Feedback
- **[REQ-7.2.1] Real-Time Waveform Animation**: During voice ingestion, the panel must render an animated Siri-style sound wave (tailored using HSL-based colored lines) whose amplitude and frequency respond dynamically in real time to microphone volume (decibel) inputs.
- **[REQ-7.2.2] Real-Time Ghost Text Subtitles**: As speech is transcribed word-by-word by the local speech recognizer, greyed-out ghost text must appear inside the text input box, turning into solid editable text once voice input terminates.

### 7.3 Multi-Step Execution Feedback
- **[REQ-7.3.1] Interactive Step Checklist**: Multi-step plans generated by the Model Orchestrator must be rendered as an interactive checklist. Each item must show a status icon: spinner (in progress), checkmark (success), or warning/X (aborted/denied).
- **[REQ-7.3.2] Nested Console Log Drawer**: Clicking or tapping any step in the execution checklist must expand a nested, scrollable detail drawer showing raw console stdout, stderr, or JXA parameters corresponding to that specific script execution step.

### 7.4 Multi-Tab Settings Preferences
- **[REQ-7.4.1] Multi-Tab Preferences Layout**: The app must provide a standard macOS multi-tab preferences window.
- **[REQ-7.4.2] Model & API Tab**: Users must be able to configure the model names, endpoints (MLX-LM, Ollama, custom server ports), and check server health connection status.
- **[REQ-7.4.3] Security Allowlist Tab**: Users must be able to view and modify the allowed directories, allowed terminal commands, and browser targets using interactive data tables with (+) and (-) buttons.
- **[REQ-7.4.4] Audit Log Tab**: The Preferences window must include an Audit Logs tab displaying the tamper-evident records.

### 7.5 Audit Log Viewer UI
- **[REQ-7.5.1] Searchable Audit Grid**: The Audit Logs tab must display a table grid showing: Timestamp, Tier, Action (Tool), and Outcome (Approved/Denied). It must support text search filtering and filtering by security clearance tier.
- **[REQ-7.5.2] Detail Inspector Panel**: Selecting any row in the audit grid must open a side-by-side split detail inspector displaying the full raw JSON payload, evaluated arguments, and the exact security policy rule or denylist pattern that triggered the authorization gate.

