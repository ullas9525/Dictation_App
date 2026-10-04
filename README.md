# AI-Powered Dictation and Summarization App

## 🎙️ What This App Does
Talking is easy, but organizing raw thoughts is a pain. **AI-Powered Dictation and Summarization App** turns your voice into structured, professional knowledge in seconds.

- **Record** your thoughts, ideas, or meeting notes with zero latency.
- **Transcribe** instantly using Groq's LPU-powered Whisper engine.
- **Polish** with a high-capacity LLM "Secretary" that fixes jargon, removes fillers, and organizes your notes.
- **Structured Output**: Get high-quality Markdown notes with clear headings and bullet points.

---

## 📖 Story
- **Historical Context**: Before the advent of typing and texting, people relied on handwriting for communication.  
- **Evolution to Text**: To reduce delays and save time, communication transitioned to typing and texting.  
- **Our Solution (Audio Input)**: Our app takes this further by allowing users to speak naturally. The app instantly converts speech into polished, easy-to-read text.  

### Why This Matters
This process is:
- ⏱ **Instant Transcription** – Instantly turns speech into text.  
- ✅ **More Perfect** – AI corrects mistakes and fillers.  
- 🔒 **More Reliable** – Keeps your dictation accurate and safe.  
- 🙌 **More Easy** – No typing, just speak and let the app do the rest.  
- 🧠 **More Understandable** – Summaries highlight key points for quick reading.  

Overall, the process takes very little time while ensuring clarity, efficiency, and usability for everyone.

---

## 🎯 Why Build This?
Because professionals, students, and creators are always on the go. Voice notes are quick, but text is **easier to search, edit, and share**. This app bridges the gap by turning your spoken words into **usable content**.

---

## ✨ Features
- 🎙 **Instant Recording**: Minimalist UI with waveform visualizer and immediate startup.
- 🧠 **AI Brain Animation**: Premium high-end feedback during processing.
- 🔌 **Bring Your Own Provider**: OpenRouter and Gemini are preconfigured — tap **+** in Settings to connect any OpenAI-compatible provider (Groq, OpenAI, Mistral, a local server…) and it is used immediately. If the primary brain fails for **any** reason (wrong key, retired model, rate limit, server error) the next connected provider answers instead of an error.
- ⚡ **Smart Retry**: a retry never re-uploads the audio — once Groq has transcribed it, only the AI step re-runs against the model you pick.
- 🔄 **Free Models Only**: a **Retry free model list** button in Settings pulls OpenRouter's live catalog and keeps just the models that are still free.
- 🔑 **On-Device API Keys**: Keys stay on your device.
- 📊 **Staged Progress**: Real-time tracking through **Uploading → Processing → Downloading**.
- 📝 **Triple View Tabs**:
  - **Raw Transcript**: Your exact spoken words.
  - **Cleaned Text**: A readable version of the transcript.
  - **Polished Note**: Professional Markdown with headings (#) and sections (##).
- 🧠 **Knows its brain**: each tab shows the **provider and the exact model** that produced it
  (e.g. `Provider: Groq` / `Model: whisper-large-v3`, or `Provider: Gemini` / `Model: gemini-2.5-flash`)
  right above the Copy / Edit buttons — so you always know which LLM wrote the note.
- 🔄 **Sparkle ✨ Re-polish**: Didn't like the result? Re-process with a different LLM instantly (the label updates to the new brain).

---

## 📦 Tech Stack
- **Flutter** (cross-platform mobile)
- **Framework**: Flutter (Material 3)
- **Speech-to-Text**: Groq Cloud (LPU Inference, Whisper)
- **LLM Brain**: provider-independent registry — OpenRouter and Gemini built in, plus any
  OpenAI-compatible `/chat/completions` endpoint you connect with the **+** button
- **State Management**: Provider
- **Persistence**: SharedPreferences
- **Markdown Rendering**: Flutter Markdown

---

## 🛠️ Setup Guide
1. **Clone the Repo**:
   ```bash
   git clone https://github.com/ullas9525/Dictation_App.git
   cd Dictation_App
   ```
2. **Install Dependencies**:
   ```bash
   flutter pub get
   ```
3. **API Keys** (configured in-app):
   - **Groq** key from [console.groq.com](https://console.groq.com) → **Settings → Groq API Key** (speech-to-text).
   - **LLM Brain**: an **OpenRouter** and a **Gemini** card are preconfigured — paste a key into either, or tap **+** to connect any provider you like.
4. **Run**:
   ```bash
   flutter run --release
   ```

---

## 🔐 API Key Setup
1. **Speech-to-Text (required)**: get a Groq key at [console.groq.com](https://console.groq.com/) and paste it under **Settings → Groq API Key**.
2. **LLM Brain (at least one required)**: paste a key into the **OpenRouter** or **Gemini** card, or press the **+** button next to a provider to connect another one. Tap a provider entry once to paste its API key — it is remembered, and later taps open its settings directly:
   - Presets: **Gemini**, **OpenRouter**, **Groq**, **OpenAI**, **Mistral** — or **Custom** for any OpenAI-compatible `/chat/completions` endpoint (just give it a name, base URL and model; the key is asked the first time you tap it).
   - Mark the provider you want tried first with ★ (**Set as primary**). Every other connected provider is then used automatically if the primary hits a rate limit.
3. **There is no save button** — every change (keys, models, toggles) is stored automatically as you make it, with no indicator to watch. Models are chosen from a **dropdown** that shows only the selected model until you tap it. Keys are stored **only on your device**.

---

## 🛠 Roadmap
- [x] Multi-language transcription (8 target languages via the polish prompt)
- [x] Provider-specific model auto-discovery (`Retry free model list` fetches OpenRouter's free models)

---

## 📜 License
This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
