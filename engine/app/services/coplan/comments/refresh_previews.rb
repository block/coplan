module CoPlan
  module Comments
    class RefreshPreviews
      def self.call(thread:)
        new(thread:).call
      end

      def initialize(thread:)
        @thread = thread
      end

      def call
        kinds = []
        kinds << "general" unless @thread.anchored?
        kinds << "detached" if @thread.out_of_date? && @thread.anchor_kind.blank?
        return [] if kinds.empty?

        plan = @thread.plan
        locals = { threads: plan.comment_threads.with_kept_comments.includes(:comments).order(:created_at) }
        kinds.map do |kind|
          partial = kind == "general" ? "general_comment_list" : "detached_comments"
          target = kind == "general" ? "plan-general-comment-list" : "plan-detached-comments"
          preview = { target: target, partial: "coplan/plans/#{partial}", locals: locals }
          Broadcaster.replace_to(plan, **preview)
          preview
        end
      end
    end
  end
end
