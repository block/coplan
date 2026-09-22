require "set"

module CoPlan
  module Plans
    class RequestApprovals
      Result = Struct.new(:approvers, :unresolved_identities, keyword_init: true)

      class NotConfigured < StandardError; end
      class InvalidRouterResponse < StandardError; end

      def self.call(plan:, requester:)
        new(plan:, requester:).call
      end

      def initialize(plan:, requester:)
        @plan = plan
        @requester = requester
      end

      def call
        router = CoPlan.configuration.approval_router
        raise NotConfigured, "Approval routing is not configured" unless router
        routes = begin
          router.call(
            plan: @plan,
            touched_files: @plan.touched_files,
            author_identity: @plan.created_by_user.username
          )
        rescue StandardError => e
          raise InvalidRouterResponse, e.message
        end
        raise InvalidRouterResponse, "Approval router must return an array" unless routes.is_a?(Array)

        resolved, unresolved = resolve_routes(routes)
        approvers = reconcile_approvers(router_source(router), resolved)
        Result.new(approvers:, unresolved_identities: unresolved.sort)
      end

      private

      def resolve_routes(routes)
        resolved = {}
        unresolved = Set.new

        routes.each do |route|
          unless route.respond_to?(:to_h)
            raise InvalidRouterResponse, "Approval router entries must be objects"
          end
          route = route.to_h.stringify_keys
          identity = route["identity"].to_s.strip
          next if identity.blank?
          metadata = route.fetch("metadata", {})
          unless metadata.is_a?(Hash)
            raise InvalidRouterResponse, "Approval router metadata must be an object"
          end

          user = resolve_user(identity)
          if user.nil? || user.id == @plan.created_by_user_id
            unresolved.add(identity) unless user&.id == @plan.created_by_user_id
            next
          end

          resolved[user.id] ||= { user:, identities: [], routes: [] }
          resolved[user.id][:identities] << identity
          resolved[user.id][:routes] << metadata
        end

        [ resolved.values, unresolved.to_a ]
      end

      def resolve_user(identity)
        resolver = CoPlan.configuration.approval_identity_resolver
        return resolver.call(identity) if resolver

        User.where("LOWER(username) = ?", identity.downcase).first
      end

      def router_source(router)
        return router.source.to_s if router.respond_to?(:source)

        router.class.name.to_s.underscore.presence || "approval_router"
      end

      def reconcile_approvers(source, resolved)
        desired_user_ids = resolved.map { |entry| entry[:user].id }

        PlanCollaborator.transaction do
          @plan.plan_collaborators.approvers.where(routing_source: source)
            .where.not(user_id: desired_user_ids).destroy_all

          resolved.map do |entry|
            collaborator = @plan.plan_collaborators.find_or_initialize_by(user: entry[:user])
            routing_metadata = {
              "identities" => entry[:identities].uniq,
              "routes" => entry[:routes].uniq
            }
            same_route = collaborator.persisted? && collaborator.role == "approver" &&
              collaborator.routing_source == source && collaborator.routing_metadata == routing_metadata
            newly_requested = !same_route
            collaborator.assign_attributes(
              role: "approver",
              approved_at: same_route ? collaborator.approved_at : nil,
              added_by_user: @requester,
              routing_source: source,
              routing_metadata:
            )
            collaborator.save!
            notify(collaborator) if newly_requested
            collaborator
          end
        end
      end

      def notify(collaborator)
        return unless CoPlan.configuration.notification_handler

        NotificationJob.perform_later(:approval_requested, {
          plan_id: @plan.id,
          approver_user_id: collaborator.user_id,
          requested_by_user_id: @requester.id,
          routing_source: collaborator.routing_source,
          touched_files: @plan.touched_files
        })
      end
    end
  end
end
