# NewsComb
Analyzes, filters, aggregates, summarizes RSS news feeds

## Installation

1. Download the latest DMG from [Releases](https://github.com/iliasaz/NewsComb/releases)
2. Open the DMG and drag `NewsCombApp.app` to your Applications folder
3. Eject the DMG

## First Launch

Since the app is not signed with an Apple Developer certificate, macOS will block it on first launch.

**To open the app:**

1. Try to open `NewsCombApp.app` — macOS will show a warning that it cannot verify the developer
2. Open **System Settings** → **Privacy & Security**
3. Scroll down to find the message *"NewsCombApp.app" was blocked to protect your Mac*
4. Click **Open Anyway**

![Privacy & Security settings showing Open Anyway button](docs/images/privacy-security-confirmation.png)

5. macOS will ask you to confirm twice more — click **Open** each time

After this one-time setup, the app will open normally.

## Setup

### Embeddings (Required)

NewsComb uses local embeddings for the knowledge graph. You need to install Ollama and download the nomic-embed-text model:

1. Install [Ollama](https://ollama.com/download)
2. Open Terminal and run:
   ```bash
   ollama pull nomic-embed-text
   ```

### LLM Provider (Required for Q&A)

To use the "Ask Your News" feature, you need to configure an LLM provider in the app's Settings.

**Recommended: OpenRouter**

1. Create an account at [OpenRouter](https://openrouter.ai/)
2. Generate an API key
3. In NewsComb Settings, select OpenRouter as the provider and enter your API key
4. Use `meta-llama/llama-4-maverick` as the model for best results

**Alternative: Local Ollama**

You can run an LLM locally with Ollama, but this will be significantly slower:

```bash
ollama pull qwen2.5:14b
```

Then select Ollama as the provider in Settings and use `qwen2.5:14b` as the model
