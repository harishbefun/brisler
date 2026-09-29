# Brisler

Brisler is a local-first animated desktop companion for Windows. He has a persistent, simulated mood and personality, reacts to being petted, and can chat through a local language model. He lives in a transparent always-on-top window and keeps breathing and blinking while idle.

## What it does

- Runs as a small transparent desktop character. Drag him to a comfortable spot; click to pet him; double-click to open chat; right-click for controls.
- Uses an 8-frame idle loop for breathing and blinking, with separate expression art for brief emotional reactions.
- Asks a local AI to choose his reply, mood, and reaction during conversation.
- Saves a short conversation history and his mood, energy, and bond in `%LOCALAPPDATA%\Brisler\state.json`.
- Can optionally speak replies using the Windows speech voice installed on your PC.
- Does not capture the screen, read other windows, control apps, or send data to a cloud AI service.

Brisler’s emotions are part of his fictional character simulation; he does not literally experience feelings.

## Quick start

1. Install [Ollama for Windows](https://ollama.com/download/windows).
2. Open PowerShell and download the default local model:

   ```powershell
   ollama pull qwen3.5:4b
   ```

   The quantized model download is about 3.4 GB. Ollama serves it locally on `127.0.0.1:11434`.
3. Double-click **Start Brisler.vbs**. The app uses Windows PowerShell and WPF already included with Windows.
4. Double-click Brisler to chat. Right-click him to pause animation, enable spoken replies, open setup help, reset local memory, or quit.

Brisler can still float and respond to clicks without Ollama. Chat replies require Ollama and the model above. The model is a default; you can change it in `Brisler.ps1` if you have another model installed locally.

## Privacy

The model runs on your PC through Ollama. Brisler sends the current message, recent chat history, and companion state to the local Ollama service at `127.0.0.1`; it does not make cloud AI requests. Chat history and companion state stay in the local AppData folder. Screen awareness and desktop control are intentionally out of scope.

## Project layout

- `Brisler.ps1` — transparent desktop app, animation loop, chat UI, Ollama connection, and local state.
- `assets/idle-*.png` — the continuous idle animation frames.
- `assets/pose-*.png` — short expression/reaction poses.
- `Start Brisler.vbs` — launches Brisler without leaving a console window open.

## License

The project code and included Brisler art are released under the MIT License. See [LICENSE](LICENSE).

Brisler is inspired by the general design idea of a desktop pet whose local agent picks an action and mood while a separate animation loop keeps motion smooth. [Mochi](https://github.com/NatBrian/mochi-llm-pet) is an independent project; this repository does not include Mochi’s code or art.
