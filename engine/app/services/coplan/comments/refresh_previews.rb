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
          preview = { target: "plan-#{kind}-comments", partial: "coplan/plans/#{kind}_comments", locals: locals }
          Broadcaster.replace_to(plan, **preview)
          preview
        end
      end
    end
  end
end
