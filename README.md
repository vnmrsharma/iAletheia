# iAletheia

**iAletheia** (Greek: ἀλήθεια — truth, un-forgetting) is a privacy-first **personal agent for macOS**.

It quietly learns from your screen, builds a private local memory, and answers with what you were actually working on — including **live screen awareness** (see the active window, draft email replies, review code) and **Qwen Cloud** for reasoning and web search.

Built for **Track 1: MemoryAgent** — [Global AI Hackathon Series with Qwen Cloud](https://qwencloud-hackathon.devpost.com/).

<p align="center">
  <img src="Sources/iAletheia/Resources/AppIcon.png" alt="iAletheia icon" width="128" />
</p>

---

## Highlights

| Capability | What you get |
|---|---|
| **Personal memory** | Screen → OCR / Accessibility → local SQLite + FTS5 (screenshots never saved) |
| **Live screen** | “What’s on my screen?” / “Draft a reply to this email” uses the **frontmost** window |
| **Show Me** | Step-by-step on-screen instructor (pointer + chat) — guides you, never clicks for you |
| **Session chat** | Multi-turn awareness in the current chat; full **Chat History** of past sessions |
| **Smart routing** | Direct · memory · live screen · web · hybrid — via Qwen when configured |
| **Privacy** | Redaction, exclusions, local storage under Application Support |

---

## Demo prompts

| Type | Example |
|---|---|
| Live screen | “Can you see my screen?” |
| Show Me | Toggle **Show Me**, then “Where can I find Capitalize?” |
| Email assist | “Draft a reply for this email” |
| Code context | “What am I looking at?” → “Is there any error in this?” |
| Personal recall | “What was I researching about storage yesterday?” |
| Live web | “What’s new with Qwen Cloud this month?” |
| Hybrid | “Compare what I read about HBM with current GPU specs” |

---

## Architecture Diagram

System overview for [Track 1: MemoryAgent](https://qwencloud-hackathon.devpost.com/) — how the **frontend**, **local backend**, **database**, and **Qwen Cloud** connect.

<p align="center">
  <img src="docs/architecture-diagram.png" alt="iAletheia system architecture: Frontend → Local Backend → SQLite → Qwen Cloud" width="900" />
</p>

```mermaid
flowchart TB
    subgraph Frontend["Frontend · SwiftUI macOS"]
        Owl["Floating Owl Widget"]
        Main["Main App<br/>Home · Chat · Memories · Settings"]
        ShowMeUI["Show Me Overlay<br/>pointer + coach card"]
        ChatUI["Chat UI<br/>sessions · history · feedback"]
    end

    subgraph Backend["Local Backend · Swift / AppState"]
        Agent["PersonalAgent<br/>orchestrator"]
        Router["QueryRouter<br/>direct · memory · live · web · hybrid"]
        Observe["ObservationPipeline<br/>~2s screen → text"]
        Capture["Capture<br/>ScreenCaptureKit · AX · Vision OCR"]
        Privacy["PrivacyFilter + Redaction"]
        MemorySvc["Memory services<br/>extract · admit · dedupe · decay · entities"]
        Retrieve["HybridRetriever<br/>FTS5 + on-device vectors"]
        ShowMe["ShowMePlanner<br/>steps + target finder"]
        QwenClient["QwenClient<br/>DashScope HTTP client"]
    end

    subgraph Database["Local Database<br/>~/Library/Application Support/iAletheia/"]
        SQLite[("SQLite")]
        Mem["memories + FTS5"]
        ChatDB["chat_sessions · chat_messages"]
        Obs["observations metadata"]
        Vec["VectorStore<br/>Apple NaturalLanguage embeddings"]
    end

    subgraph QwenCloud["Qwen Cloud · Alibaba DashScope"]
        ChatAPI["Chat Completions<br/>qwen3.7-plus"]
        VL["Vision / multimodal<br/>optional live-screen path"]
        Search["Web Search<br/>enable_search / Responses API"]
    end

    Owl --> ChatUI
    Main --> ChatUI
    ChatUI --> Agent
    Main --> ShowMe
    ShowMe --> ShowMeUI

    Agent --> Router
    Router --> Retrieve
    Router --> Observe
    Router --> QwenClient
    Agent --> QwenClient
    ShowMe --> QwenClient
    ShowMe --> Capture

    Observe --> Capture
    Capture --> Privacy
    Privacy --> MemorySvc
    MemorySvc --> SQLite
    Retrieve --> SQLite
    Retrieve --> Vec
    Agent --> ChatDB
    MemorySvc --> Mem
    Observe --> Obs
    Vec --> Mem

    QwenClient -->|"HTTPS · API key"| ChatAPI
    QwenClient --> VL
    QwenClient --> Search

    ChatAPI -->|"grounded answer"| Agent
    Search -->|"citations"| Agent
    Agent --> ChatUI
```

### Request path (ask / follow-up)

```text
  User (Owl / Main Chat)
           │
           ▼
  PersonalAgent ──► QueryRouter (Qwen-assisted when configured)
           │
           ├── memory   → HybridRetriever → SQLite FTS5 + vectors
           ├── live     → ObservationPipeline → frontmost window text
           ├── web      → Qwen Cloud web_search
           └── hybrid   → memory + live and/or web
           │
           ▼
  QwenClient ──HTTPS──► DashScope (Qwen Cloud)
           │                    qwen3.7-plus · search · optional VL
           ▼
  AnswerSanitizer → Chat UI + chat_messages (SQLite)
```

### Continuous memory path (background)

```text
  ScreenCaptureKit + Accessibility + Vision OCR
           │  frontmost window only; image discarded after OCR
           ▼
  PrivacyFilter / Redaction / Exclusions
           │
           ▼
  Memory extraction (+ optional Qwen structuring)
           │
           ▼
  SQLite memories · FTS5 · on-device embeddings
```

### Component map

| Layer | Components | Role |
|---|---|---|
| **Frontend** | SwiftUI Main app, Owl widget, Show Me overlay, Chat History | User interaction; never talks to DashScope directly |
| **Backend** | `PersonalAgent`, `QueryRouter`, `ObservationPipeline`, `ShowMePlanner` | Orchestration, routing, capture, guidance |
| **Database** | SQLite + FTS5, `VectorStore`, chat history repos | Persistent memory & sessions on device |
| **Qwen Cloud** | `QwenClient` → DashScope Compatible / Responses APIs | Reasoning, routing help, web search, optional vision |

Alibaba Cloud / Qwen usage is implemented in [`Sources/iAletheia/Qwen/QwenClient.swift`](Sources/iAletheia/Qwen/QwenClient.swift).

### Privacy model

| Stage | Location |
|---|---|
| Screen capture & OCR | Local only |
| Memory & chat history | Local (`~/Library/Application Support/iAletheia/`) |
| Embeddings | On-device (Apple NaturalLanguage) |
| Screenshot persistence | **Never** (ephemeral capture only) |
| Qwen Cloud | Query-time reasoning / search only |
| Secrets | Keychain and/or `.env.local` (never committed) |

---

## Features

- Full macOS app: **Home**, **Memories**, **Chat**, **Chat History**, **About Me**, **Agent**, **Settings**
- Floating owl widget — open chat anytime; learning continues in the background
- Live screen actions: describe the active window, draft copy-paste email replies, review visible code
- Session-aware chat + persisted history of every conversation
- Smart entity memory (merge same people/topics, learn how you like answers)
- About Me + Agent personality (tone, length, custom instructions)
- Auto-observe ~every 2s → text kept, image discarded
- Pin / forget / clear-all for local data

---

## Requirements

- macOS 14+
- Xcode 15+ / Swift 5.9+
- Apple Silicon recommended
- **Screen Recording** and **Accessibility** permissions
- A [DashScope / Qwen Cloud](https://www.alibabacloud.com/help/en/model-studio/) API key

---

## Quick start

```bash
git clone https://github.com/vnmrsharma/iAletheia.git
cd iAletheia

cp .env.local.example .env.local
# Edit .env.local and set QWEN_API_KEY

chmod +x run.sh
./run.sh
```

Or manually:

```bash
cp .env.local.example .env.local   # then add your key
swift build -c release
.build/release/iAletheia
```

### Permissions

1. Launch the app (menu bar / floating owl)
2. Grant **Screen Recording** and **Accessibility** for iAletheia
3. Click the owl to chat

### Configuration

```env
QWEN_API_KEY=sk-your-dashscope-api-key-here
QWEN_BASE_URL=https://dashscope-intl.aliyuncs.com/compatible-mode/v1
QWEN_TEXT_MODEL=qwen3.7-plus
```
---

## Project structure

```text
Sources/iAletheia/
├── App/            AppState, DependencyContainer, entry
├── Capture/        ScreenCaptureKit, Accessibility, active window
├── Chat/           Session models + chat history persistence
├── Privacy/        Filters, redaction, exclusions
├── Observation/    Live snapshot + observation pipeline
├── Memory/         Extraction, entities, chat learning
├── Retrieval/      Hybrid FTS + vector search
├── Tools/          PersonalAgent, QueryRouter, web helpers
├── Qwen/           DashScope client, AnswerSanitizer
├── Storage/        SQLite, repositories, preferences
└── UI/             Main app, owl widget, chat, inspector
```
---

## Hackathon submission

- **Track:** MemoryAgent (Track 1) — [Qwen Cloud Hackathon](https://qwencloud-hackathon.devpost.com/)
- **Repository:** https://github.com/vnmrsharma/iAletheia
- **License:** MIT
- **Architecture diagram:** see [Architecture Diagram](#architecture-diagram) above (frontend ↔ local backend ↔ SQLite ↔ Qwen Cloud)
- **Alibaba Cloud proof:** Qwen / DashScope via [`QwenClient.swift`](Sources/iAletheia/Qwen/QwenClient.swift)
- **Differentiator:** Local visual memory + live frontmost-window awareness + session chat; not a generic chatbot

---

## License
MIT — see [LICENSE](LICENSE).