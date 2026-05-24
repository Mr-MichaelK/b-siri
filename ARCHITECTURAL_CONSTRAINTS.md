# B-Siri: ARCHITECTURAL_CONSTRAINTS.md

This document defines the core engineering boundaries, concurrency guarantees, memory models, and storage constraints.

## Section 1: Concurrency and Thread Safety

### 1.1 Thread-Safe Queue Boundaries
- **[ARC-1.1.1] Main Thread Isolation**: The main SwiftUI thread must never be blocked by speech recognition, database writes, or tool execution.
- **[ARC-1.1.2] Actor-Based Concurrency**: The queue and task orchestrator must be implemented using Swift `actor` types or strict GCD Serial Dispatch queues to prevent data races.
- **[ARC-1.1.3] Task Cancellation propagation**: The system must support cooperative task cancellation. All custom actions must check for cancellation (`Task.isCancelled` in Swift) at loop and step boundaries.

### 1.2 Data Persistence Boundaries
- **[ARC-1.2.1] Hybrid Queue Persistence**: 
  - The live task queue memory footprint must be lightweight and transient.
  - SQLite database writes for logging task state transitions and interrupts must be dispatched asynchronously to a dedicated database background queue.

## Section 2: Accessibility Browser Wrapper

### 2.1 Performance & Latency Constraints
- **[ARC-2.1.1] AX Query Optimization**: Searching the accessibility tree (`AXUIElement`) can be slow. The browser wrapper must employ caching strategies (e.g., cache static elements during navigation state staticity) and limit tree traversal depth.
- **[ARC-2.1.2] Asynchronous UI Querying**: All `AXUIElement` queries and actions must run on a background concurrent queue, since accessibility requests block if the target app (Safari/Chrome) is busy.

### 2.2 Framework & API Constraints
- **[ARC-2.2.1] Native API Usage**: Use macOS `ApplicationServices` / `AXUIElement` APIs directly (bridged to Swift or Node.js) rather than spawning AppleScript/JXA wrappers for page interactions.
- **[ARC-2.2.2] Fallback JXA boundaries**: JXA or AppleScript may only be used for querying tab metadata (active tab URL, title, or creating a new tab), never for reading or clicking inside the page.

## Section 3: Ephemeral Vision Fallback

### 3.1 Screenshot Capture Constraints
- **[ARC-3.1.1] Focused Window Only**: Screenshots must capture only the frontmost focused window (`CGWindowListCreateImage` with `kCGWindowListOptionIncludingWindow`), never the full display, to minimise data footprint and avoid capturing unrelated private information.
- **[ARC-3.1.2] In-Memory First**: Raw image buffers (`CGImageRef`) must be held in-memory and must not be written to disk unless the Vision/VLM pipeline explicitly requires a file path, in which case a sandboxed temp file must be used and immediately deleted upon pipeline completion.

### 3.2 Vision Pipeline Routing
- **[ARC-3.2.1] Sequential Phase Evaluation**: Phase 1 (VNRecognizeTextRequest OCR) must complete and its confidence score evaluated before Phase 2 (local VLM) is invoked. Phase 2 is only triggered if OCR confidence or result completeness falls below an acceptable threshold.
- **[ARC-3.2.2] Local VLM Endpoint Abstraction**: The local VLM must be accessed via a standard REST interface (Ollama-compatible `/api/generate` or `/api/chat`). The endpoint URL must be user-configurable, with no hardcoded dependency on a specific model or server port.

## Section 4: Model Orchestrator

### 4.1 Backend Abstraction Layer
- **[ARC-4.1.1] Unified Adapter Interface**: The orchestrator must implement a single `LLMAdapter` protocol with two concrete implementations: `MLXLMAdapter` (primary) and `OllamaAdapter` (fallback). All inference calls must route through this abstraction; no caller may reference a specific backend directly.
- **[ARC-4.1.2] Health-Check on Startup**: On launch, the orchestrator must perform a lightweight health-check ping against the MLX-LM server endpoint. If no 200 response is received within a configurable timeout (default: 2s), it must automatically activate the Ollama adapter.
- **[ARC-4.1.3] OpenAI Wire Format**: Both adapters must translate to/from the OpenAI Chat Completions wire format (`/v1/chat/completions`). MLX-LM server natively supports this; the Ollama adapter must translate Ollama’s `/api/chat` responses to the same schema.

### 4.2 Context Construction Performance
- **[ARC-4.2.1] RAG Budget Cap**: The orchestrator must enforce a maximum token budget for RAG-injected context (e.g., 2048 tokens). Summaries must be ranked by cosine similarity and truncated to fit within the budget before injection.
- **[ARC-4.2.2] System State Snapshot**: Active system state (frontmost app bundle ID, window title, active AX element hint) must be captured as a lightweight struct and serialized to JSON for inclusion in each context payload.

### 4.3 SQLite-vec Integration
- **[ARC-4.3.1] Single Database File**: The sqlite-vec extension must be loaded as a runtime extension into the existing SQLite connection. No secondary `.db` file may be created for embeddings.
- **[ARC-4.3.2] Embedding Dimensionality Lock**: The embedding dimension (e.g., 768 for nomic-embed-text) must be stored in a `db_config` table and validated on startup. If it changes (model swap), existing vectors must be migrated or the embedding table dropped and rebuilt. During a model-swap migration or embedding table rebuild, the Model Orchestrator must enter a temporary pass-through mode, pausing all semantic RAG queries until the background DatabaseActor signals that vector re-indexing is 100% complete.

## Section 5: Dual-Phase Security Broker

### 5.1 Broker Pipeline Architecture
- **[ARC-5.1.1] Synchronous Interception**: The Security Broker must be a synchronous, blocking step in the execution pipeline. The execution engine must await broker clearance before dispatching any tool call to the System Bridge.
- **[ARC-5.1.2] Immutable Denylist Binary**: The High-tier denylist must be compiled into the app binary as a constant data structure (e.g., Swift `let` array of `SecurityRule` structs). It must not be loaded from any external file, network resource, or user-writable path.
- **[ARC-5.1.3] Allowlist File Sandboxing**: The Medium-tier user-editable allowlist file must reside in the app's sandboxed `Application Support` container (`~/Library/Application Support/B-Siri/allowlist.json`). Writes to this file from outside the app process must be rejected by the sandbox. Committing modifications to the allowlist.json file from the Preferences UI must utilize an atomic safe-save pattern (writing to a temp file, validating schema conformance, then executing an atomic filesystem replacement via FileManager) to guarantee file integrity.

### 5.2 Pattern Matching Engine
- **[ARC-5.2.1] Two-Pass Evaluation**: Pass 1 matches the tool name against the tier lookup table. Pass 2 applies compiled `NSRegularExpression` patterns against each argument field string. The result is `max(pass1Tier, pass2Tier)`.
- **[ARC-5.2.2] Fail-Closed Default**: If the broker encounters any evaluation error, exception, or unparseable tool call JSON, it must default to High tier and block execution pending explicit user approval.

### 5.3 UI Authorization Layer
- **[ARC-5.3.1] Main-Thread UI Suspension**: Presentation of an NSAlert modal window must be dispatched to the MainActor. The calling background queue task must be suspended using a non-blocking asynchronous primitive (`withCheckedContinuation`), explicitly avoiding primitive OS locks or DispatchSemaphores that cause Swift thread pool starvation.
- **[ARC-5.3.2] Denial Audit Log**: Every denied tool call must be written to an `audit_log` SQLite table with: timestamp, tool name, full argument JSON, matched pattern, and deny reason. This table must not be subject to the 500MB sliding window pruning.

## Section 6: Storage Architecture Constraints

### 6.1 Concurrency & Integrity
- **[ARC-6.1.1] Single Writer**: SQLite WAL mode permits multiple concurrent readers but enforces a single writer at a time. All write operations (task log, chat history, embeddings) must be serialised through a dedicated background `DatabaseActor`; no two writers may hold a write lock simultaneously.
- **[ARC-6.1.2] Foreign Key Enforcement**: `PRAGMA foreign_keys = ON` must be set on every SQLite connection open. The self-referencing `chat_history.parent_context_id` foreign key with `ON DELETE CASCADE` is the sole mechanism for Phase 2 thread group deletion integrity.
- **[ARC-6.1.3] Transaction Atomicity**: Phase 2 pruning deletes must each execute within `BEGIN IMMEDIATE ... COMMIT` transactions. If any transaction fails mid-sweep, the entire pruning operation must roll back the current transaction and terminate gracefully, leaving the database in a valid state.

### 6.2 Size Cap Enforcement
- **[ARC-6.2.1] Audit Log Expansion Threshold**: The 500MB cap remains a hard architectural ceiling. If the un-prunable `audit_log` table reaches a 400MB threshold, the application must intercept startup or termination and dispatch a native macOS system notification alerting the user that administrative intervention or log exporting is required via the Preferences UI to preserve storage clearance.
- **[ARC-6.2.2] WAL Journal Inclusion**: File size checks must sum the `.db` file size and the `.db-wal` file size (if it exists) to get the true footprint.

## Section 7: UI/UX Architecture Constraints

### 7.1 Window Management
- **[ARC-7.1.1] Floating NSPanel Subclass**: The overlay input window must be implemented as an `NSPanel` subclass configured with the styles `.nonactivatingPanel`, `.borderless`, `.utilityWindow`, and `.hudWindow` to allow it to float above full-screen applications without appearing in the Dock or window switcher.
- **[ARC-7.1.2] Automatic Dismissal**: The overlay panel must set `hidesOnDeactivate = true` so that clicking outside the panel boundaries or switching applications automatically dismisses it.
- **[ARC-7.1.3] Visual Effect Material**: The background must employ `NSVisualEffectView` with `.behindWindow` blending mode and material `.hudWindow` (dark or light mode adaptive) to create a premium glassmorphic appearance.

### 7.2 Input & Telemetry Performance
- **[ARC-7.2.1] Low-Latency Hotkey Registration**: Global hotkey detection must be implemented using macOS Carbon APIs (`RegisterEventHotKey`) to ensure near-zero latency interception of `Option + Space` even when the app is inactive.
- **[ARC-7.2.2] Throttled Waveform Updates**: Decibel levels from the active audio input stream must be calculated on a background serial utility queue and dispatched to the main UI thread at a throttled rate not exceeding 60Hz.

### 7.3 Settings & Audit Safety
- **[ARC-7.3.1] Thread-Isolated Preferences**: Model and API configuration changes made in settings must be written atomically to `UserDefaults` (or SQLite config table) and broadcast via a thread-safe notification system so running instances of the orchestrator update their state immediately.
- **[ARC-7.3.2] Lazy-Loaded Audit Logs**: The audit log grid must use SwiftUI's `LazyVStack` or `Table` with row virtualization to ensure that fetching and rendering thousands of history events does not block the UI thread or cause hitching.

