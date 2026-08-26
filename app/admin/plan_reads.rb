# Read receipts. Mostly here to answer one support question: "why is my
# agent getting human_edit_pending?" — compare last_seen_revision against
# the plan's most recent human version.
ActiveAdmin.register CoPlan::PlanRead, as: "PlanRead" do
  actions :index, :show

  filter :plan
  filter :reader_type, as: :select, collection: CoPlan::PlanRead::READER_TYPES
  filter :reader_id
  filter :last_seen_revision
  filter :last_seen_at

  index do
    selectable_column
    id_column
    column :plan
    column :reader_type
    column :reader_id
    column :last_seen_revision
    column("Plan revision") { |read| read.plan.current_revision }
    column :last_seen_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :plan
      row :reader_type
      row :reader_id
      row :last_seen_revision
      row("Plan revision") { |read| read.plan.current_revision }
      row("Last human revision") do |read|
        read.plan.plan_versions.where(actor_type: "human").maximum(:revision)
      end
      row :last_seen_at
      row :created_at
      row :updated_at
    end
  end
end
