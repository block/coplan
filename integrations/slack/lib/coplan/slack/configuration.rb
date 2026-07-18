module CoPlan
  module Slack
    Configuration = Struct.new(:signing_secret, :bot_token, :base_url, keyword_init: true) do
      def configured?
        signing_secret.present? && bot_token.present? && base_url.present?
      end
    end
  end
end
