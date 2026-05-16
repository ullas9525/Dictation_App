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
- 🔑 **Secure API Key Storage**: Your Groq key stays safe on your device.
- 📊 **Staged Progress**: Real-time tracking through **Uploading → Processing → Downloading**.
- 📝 **Triple View Tabs**:
  - **Raw Transcript**: Your exact spoken words.
  - **Cleaned Text**: A readable version of the transcript.
  - **Polished Note**: Professional Markdown with headings (#) and sections (##).
- 🔄 **Sparkle ✨ Re-polish**: Didn't like the result? Re-process with a different LLM instantly.

---

## 📦 Tech Stack
- **Flutter** (cross-platform mobile)
- **Framework**: Flutter (Material 3)
- **AI Infrastructure**: Groq Cloud (LPU Inference)
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
3. **Groq API Key**:
   - Get your key at [console.groq.com](https://console.groq.com).
   - Open the app → **Settings** → Paste your **Groq API Key**.
4. **Run**:
   ```bash
   flutter run --release
   ```

---

## 🔐 API Key Setup
1. Get your **Groq API Key** from [console.groq.com](https://console.groq.com/).
2. Enter it in the app under **Settings** → **API Settings**.
3. It stays **securely on your device**.

---

## 🛠 Roadmap
- [ ] Multi-language transcription

---

## 📜 License
This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
