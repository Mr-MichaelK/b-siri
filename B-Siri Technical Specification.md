# **B-Siri: Native Local System Orchestrator**

## **Technical Specification & Architecture Blueprint**

## **1\. Executive Summary & Introduction**

### **1.1 Project Vision**

B-Siri ("Better Siri") is a native, privacy-first desktop agent designed to execute system-level actions and web automation via local Large Language Models (LLMs). Operating exclusively on Apple hardware, it leverages the unified memory architecture of Apple Silicon to run sophisticated models locally. This approach ensures zero-latency execution, complete data privacy, and a deep, unrestricted integration with the macOS operating system.

### **1.2 Core Philosophy**

The system is built upon four foundational pillars: local computation, zero-latency execution, robust sandbox boundaries, and deep operating system integration. Unlike cloud-dependent counterparts, B-Siri is engineered to be an offline-capable sovereign assistant. It prioritizes structural Document Object Model (DOM) and Accessibility (AX) tree manipulation over computationally expensive computer vision parsing, employing visual screenshot analysis strictly as a localized fallback.

### **1.3 Scope of Document**

This monolithic blueprint covers the system architecture, state machines, inter-process communication protocols, and data persistence layers required to implement B-Siri using Google Antigravity 2.0. It serves as the primary architectural contract for all subsequent development phases and autonomous coding agents.

## **2\. Problem Statement & Market Landscape**

### **2.1 The Friction of Modern Agentic Frameworks**

Existing macro-automation platforms, such as OpenClaw, serve as broad "AI operating systems" designed to connect third-party messaging services to shell environments and thousands of external SaaS plugins. While powerful, they introduce severe friction for dedicated workstation orchestration: loose trust models, chaotic external plugin marketplaces, heavy external gateway routing, and vulnerability to prompt injection from unverified internet sources. They sacrifice local security for broad web connectivity.

### **2.2 The Solution**

B-Siri provides a decoupled, memory-efficient, compile-time-safe orchestrator. It bridges natural language instructions into precise native macOS scripting (AppleScript, JXA, Bash) while remaining completely sandboxed. It achieves high capability without the architectural bloat or security pitfalls of decentralized plugin hubs.

## **3\. System Architecture & Core Engine**

### **3.1 High-Level Component Topology**

The architecture is divided into three primary execution boundaries:

* **The User Interface & Ingestion Layer:** Handles asynchronous voice and text inputs, maintaining the interactive interrupt queue.  
* **The Model Orchestrator:** A model-agnostic server adapter communicating with the LLM (e.g., Gemma 4\) via standardized APIs. It manages the stateless context window and local Retrieval-Augmented Generation (RAG).  
* **The System Bridge:** The execution layer comprising the Security Broker and macOS Accessibility Wrappers, responsible for translating LLM intents into verifiable native actions.

### **3.2 Execution Cycle (The Orchestration Loop)**

1. **Intent Capture:** Streaming parser interprets user command (audio/text).  
2. **Context Compilation:** System queries SQLite DB for related thread history and injects it alongside active system state (e.g., focused app).  
3. **Inference:** The stateless model generates a structured JSON tool call.  
4. **Security Validation:** The intent is passed through the Dual-Phase Security Broker.  
5. **Execution:** The native script runs; state and screen updates are fed back into the memory buffer.

## **4\. Comprehensive Feature Matrix & Functional Specifications**

| Feature Module | Functional Description   |
| :---- | :---- |
| Asynchronous Interrupt Queue | Thread-safe message queue allows user input to interrupt or append to active agent actions without locking the main thread. |
| Accessibility Browser Wrapper | Uses macOS AXUIElement APIs to manipulate the user's active browser, fully inheriting existing cookie authentication profiles without locks. |
| Ephemeral Vision Fallback | Captures high-res screenshots for non-DOM apps, extracts metadata via vision models, and immediately purges raw images post-task. |

## **5\. Implementation Methodology & Technology Stack**

### **5.1 Language & Framework Selection**

* **Core Application:** Swift / Node.js (via Antigravity frameworks).  
* **Native Automation:** AppleScript, JavaScript for Automation (JXA), and macOS ApplicationServices (AXUI).  
* **Data Persistence:** SQLite configured with self-referencing foreign keys for relational thread management.

### **5.2 The 500MB Sliding Storage Ring Buffer**

To prevent the system from consuming excessive storage, a background garbage collection daemon enforces a strict 500MB cap on all historical data and assets. When the application window closes (NSApplicationWillTerminate) and the cap is exceeded, a two-phase atomic cascade delete triggers: Phase 1 prunes context-free history; Phase 2 purges entire conversational thread groups atomically to prevent model hallucination from fractured contexts.

## **6\. Data Models, Schemas, & State Machines**

### **6.1 Tool Call Schema Contract**

The standard schema enforcing model-to-system translation.

{  
  "tool": "SystemScriptExecutor",  
  "arguments": {  
    "targetApplication": "String",  
    "axElementCoordinates": {  
      "x": "Integer",  
      "y": "Integer"  
    },  
    "actionType": "Click | Input | Scroll | Read",  
    "payload": "String"  
  },  
  "securityClearanceRequirement": "Low | Medium | High"  
}

### **6.2 Threaded History Relational Schema (SQLite)**

This schema ensures complete thread safety during Phase 2 storage pruning.

CREATE TABLE chat\_history (  
    prompt\_id UUID PRIMARY KEY,  
    parent\_context\_id UUID NULL,  
    timestamp DATETIME DEFAULT CURRENT\_TIMESTAMP,  
    semantic\_summary TEXT,  
    payload\_data BLOB,  
    FOREIGN KEY(parent\_context\_id) REFERENCES chat\_history(prompt\_id) ON DELETE CASCADE  
);

## **7\. Security Architecture & Threat Modeling**

### **7.1 Dual-Phase Security Broker**

A mandatory interception layer between the model's generated intent and the OS terminal.

* **Low Security (Allowlist):** Read-only operations (\`ls\`, \`pwd\`, interface reading). Executes silently.  
* **Medium Security:** General app interactions, basic file writes. Requires verbal confirmation or simple UI acknowledgment.  
* **High Security (Denylist Interception):** Destructive commands (\`rm\`, privacy configurations). Execution blocks entirely until explicit human-in-the-loop authorization is granted via iOS/Apple Watch push notification relays.

## **8\. Non-Functional Requirements & Performance Milestones**

| Metric | Constraint   |
| :---- | :---- |
| Maximum Storage Footprint | Strictly capped at 500MB; sliding window pruning on termination. |
| Context State Flush | Memory must be flushed pre-inference; state restored purely via RAG. |
| Model Isolation | Zero hardcoded dependencies. Must interface over standard REST API formats. |

**Document Status: Finalized for Implementation Phase.**