class CommentThread < ApplicationRecord
  STATUSES = %w[open resolved accepted dismissed].freeze

  belongs_to :plan
  belongs_to :organization
  belongs_to :plan_version
  belongs_to :created_by_user, class_name: "User"
  belongs_to :resolved_by_user, class_name: "User", optional: true
  belongs_to :out_of_date_since_version, class_name: "PlanVersion", optional: true
  belongs_to :addressed_in_plan_version, class_name: "PlanVersion", optional: true
  has_many :comments, dependent: :destroy

  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :open_threads, -> { where(status: "open") }
  scope :current, -> { where(out_of_date: false) }
  scope :active, -> { where(status: "open", out_of_date: false) }
  scope :archived, -> { where("status != 'open' OR out_of_date = ?", true) }

  def self.mark_out_of_date_for_new_version!(new_version)
    content = new_version.content_markdown || ""
    threads = where(out_of_date: false).where.not(plan_version_id: new_version.id)
    threads.find_each do |thread|
      next unless thread.anchored?
      if thread.anchor_context.present?
        next if content.include?(thread.anchor_context)
      else
        next if content.include?(thread.anchor_text)
      end

      thread.update_columns(
        out_of_date: true,
        out_of_date_since_version_id: new_version.id
      )
    end
  end

  def anchored?
    anchor_text.present?
  end

  def line_specific?
    start_line.present?
  end

  def line_range_text
    return nil unless line_specific?
    start_line == end_line ? "Line #{start_line}" : "Lines #{start_line}–#{end_line}"
  end

  def anchor_preview(max_length: 80)
    return nil unless anchored?
    anchor_text.length > max_length ? "#{anchor_text[0...max_length]}…" : anchor_text
  end

  def resolve!(user)
    update!(status: "resolved", resolved_by_user: user)
  end

  def accept!(user)
    update!(status: "accepted", resolved_by_user: user)
  end

  def dismiss!(user)
    update!(status: "dismissed", resolved_by_user: user)
  end
end
