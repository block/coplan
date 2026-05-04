module CoPlan
  module Comments
    # Rewrites plain `@username` mentions in a comment body into the canonical
    # `[@username](mention:username)` markdown form, but only for usernames that
    # resolve to a real CoPlan::User. Unresolved `@foo` is left as plain text.
    #
    # This runs `before_save` on Comment so:
    # - The textarea stays visually clean while the user is typing.
    # - The persisted body is round-trip-safe markdown — no DB lookup is
    #   needed at render time, and ProcessMentions can find mentions reliably.
    #
    # The lookbehind `(?<![\w@\[])` skips:
    #   - Email addresses (`foo@bar.com` → `r` precedes `@`)
    #   - Already-canonical mentions (`[@hampton](...)` → `[` precedes `@`)
    #   - Double-`@` artifacts
    class RewriteMentions
      # Matches plain `@username` at a word boundary. Username must start and
      # end with a word char and may contain dots/dashes between word runs.
      PLAIN_MENTION_PATTERN = /(?<![\w@\[])@([a-zA-Z0-9_]+(?:[.-][a-zA-Z0-9_]+)*)/

      def self.call(body)
        new(body).call
      end

      def initialize(body)
        @body = body.to_s
      end

      def call
        usernames = @body.scan(PLAIN_MENTION_PATTERN).flatten.uniq
        return @body if usernames.empty?

        resolved = CoPlan::User.where(username: usernames).pluck(:username).to_set

        @body.gsub(PLAIN_MENTION_PATTERN) do
          username = ::Regexp.last_match(1)
          if resolved.include?(username)
            "[@#{username}](mention:#{username})"
          else
            ::Regexp.last_match(0)
          end
        end
      end
    end
  end
end
