module CoPlan
  # Turns human names into URL segments, and compares them loosely.
  #
  # Every browsable folder and plan segment goes through {call}. The rules
  # are deliberately dull so a slug is predictable from the name that
  # produced it: downcase, runs of punctuation and whitespace to hyphens,
  # keep letters and digits. No camelCase splitting: "LiveOrder" is one
  # word to a reader, so it stays "liveorder" rather than "live-order".
  #
  # "Letters and digits" means Unicode ones. A title in Japanese or Arabic
  # keeps its own script — /aiko/信頼性向上ロードマップ-2027年前半 — because
  # the alternative is a URL reading "untitled", which defeats the whole
  # point of a readable link. Browsers percent-encode these on the wire
  # and display them decoded, and Rails hands them back as UTF-8. Accents
  # survive too: NFC, not NFKD, so "incorporación" doesn't come apart into
  # a base letter and a stray combining mark.
  #
  # Library handles are the exception — see {handle}.
  #
  # {compare_key} is the fuzzy half. "LiveOrder", "Live Order" and
  # "live-order" all reduce to the same key, which is what lets a plan
  # titled "LiveOrder Cart Roadmap" recognize that the folder it sits in
  # already said "LiveOrder" — see {Plans::AssignSlug}.
  module Slug
    # Long enough to stay readable, short enough to paste in Slack.
    # Characters, not bytes — a CJK title gets the same 60 glyphs.
    MAX_LENGTH = 60

    # Everything in this app is a plan, so the word carries no
    # information in a URL. Stripped as a leading or trailing token only
    # — "plan-b-pricing" keeps its middle.
    NOISE_TOKENS = %w[plan plans doc document].freeze

    def self.call(text)
      normalize(text.to_s.unicode_normalize(:nfc).downcase.gsub(/[^[[:alnum:]]]+/, "-"))
    end

    # ASCII-only variant for library handles. A handle is the root of
    # every URL under it and gets typed, read aloud, and pasted into
    # places that mangle non-ASCII, so it stays in the Latin alphabet
    # even when the name it came from doesn't. Empty is a legitimate
    # answer — callers fall back (see Library.unclaimed_handle).
    def self.handle(text)
      normalize(text.to_s.unicode_normalize(:nfkd).downcase.gsub(/[^a-z0-9]+/, "-"))
    end

    # Hyphen-insensitive form, for asking "do these two names say the
    # same thing?" without caring how the writer spaced it.
    def self.compare_key(text)
      call(text).delete("-")
    end

    # Splits a slug into its tokens — the unit that redundancy stripping
    # and truncation both work in.
    def self.tokens(text)
      call(text).split("-")
    end

    # Rejoins tokens into a slug, trimming to MAX_LENGTH on a token
    # boundary so a URL never ends mid-word.
    def self.from_tokens(tokens)
      truncate(tokens.join("-"))
    end

    # Drops leading/trailing filler like "plan" and "doc". Never returns
    # empty: a title that is nothing but noise keeps its tokens.
    def self.strip_noise(tokens)
      kept = tokens.dup
      kept.shift while kept.size > 1 && NOISE_TOKENS.include?(kept.first)
      kept.pop while kept.size > 1 && NOISE_TOKENS.include?(kept.last)
      kept.presence || tokens
    end

    # Collapses hyphen runs and trims the ends, then truncates. Shared by
    # {call} and {handle}, which differ only in what they keep.
    def self.normalize(hyphenated)
      truncate(hyphenated.gsub(/-{2,}/, "-").delete_prefix("-").delete_suffix("-"))
    end

    # Cuts at the last token boundary that fits, so "orders-api-
    # migration-plan" truncates to "orders-api" rather than
    # "orders-api-migrat".
    def self.truncate(slug)
      return slug if slug.length <= MAX_LENGTH

      slug[0, MAX_LENGTH].rpartition("-").first.presence || slug[0, MAX_LENGTH]
    end
  end
end
