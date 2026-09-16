require "json"

module CoPlan
  module OwnerOwl
    class Client
      ENDPOINT = "/api/v2/"
      OPTIONS = {
        expandTeams: true,
        includeOwnerOwl: true,
        includeCodeowners: false,
        includeRepoAdmins: false
      }.freeze

      class Error < StandardError
        attr_reader :status_code

        def initialize(message, status_code: nil)
          @status_code = status_code
          super(message)
        end
      end

      class InvalidResponse < Error; end

      def initialize(http_client:, endpoint: ENDPOINT)
        @http_client = http_client
        @endpoint = endpoint
      end

      def ownership(repo:, ref:, paths:)
        response = @http_client.post(
          @endpoint,
          JSON.generate(repo:, ref:, paths:, options: OPTIONS),
          { "Content-Type" => "application/json" }
        )
        unless response.code.to_i == 200
          raise Error.new(error_message(response.body) || "Ownership API returned HTTP #{response.code}", status_code: response.code.to_i)
        end

        body = JSON.parse(response.body)
        validate!(body)
        body
      rescue JSON::ParserError => e
        raise InvalidResponse, "Ownership API returned malformed JSON: #{e.message}"
      end

      private

      def error_message(body)
        parsed = JSON.parse(body)
        parsed["message"] if parsed.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def validate!(body)
        valid = body.is_a?(Hash) && body["sha"].present? && body["results"].is_a?(Array) &&
          body["results"].all? do |result|
            result.is_a?(Hash) && result["path"].present? &&
              result["requested_reviewers"].is_a?(Array) && result["policies"].is_a?(Array)
          end
        raise InvalidResponse, "Ownership API response did not match the expected v2 response shape" unless valid
      end
    end
  end
end
