// The /+esm endpoint is required: the raw files in the npm package re-export
// from CommonJS modules, which browsers can't import. jsDelivr's +esm builds
// proper ESM bundles with default exports.
const HLJS_VERSION = "11.11.1"
const CDN_BASE = `https://cdn.jsdelivr.net/npm/highlight.js@${HLJS_VERSION}/lib`

// Fence tags whose highlight.js grammar lives under a different file name.
// Each grammar module registers its own aliases once loaded, but the file
// we import must be the canonical name.
const LANGUAGE_FILES = {
  js: "javascript", jsx: "javascript", mjs: "javascript", cjs: "javascript",
  ts: "typescript", tsx: "typescript", mts: "typescript", cts: "typescript",
  html: "xml", xhtml: "xml", svg: "xml", plist: "xml",
  sh: "bash", zsh: "bash",
  console: "shell", shellsession: "shell",
  yml: "yaml",
  rb: "ruby", gemspec: "ruby", irb: "ruby",
  py: "python",
  golang: "go",
  "c++": "cpp", cc: "cpp", cxx: "cpp", hpp: "cpp", hh: "cpp",
  "c#": "csharp", cs: "csharp",
  "f#": "fsharp", fs: "fsharp",
  kt: "kotlin", kts: "kotlin",
  rs: "rust",
  ps: "powershell", ps1: "powershell",
  docker: "dockerfile",
  proto: "protobuf",
  objc: "objectivec", "objective-c": "objectivec",
  md: "markdown", mkdown: "markdown",
  pl: "perl",
  hs: "haskell",
  gql: "graphql",
  tex: "latex",
  text: "plaintext", txt: "plaintext", plain: "plaintext"
}

let hljsPromise
const languagePromises = new Map()

export function loadHljs() {
  // Don't cache a rejected import — a transient CDN failure would otherwise
  // disable highlighting for the rest of the Turbo session.
  hljsPromise ||= import(`${CDN_BASE}/core/+esm`)
    .then(module => module.default)
    .catch(error => {
      hljsPromise = null
      throw error
    })
  return hljsPromise
}

// Resolves a fence tag to a registered grammar name, importing the grammar
// module on first use. Returns null when the language isn't recognized.
export async function loadLanguage(hljs, lang) {
  const name = LANGUAGE_FILES[lang] || lang
  // Grammar file names are strictly [a-z0-9-]. The fence tag comes from
  // untrusted plan content — anything else must never reach the CDN URL.
  if (!/^[a-z0-9-]{1,42}$/.test(name)) return null
  if (hljs.getLanguage(name)) return name

  if (!languagePromises.has(name)) {
    languagePromises.set(name,
      import(`${CDN_BASE}/languages/${name}/+esm`)
        .then(module => {
          hljs.registerLanguage(name, module.default)
          return name
        })
        .catch(() => {
          // Unknown language or transient failure — don't cache it, so a
          // later page view can retry.
          languagePromises.delete(name)
          return null
        }))
  }
  return languagePromises.get(name)
}
