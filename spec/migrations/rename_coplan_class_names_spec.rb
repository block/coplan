require "rails_helper"
require Coplan::Engine.root.join("db/migrate/20261123151500_rename_coplan_class_names.rb")

RSpec.describe RenameCoplanClassNames do
  subject(:migration) { described_class.new }

  before do
    migration.verbose = false
    # MySQL table comments use DDL, which would commit the fixture transaction.
    allow(migration.connection).to receive(:supports_comments?).and_return(false)
  end

  it "migrates persisted class names, leaves host records alone, and supports rollback" do
    user = create(:coplan_user)
    library = user.library
    library.update_column(:owner_type, "CoPlan::User")

    plan = create(:plan, created_by_user: user)
    blob = ActiveStorage::Blob.create_before_direct_upload!(
      filename: "notes.txt", byte_size: 5, checksum: "0pmlW+cQLmt3P6q6Rgz+xA=="
    )
    ActiveStorage::Attachment.insert_all!([
      { name: "attachments", record_type: "CoPlan::Plan", record_id: plan.id, blob_id: blob.id },
      { name: "avatar", record_type: "User", record_id: user.id, blob_id: blob.id }
    ])
    ActiveAdmin::Comment.insert_all!([
      { author_type: "CoPlan::User", author_id: 1, resource_type: "CoPlan::Plan", resource_id: 1,
        namespace: "admin", body: "Legacy comment" },
      { author_type: "User", author_id: 1, resource_type: "User", resource_id: 1,
        namespace: "admin", body: "Host comment" }
    ])

    migration.up
    migration.up

    expect(library.reload.owner).to eq(user)
    expect(plan.attachments.blobs).to contain_exactly(blob)
    expect(ActiveAdmin::Comment.find_by!(body: "Legacy comment").attributes.values_at("author_type", "resource_type"))
      .to eq([ "Coplan::User", "Coplan::Plan" ])
    expect(ActiveAdmin::Comment.find_by!(body: "Host comment").attributes.values_at("author_type", "resource_type"))
      .to eq([ "User", "User" ])

    migration.down

    expect(library.reload.owner_type).to eq("CoPlan::User")
    expect(blob.attachments.pluck(:record_type)).to contain_exactly("CoPlan::Plan", "User")
    expect(ActiveAdmin::Comment.find_by!(body: "Legacy comment").attributes.values_at("author_type", "resource_type"))
      .to eq([ "CoPlan::User", "CoPlan::Plan" ])
  end
end
