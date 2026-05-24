# B-Siri: MCP_ROUTING.md

This document maps standard tool calls and user intents to specific local MCP servers and native OS interfaces.

## Section 1: Ingestion Routing

### 1.1 Ingestion Interface Mapping
- **[MCP-1.1.1] Audio Ingestion Hook**: Native Swift Audio Session stream -> Apple `SFSpeechAudioBufferRecognitionRequest` -> Local Apple Speech Recognizer.
- **[MCP-1.1.2] Task Dispatcher Routing**: Local SwiftUI client text input / transcribed text -> In-Memory Queue Actor -> Local REST API / Socket channel -> Local Model Orchestrator endpoint.

## Section 2: Accessibility Browser Routing

### 2.1 Tool-to-Native API Mapping
- **[MCP-2.1.1] Browser Element Query**: LLM tool call -> `AXUIElementCopyAttributeValue` / `AXUIElementCopyAttributeNames` down the target app tree (`com.apple.Safari` or `com.google.Chrome`).
- **[MCP-2.1.2] Action Triggering**: Targeted interaction must prioritize `AXUIElementPerformAction` (e.g., kAXPressAction, kAXScrollToVisibleAction) or localized window attribute setting. Global coordinate-based `CGEvent` mouse/scroll injections are strictly forbidden to prevent event bleeding outside the target browser context.
- **[MCP-2.1.3] Metadata Queries**:
  - Safari tab query: AppleScript `tell application "Safari" to get {URL, name} of current tab of window 1`.
  - Chrome tab query: AppleScript `tell application "Google Chrome" to get {URL, title} of active tab of window 1`.
  The AppleScript execution layer must run asynchronously on a background utility queue wrapped in a strict 1-second timeout handler to prevent app freezes from blocking B-Siri's query loop.

## Section 3: Ephemeral Vision Fallback Routing

### 3.1 Vision Pipeline Routing
- **[MCP-3.1.1] Screenshot Capture**: Model Orchestrator tool call `CaptureWindowScreenshot` → `CGWindowListCreateImage` → in-memory `CGImageRef`.
- **[MCP-3.1.2] Phase 1 — OCR**: `CGImageRef` → `VNImageRequestHandler` + `VNRecognizeTextRequest` → structured text result → Orchestrator context.
- **[MCP-3.1.3] Phase 2 — Local VLM**: `CGImageRef` (Base64-encoded) → `POST http://localhost:{configuredPort}/api/chat` (Ollama-compatible) with `{model, images[], prompt}` → text result → Orchestrator context.
- **[MCP-3.1.4] Purge Trigger**: On result return from either Phase 1 or Phase 2 → immediately dereference `CGImageRef`, zero buffer, unlink any temp file.

## Section 4: Model Orchestrator Routing

### 4.1 Inference Routing
- **[MCP-4.1.1] Primary — MLX-LM**: Orchestrator → `POST http://127.0.0.1:{mlxPort}/v1/chat/completions` with OpenAI-compatible payload `{model, messages[], tools[], stream}`.
- **[MCP-4.1.2] Fallback — Ollama**: Orchestrator → `POST http://127.0.0.1:11434/api/chat` → OllamaAdapter translates response to OpenAI schema → Orchestrator.
- **[MCP-4.1.3] Health Check**: On startup → `GET http://127.0.0.1:{mlxPort}/health` with 2s timeout → if fail, activate OllamaAdapter.

### 4.2 Embedding Routing
- **[MCP-4.2.1] Embedding Generation**: Semantic summary string → `POST http://127.0.0.1:{port}/v1/embeddings` (MLX-LM primary) or `POST http://127.0.0.1:11434/api/embeddings` (Ollama fallback) → float[] vector → stored in `sqlite-vec` BLOB column.
- **[MCP-4.2.2] RAG Retrieval**: Incoming user query → embed → `SELECT ... ORDER BY vec_distance_cosine(embedding, ?) LIMIT N` in SQLite-vec → top-N summaries → injected into context window.

## Section 5: Security Broker Routing

### 5.1 Execution Interception Flow
- **[MCP-5.1.1] Pre-Execution Gate**: LLM tool call JSON → Security Broker (Pass 1: tool name lookup) → (Pass 2: argument pattern matching) → tier assignment.
- **[MCP-5.1.2] Low Tier**: Broker → silent pass-through → System Bridge executor.
- **[MCP-5.1.3] Medium Tier (Allowlisted)**: Broker → allowlist lookup hit → silent pass-through → System Bridge executor.
- **[MCP-5.1.4] Medium Tier (Not Allowlisted)**: Broker → dispatch confirmation banner to SwiftUI main thread → await user tap → approve: System Bridge executor / deny: log + abort plan step.
- **[MCP-5.1.5] High Tier**: Broker → dispatch `NSAlert` on main thread → suspend execution queue via `CheckedContinuation` → await Approve/Deny → approve: System Bridge executor / deny: write to `audit_log` table + abort plan step + inform orchestrator.
- **[MCP-5.1.6] Fail-Closed**: Any broker evaluation error → treat as High tier → route to NSAlert flow.

## Section 6: Storage & Pruning Routing

### 6.1 Database Operations Routing
- **[MCP-6.1.1] Database Thread-Safe Access**: Any component requesting DB read/write → routed through `DatabaseActor` (Swift Concurrency Actor) → SQLCipher SQLite connection.
- **[MCP-6.1.2] Embeddings Vector Search**: Orchestrator RAG search query → routed to `sqlite-vec` extension on the active SQLite connection → cosine distance similarity query on the `embeddings` table.

### 6.2 Pruning Execution Routing
- **[MCP-6.2.1] Phase 1 Background Execution**: App lifecycle manager timer → trigger `DatabaseActor.pruneOrphanRows()` → run `DELETE FROM chat_history WHERE parent_context_id IS NOT NULL AND parent_context_id NOT IN (SELECT prompt_id FROM chat_history)` in background thread.
- **[MCP-6.2.2] Phase 2 Termination Execution**: App delegate hook `applicationWillTerminate(_:)` → block termination → query `FileManager` size → if size > 500MB → trigger `DatabaseActor.pruneOldestThreadsUntilUnderCap()` → loop deletion transactions → `PRAGMA wal_checkpoint(TRUNCATE)` + `VACUUM` → allow termination to proceed.

## Section 7: UI/UX Routing

### 7.1 Panel Activation & Audio Routing
- **[MCP-7.1.1] Overlay Activation Route**: Option + Space Carbon event listener keypress → route to `AppCoordinator` / `OverlayPanelController` → `makeKeyAndOrderFront(_:)` on the floating `NSPanel`.
- **[MCP-7.1.2] Speech Visualization Route**: Microphone active channel -> AVAudioEngine input node real-time tap callback -> Lock-free scalar decibel power extraction -> Throttled 60Hz MainActor dispatch -> SwiftUI WaveformView State bindings, ensuring no heap allocations occur on the audio execution thread.

### 7.2 Settings & Audit Log Data Routing
- **[MCP-7.2.1] Settings Navigation Route**: Menu bar menu item / `⌘,` keyboard shortcut → route to `PreferencesWindowController` → load Tab View controller (Model API, Allowlist, Audit Logs).
- **[MCP-7.2.2] Audit Grid Query Route**: Settings view loaded / search bar query input → dispatch SQLite query (`SELECT * FROM audit_log WHERE ...`) strictly on read-only connection → publish to `AuditLogsView` virtual table data source.
- **[MCP-7.2.3] Allowlist Modification Route**: Interactive table Add/Remove action -> Validate schema -> Atomic safe-save pattern writing directly to `~/Library/Application Support/B-Siri/allowlist.json` -> Security Broker re-caches active file definitions in-memory.
