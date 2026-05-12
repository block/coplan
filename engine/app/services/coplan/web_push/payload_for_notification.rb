module CoPlan
  module WebPush
    # Builds the { title, body, url, tag } hash the service worker shows for a
    # given Notification. Title/body shape per reason; URL deep-links to the
    # specific thread; tag groups updates for the same thread so successive
    # replies replace each other rather than piling up.
    class PayloadForNotification
      BODY_TRUNCATE = 140

      def self.call(notification)
        new(notification).call
      end

      def initialize(notification)
        @notification = notification
        @plan = notification.plan
        @thread = notification.comment_thread
        @comment = notification.comment || @thread.comments.order(:created_at).first
      end

      def call
        {
          title: title,
          body: body,
          url: url,
          tag: "comment-thread-#{@thread.id}"
        }
      end

      private

      def title
        case @notification.reason
        when "mention"
          "#{actor_name} mentioned you on #{@plan.title}"
        when "reply"
          "#{actor_name} replied on #{@plan.title}"
        when "new_comment"
          "#{actor_name} commented on #{@plan.title}"
        when "agent_response"
          "Agent updated a thread on #{@plan.title}"
        when "status_change"
          "Thread updated on #{@plan.title}"
        else
          "Update on #{@plan.title}"
        end
      end

      def body
        return "" unless @comment&.body_markdown

        # Strip mention chips and the markdown emphasis/quote/code characters
        # that don't render usefully as plain text in an OS notification.
        # Leave hyphens and `#` alone so co-worker / URL#fragment / -prefix
        # text stays intact.
        text = @comment.body_markdown
          .gsub(/\[@(\w+)\]\(mention:[^)]+\)/, '@\1')
          .gsub(/[*_`>]/, " ")
          .gsub(/\s+/, " ")
          .strip
        text.truncate(BODY_TRUNCATE, omission: "…")
      end

      def url
        # Relative path is fine — the SW resolves against self.location.origin
        # when opening / focusing the notification target tab.
        CoPlan::Engine.routes.url_helpers.plan_path(@plan, thread: @thread.id)
      end

      def actor_name
        author = @comment&.author
        return "Someone" unless author.respond_to?(:name) && author.name.present?
        author.name
      end
    end
  end
end
