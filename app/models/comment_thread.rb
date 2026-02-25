class CommentThread < ApplicationRecord
  STATUSES = %w[open resolved accepted dismissed].freeze

  attr_accessor :anchor_occurrence

  belongs_to :plan
  belongs_to :organization
  belongs_to :plan_version
  belongs_to :created_by_user, class_name: "User"
  belongs_to :resolved_by_user, class_name: "User", optional: true
  belongs_to :out_of_date_since_version, class_name: "PlanVersion", optional: true
  belongs_to :addressed_in_plan_version, class_name: "PlanVersion", optional: true
  has_many :comments, dependent: :destroy

  validates :status, presence: true, inclusion: { in: STATUSES }

  before_create :resolve_anchor_position

  scope :open_threads, -> { where(status: "open") }
  scope :current, -> { where(out_of_date: false) }
  scope :active, -> { where(status: "open", out_of_date: false) }
  scope :archived, -> { where("status != 'open' OR out_of_date = ?", true) }

  def self.mark_out_of_date_for_new_version!(new_version)
    content = new_version.content_markdown || ""
    ops_json = new_version.operations_json || []

    threads = where(out_of_date: false).where.not(plan_version_id: new_version.id)
    threads.find_each do |thread|
      next unless thread.anchored?

      if thread.anchor_start.present? && thread.anchor_end.present? && thread.anchor_revision.present?
        # Position-based check: transform anchor range through all versions
        # since the anchor was last updated, not just the latest one.
        all_intervening = new_version.plan.plan_versions
          .where("revision > ? AND revision <= ?", thread.anchor_revision, new_version.revision)
          .order(revision: :asc)
          .to_a
        positional = all_intervening.select { |v| (v.operations_json || []).any? { |op| op.key?("resolved_range") || op.key?("replacements") } }

        if positional.any?
          begin
            new_range = Plans::TransformRange.transform_through_versions(
              [thread.anchor_start, thread.anchor_end],
              positional
            )
            thread.update_columns(
              anchor_start: new_range[0],
              anchor_end: new_range[1],
              anchor_revision: new_version.revision
            )
          rescue Plans::TransformRange::Conflict
            thread.update_columns(
              out_of_date: true,
              out_of_date_since_version_id: new_version.id
            )
          end
        elsif all_intervening.any?
          # Versions exist but lack positional data — fall back to text check
          if thread.anchor_context.present?
            unless content.include?(thread.anchor_context)
              thread.update_columns(out_of_date: true, out_of_date_since_version_id: new_version.id)
              next
            end
          else
            unless content.include?(thread.anchor_text)
              thread.update_columns(out_of_date: true, out_of_date_since_version_id: new_version.id)
              next
            end
          end
          thread.update_columns(anchor_revision: new_version.revision)
        end
      else
        # Fallback to text-based check (for threads without position data)
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

  def anchor_valid?
    return true unless anchored?
    !out_of_date
  end

  def anchor_context_with_highlight(chars: 100)
    return nil unless anchored? && anchor_start.present?

    content = plan.current_content
    return nil unless content.present?

    context_start = [anchor_start - chars, 0].max
    context_end = [anchor_end + chars, content.length].min

    before = content[context_start...anchor_start]
    anchor = content[anchor_start...anchor_end]
    after = content[anchor_end...context_end]

    "#{before}**#{anchor}**#{after}"
  end

  private

  def resolve_anchor_position
    return unless anchor_text.present?

    content = plan.current_content
    return unless content.present?

    occurrence = self.anchor_occurrence || 1
    return if occurrence < 1

    ranges = []
    start_pos = 0
    while (idx = content.index(anchor_text, start_pos))
      ranges << [idx, idx + anchor_text.length]
      start_pos = idx + anchor_text.length
    end

    if ranges.length >= occurrence
      range = ranges[occurrence - 1]
      self.anchor_start = range[0]
      self.anchor_end = range[1]
      self.anchor_revision = plan.current_revision
    end
  end
end
