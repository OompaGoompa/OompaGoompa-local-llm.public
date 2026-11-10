# Local LLM

An iPhone app that runs AI language models entirely on the phone, using your own GGUF model files.

- **Your models:** import .gguf files from the Files app, download them from a link, or drop them into On My iPhone › Local LLM › Models.
- **Chat:** streaming replies, saved chats, a fixed prompt with saved presets.
- **Files in and out:** attach text files and PDFs to a message; send chats, replies and model files through the share sheet.
- **Remote server:** optionally run bigger models on your own computer (Ollama, LM Studio, llama.cpp server) or any OpenAI-compatible service and chat from the phone.
- **Memory savers:** memory-mapped loading, GPU (Metal), adjustable context size, compact 8-bit working memory, automatic unload when you leave the app.

## Build

Every push that touches `ios/` builds an unsigned .ipa on GitHub's macOS runners (`.github/workflows/ios.yml`).
The result is published to the `ipa` branch and the `build-ios` release. Sideload it with AltStore, SideStore or
Sideloadly.

The engine is [llama.cpp](https://github.com/ggml-org/llama.cpp), pulled in as its prebuilt XCFramework (version pinned in the workflow).
