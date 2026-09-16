require "digest"
require "set"

module CoPlan
  module OwnerOwl
    class Router
      MAX_REVIEWERS_PER_ROUTE = 5

      def initialize(client:)
        @client = client
      end

      def source
        "owner_owl"
      end

      def call(plan:, touched_files:, author_identity: nil)
        touched_files.group_by { |file| [ file.fetch("repo"), file.fetch("ref", "HEAD") ] }.flat_map do |(repo, ref), files|
          response = @client.ownership(repo:, ref:, paths: files.map { |file| file.fetch("path") })
          routes_from(response, plan_id: plan.id, repo:, ref:, author_identity:)
        end
      end

      private

      def routes_from(response, plan_id:, repo:, ref:, author_identity:)
        grouped = grouped_reviewer_entries(response.fetch("results"))
        grouped.flat_map do |key, route|
          pool = expanded_users(route.fetch(:entry))
            .reject { |identity| identity.casecmp?(author_identity.to_s) }
            .uniq
            .sort
          if pool.empty?
            schedule = route.dig(:entry, "pagerduty", "schedule")
            pool = [ "pagerduty:#{schedule}" ] if schedule.present?
          end
          next [] if pool.empty?

          count = reviewer_count(route.fetch(:entry), route.fetch(:policies))
          selected = rotate(pool, Digest::SHA256.hexdigest([ plan_id, repo, ref, key ].join("\0")).to_i(16)).first(count)
          selected.map do |identity|
            {
              identity:,
              metadata: {
                "repo" => repo,
                "ref" => ref,
                "sha" => response.fetch("sha"),
                "paths" => route.fetch(:paths).sort,
                "source" => route.dig(:entry, "source"),
                "source_url" => route.dig(:entry, "source_url"),
                "pathspec" => route.dig(:entry, "pathspec")
              }.compact
            }
          end
        end
      end

      def grouped_reviewer_entries(results)
        results.each_with_object({}) do |result, grouped|
          result.fetch("requested_reviewers").each do |entry|
            key = entry.slice("source", "source_url", "pathspec", "principals", "expanded_principals", "expanded_except", "round_robin", "recommend").to_json
            grouped[key] ||= { entry:, paths: Set.new, policies: [] }
            grouped[key][:paths].add(result.fetch("path"))
            grouped[key][:policies].concat(result.fetch("policies"))
          end
        end
      end

      def reviewer_count(entry, policies)
        configured = entry.key?("recommend") ? entry["recommend"] : entry["round_robin"]
        return configured.to_i.clamp(0, MAX_REVIEWERS_PER_ROUTE) unless configured.nil?

        principals = Array(entry["principals"]).sort
        minimum = policies.filter_map do |policy|
          policy["minimum_owner_approvals"].to_i if Array(policy["principals"]).sort == principals
        end.max.to_i
        [ [ 1, minimum ].max, MAX_REVIEWERS_PER_ROUTE ].min
      end

      def expanded_users(entry)
        excluded = flatten_users(entry["expanded_except"])
        flatten_users(entry["expanded_principals"]) - excluded
      end

      def flatten_users(principals)
        Array(principals).flat_map do |principal|
          next [] unless principal.is_a?(Hash)

          case principal["type"]
          when "User" then principal["id"].to_s.presence
          when "Team" then flatten_users(principal["members"])
          else []
          end
        end.compact
      end

      def rotate(values, offset)
        return values if values.empty?

        values.rotate(offset % values.length)
      end
    end
  end
end
