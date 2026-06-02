module CoPlan
  # Provider-agnostic facade for single-shot AI completions. Delegates to
  # `CoPlan.configuration.ai_call` — a callable the host wires up — so the
  # engine never needs to know which model, provider, or LLM gateway is
  # actually serving the request.
  #
  # ## Usage
  #
  #   # Convenience sugar (90% case):
  #   CoPlan::Ai.call(system: "You are concise.", user: "Hi")
  #
  #   # General form (multi-turn, future-proof):
  #   CoPlan::Ai.call(messages: [
  #     { role: :system,    content: "You are concise." },
  #     { role: :user,      content: "Hi" },
  #     { role: :assistant, content: "Hello." },
  #     { role: :user,      content: "Capital of France?" },
  #   ])
  #
  # The messages array is the canonical wire format every provider speaks
  # (OpenAI chat completions, Anthropic messages, Gondola, Bedrock, etc.),
  # so the host's `ai_call` lambda can pass it straight through with zero
  # translation.
  #
  # ## Errors
  #
  # Any exception raised inside the configured `ai_call` is wrapped in
  # CoPlan::Ai::Error, so callers can `discard_on CoPlan::Ai::Error`
  # without coupling to the underlying provider.
  #
  # When no callable is configured, raises CoPlan::Ai::NoProviderError
  # (a subclass of Error) so jobs still `discard_on` cleanly.
  module Ai
    class Error < StandardError; end
    class NoProviderError < Error; end

    def self.call(messages: nil, system: nil, user: nil)
      messages ||= [
        ({ role: :system, content: system } if system),
        ({ role: :user,   content: user   } if user),
      ].compact

      if messages.empty?
        raise ArgumentError, "CoPlan::Ai.call requires `messages:`, or `system:` and/or `user:`"
      end

      callable = CoPlan.configuration.ai_call
      unless callable
        raise NoProviderError,
          "No AI provider configured. Set CoPlan.configuration.ai_call in your host initializer " \
          "(or set OPENAI_API_KEY to auto-wire the built-in OpenAI plugin)."
      end

      begin
        callable.call(messages: messages)
      rescue => e
        raise Error, e.message
      end
    end
  end
end
