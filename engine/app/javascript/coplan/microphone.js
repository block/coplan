const preferenceKey = "coplan:microphone"

export function selectedMicrophone() {
  try { return localStorage.getItem(preferenceKey) || "" } catch { return "" }
}

export function selectMicrophone(deviceId) {
  try { localStorage.setItem(preferenceKey, deviceId) } catch {}
  document.dispatchEvent(new CustomEvent("coplan:microphone-change"))
}

export function audioConstraints() {
  const deviceId = selectedMicrophone()
  return { audio: deviceId ? { deviceId: { exact: deviceId } } : true }
}

export function supportsRecognitionTrack() {
  // There is no feature probe for this overload. Older implementations silently
  // ignore its argument and record the default mic. Limit it to documented
  // desktop Chromium support (135+); never claim a selected mic was used otherwise.
  const chromium = navigator.userAgent.match(/(?:Chrome|Chromium)\/(\d+)/)
  return !!chromium && Number(chromium[1]) >= 135 && !/Android/.test(navigator.userAgent)
}

export function microphoneError(error) {
  const code = error?.error || error?.name
  return {
    NotAllowedError: "Mic blocked. Allow microphone access in your browser and system privacy settings.",
    SecurityError: "Mic blocked. Allow microphone access in your browser and system privacy settings.",
    NotFoundError: "No microphone found. Connect an input and choose it in Microphone settings.",
    OverconstrainedError: "The selected microphone is unavailable. Choose another audio input.",
    NotReadableError: "Couldn't open the microphone. Check whether another app is using it, or choose another input.",
    "not-allowed": "Mic blocked. Allow microphone access in your browser and system privacy settings.",
    "audio-capture": "Couldn't capture microphone audio. Check Microphone settings and your system input.",
    "no-speech": "No speech heard. Check your audio input and try again.",
    "network": "The browser's speech service couldn't connect. Try dictation in Chrome, or enable server transcription.",
    "service-not-allowed": "Speech recognition is unavailable in this browser. Try Chrome, or enable server transcription.",
    "language-not-supported": "Speech recognition doesn't support this language. Try another browser or enable server transcription."
  }[code] || `Dictation couldn't start${code ? ` (${code})` : ""}. Check Microphone settings and try again.`
}
