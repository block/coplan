import { t } from "coplan/ui_messages"
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
    NotAllowedError: t("coplan.client.common.mic_blocked"),
    SecurityError: t("coplan.client.common.mic_blocked"),
    NotFoundError: t("coplan.client.common.mic_not_found"),
    OverconstrainedError: t("coplan.client.common.mic_unavailable"),
    NotReadableError: t("coplan.client.common.mic_open_failed"),
    "not-allowed": t("coplan.client.common.mic_blocked"),
    "audio-capture": t("coplan.client.common.mic_capture_failed"),
    "no-speech": t("coplan.client.common.mic_no_speech"),
    "network": t("coplan.client.common.mic_connection_failed"),
    "service-not-allowed": t("coplan.client.common.mic_recognition_unavailable"),
    "language-not-supported": t("coplan.client.common.mic_language_unsupported")
  }[code] || t("coplan.client.common.dictation_start_failed", { detail: code ? " (" + code + ")" : "" })
}
