module CoPlan
  # Provider-agnostic facade for AI calls where the caller doesn't care
  # which underlying provider runs the prompt. Use this from any place
  # that just wants "an AI" (e.g. SummarizePlanJob).
  #
  # Provider-specific jobs that need to pin a model or provider per call
  # (e.g. AutomatedReviewJob, where each reviewer is configured with its
  # own provider+model) should keep calling AiProviders::OpenAi /
  # AiProviders::Anthropic directly.
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
  end
end
