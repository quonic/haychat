# Network Architecture Overview

```md
Main Process (master)
         ↓    IPC Socket
         ↓Network Process
├── Thread Pool (default 4 threads)
│   ├── Worker 0 → Peers [1,2,3...]
│   ├── Worker 1 → Peers [4,5,6...]
│   └── ...
├── Peer Manager (global, mutex-protected)
│   └── Map[PeerID] → Address + Channel State
└── ENet Host (listening on :6667)
    ↓    Client Connections
```

Key Design Features
✓ Thread-safe - All shared data protected with sync.Mutex
✓ Load-balanced - New peers assigned to least-loaded thread
✓ Multi-channel - Each peer can have Chat, Voice, Video, Screenshare active independently
✓ IPC integration - Receives commands from main process, sends notifications back
✓ ENet-ready - Structure prepared for UDP-based reliable transport
✓ Graceful shutdown - Proper cleanup of threads and peers on ProcessShutdown signal