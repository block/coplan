module CoPlan
  # Provider-agnostic facade for AI calls where the caller doesn't care
  # which underlying provider runs the prompt. Use this from any place
  # that just wants "an AI" (e.g. SummarizePlanJob).
  #
  # The provider chosen here is an implementation detail; swap it without
  # touching callers. Raises CoPlan::Ai::Error on provider failure so
  # callers can `discard_on` without knowing which provider is in use.
  module Ai
    class Error < StandardError; end

    def self.call(system_prompt:, user_content:)
      AiProviders::OpenAi.call(system_prompt: system_prompt, user_content: user_content)
    rescue AiProviders::OpenAi::Error => e
      raise Error, e.message
    end

    # Speech to text. `context` is surrounding material the speaker was
    # looking at; passing it makes the difference between "CoPlan" and
    # "co-plan", or "Turbo Streams" and "turbo streets".
    def self.transcribe(file:, context: nil)
      AiProviders::OpenAi.transcribe(file: file, context: context)
    rescue AiProviders::OpenAi::Error => e
      raise Error, e.message
    end

    # Whether a provider is reachable at all, for callers that need to
    # choose a different route rather than fail (the voice control picks
    # how to capture based on this).
    def self.available?
      AiProviders::OpenAi.configured?
    end
  end
end
