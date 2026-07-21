module CoPlan
  class ReferencesController < ApplicationController
    before_action :set_plan

    def create
      # Anyone signed in can contribute a reference (like a comment);
      # removal stays with the author.
      authorize!(@plan, :contribute?)

      reference_params = params.expect(reference: [ :url, :key, :title ])
      url = reference_params[:url]
      ref_type = Reference.classify_url(url)
      target_plan_id = nil
      if ref_type == "plan"
        candidate_id = Reference.extract_target_plan_id(url)
        target_plan_id = candidate_id if candidate_id && candidate_id != @plan.id && Plan.exists?(candidate_id)
      end

      ref = @plan.references.find_or_initialize_by(url: url)
      was_new = ref.new_record?
      ref.assign_attributes(
        key: reference_params[:key].presence || ref.key,
        title: reference_params[:title].presence || ref.title,
        reference_type: ref_type,
        source: "explicit",
        target_plan_id: target_plan_id
      )
      ref.save!

      if was_new
        Plans::LogEvent.call(
          plan: @plan,
          actor: current_user,
          event_type: "reference_added",
          after: ref.url,
          metadata: { title: ref.title, reference_type: ref.reference_type }
        )
      end

      respond_to do |format|
        format.turbo_stream { render_references_stream }
        format.html { redirect_to plan_path(@plan, anchor: "footnote-references"), notice: "Reference added." }
      end
    rescue ActiveRecord::RecordInvalid => e
      respond_to do |format|
        format.turbo_stream { render_references_stream }
        format.html { redirect_to plan_path(@plan, anchor: "footnote-references"), alert: e.message }
      end
    end

    def destroy
      authorize!(@plan, :update?)

      ref = @plan.references.find(params[:id])
      removed_url = ref.url
      removed_title = ref.title
      removed_type = ref.reference_type
      ref.destroy!

      Plans::LogEvent.call(
        plan: @plan,
        actor: current_user,
        event_type: "reference_removed",
        before: removed_url,
        metadata: { title: removed_title, reference_type: removed_type }
      )

      respond_to do |format|
        format.turbo_stream { render_references_stream }
        format.html { redirect_to plan_path(@plan, anchor: "footnote-references"), notice: "Reference removed." }
      end
    end

    private

    def set_plan
      @plan = Plan.find(params[:plan_id])
    end

    def render_references_stream
      references = @plan.references.reload.order(reference_type: :asc, created_at: :desc)
      render turbo_stream: [
        turbo_stream.replace(
          "plan-references",
          partial: "coplan/plans/references",
          locals: { references: references, plan: @plan }
        ),
        turbo_stream.replace(
          "references-count",
          html: helpers.content_tag(:span, references.size, class: "section-count", id: "references-count")
        ),
        # The document outline shows the same count; without this it goes
        # stale the moment a reference is added or removed.
        turbo_stream.replace(
          "nav-references-count",
          html: helpers.content_tag(:span, references.size, class: "section-count", id: "nav-references-count")
        )
      ]
    end
  end
end
