# Hermes Android App

Mobile client for [Hermes Agent](https://hermes-agent.nousresearch.com) — connect to your Gateway API Server from your Android phone over WiFi.

## Features

- **Gold/black Hermes branding** — Cinzel wordmark, gold (#D4AF37) accents, dark theme
- **SSE streaming** — real-time token-by-token responses with tool progress cards
- **Session management** — browse, resume, and fork conversations
- **Verbose mode** — toggle tool calls, results, and thinking visibility
- **Dashboard access** — Memory browser, Cron jobs, Skills, Settings
- **Media attachments** — photo library and camera picker
- **Responsive layout** — phone and tablet support

## Setup

### 1. Start the Hermes Gateway API Server

The Gateway API Server must be running with API key auth enabled and bound to all interfaces:

```bash
# In ~/.hermes/.env, ensure:
#   API_SERVER_ENABLED=true
#   API_SERVER_HOST=0.0.0.0
#   API_SERVER_KEY=your-secret-key-here

hermes gateway start
```

The gateway exposes two services the app uses:

| Service | Port | Auth | Used for |
|---------|------|------|----------|
| Gateway API Server | 8642 | `Bearer <API_SERVER_KEY>` | Chat (SSE), sessions, models |
| Dashboard | 9119 | `X-Hermes-Session-Token` | Memory, Cron, Skills, Settings |

> Both services must be running. Start the dashboard with `hermes dashboard --host 0.0.0.0 --insecure` for LAN access to config/cron/skills/memory screens.

### 2. Apply the real-time streaming patch (recommended)

Without this server-side patch, tool progress events and text tokens are buffered by the TCP stack and arrive in one burst at stream end instead of streaming in real-time:

```bash
cd ~/.hermes/hermes-agent
git apply ~/.hermes/hermes-android/server-patches/0001-tcp-nodelay-sse.patch
# Then restart the gateway:
hermes gateway restart
```

The patch sets `TCP_NODELAY` on SSE response sockets, disabling Nagle's algorithm so each tool progress event and text token is sent immediately.

### 3. Find your server IP

On the machine running the gateway:

```bash
# macOS / Linux
ipconfig getifaddr en0   # or: hostname -I | awk '{print $1}'
```

### 4. Connect from the app

1. Open the Hermes Android app
2. Tap **+** to add a connection
3. Enter a label, your server's IP, port `8642`, and your `API_SERVER_KEY`
4. Tap the connection to see your sessions

## Development

```bash
cd hermes-android
flutter pub get
flutter run -d android
```

### Build release APK

```bash
flutter build apk --release --split-per-abi
# Output: build/app/outputs/flutter-apk/app-*-release.apk
```

## Architecture

```
┌──────────────┐     HTTP SSE (8642)      ┌──────────────────────┐
│  Android App  │ ───────────────────────> │  Gateway API Server   │
│  (Flutter)    │    Bearer auth           │  (port 8642)          │
│              │                           │                       │
│              │    REST API (9119)        │  Dashboard            │
│              │ ───────────────────────> │  (port 9119)          │
└──────────────┘    SPA session token      └──────────────────────┘
```

- **SSE streaming** — `POST /v1/chat/completions` with `stream: true`, OpenAI-compatible
- **REST API** — sessions, messages, models via Bearer token
- **Hermes.tool.progress** — custom SSE events for real-time tool lifecycle display

## Tech Stack

- Flutter 3.44 / Dart 3.12
- Material 3 dark theme with gold accents
- `flutter_markdown` for message rendering
- `google_fonts` (Cinzel) for branding
- `image_picker` for media attachments
- `shared_preferences` for connection persistence
- `package_info_plus` for version auto-read

## Project Structure

```
lib/
├── main.dart                          # Entry point + HomeScreen + HermesHeader
├── core/
│   ├── models/
│   │   ├── connection.dart            # SavedConnection model
│   │   └── session.dart               # Session model
│   ├── screens/
│   │   ├── session_list_screen.dart   # Messaging-style session browser
│   │   ├── chat_screen.dart           # Chat with SSE streaming + tool cards
│   │   ├── settings_screen.dart       # Model selection, theme, verbose toggle
│   │   ├── memory_screen.dart         # Memory viewer (DashboardClient)
│   │   ├── cron_screen.dart           # Cron job manager (DashboardClient)
│   │   └── skills_screen.dart         # Skills browser (DashboardClient)
│   ├── services/
│   │   ├── connection_manager.dart    # ApiClient (8642), GatewayChatClient (SSE),
│   │   │                              #   DashboardClient (9119), ConnectionManager
│   │   └── ws_client.dart             # Legacy WebSocket client (unused, kept for ref)
│   └── utils/
│       └── responsive.dart            # Phone/tablet breakpoints
└── assets/
    └── icon/
        └── icon.png                   # App icon source

server-patches/
└── 0001-tcp-nodelay-sse.patch         # TCP_NODELAY fix for real-time SSE streaming
```

## Troubleshooting

### "Cannot connect" or 401 errors

The Gateway API Server requires authentication. Ensure `API_SERVER_KEY` is set in `~/.hermes/.env` and the same key is entered in the app's connection settings. The key is stored in `SharedPreferences` on the device.

### Dashboard screens fail (Memory, Cron, Skills, Settings)

These screens use the Dashboard (port 9119) with SPA session token auth. Ensure the dashboard is running:

```bash
hermes dashboard --host 0.0.0.0 --insecure
```

### Tool progress cards don't appear in real-time

Apply the `server-patches/0001-tcp-nodelay-sse.patch` to your `~/.hermes/hermes-agent` installation and restart the gateway. Without this patch, TCP buffering causes all tool events to arrive in one burst at stream end.

### "Session not found" for new sessions

New sessions show an empty chat until the first message is sent. The server creates the session on disk when you send your first prompt.

### Can't find the server

Make sure your phone and the gateway host are on the same WiFi network. Check the firewall on the host isn't blocking ports 8642 and 9119.

## License

MIT
