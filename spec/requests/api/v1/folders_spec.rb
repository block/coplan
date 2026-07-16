require "rails_helper"

RSpec.describe "Api::V1::Folders", type: :request do
  let(:alice) { create(:coplan_user) }
  let(:bob) { create(:coplan_user) }
  let(:admin) { create(:coplan_user, :admin) }
  let(:alice_token) { create(:api_token, user: alice, raw_token: "test-token-alice") }
  let(:bob_token) { create(:api_token, user: bob, raw_token: "test-token-bob") }
  let(:admin_token) { create(:api_token, user: admin, raw_token: "test-token-admin") }
  let(:headers) { { "Authorization" => "Bearer test-token-alice" } }
  let(:bob_headers) { { "Authorization" => "Bearer test-token-bob" } }
  let(:admin_headers) { { "Authorization" => "Bearer test-token-admin" } }

  before do
    alice_token
    bob_token
    admin_token
  end

  describe "GET /api/v1/folders" do
    it "requires authentication" do
      get api_v1_folders_path
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns folders with paths and visible plan counts" do
      root = create(:folder, name: "Team EBT", created_by_user: alice)
      sub = create(:folder, name: "Q3", parent: root, created_by_user: alice)
      create(:plan, :considering, created_by_user: bob).update!(folder: sub)

      get api_v1_folders_path, headers: headers
      expect(response).to have_http_status(:success)
      folders = JSON.parse(response.body)
      sub_json = folders.find { |f| f["id"] == sub.id }
      expect(sub_json["path"]).to eq("Team EBT/Q3")
      expect(sub_json["parent_id"]).to eq(root.id)
      expect(sub_json["plans_count"]).to eq(1)
      expect(folders.find { |f| f["id"] == root.id }["plans_count"]).to eq(0)
    end

    it "does not count other users' brainstorm plans" do
      folder = create(:folder, created_by_user: alice)
      create(:plan, :brainstorm, created_by_user: bob).update!(folder: folder)
      create(:plan, :brainstorm, created_by_user: alice).update!(folder: folder)
      create(:plan, :considering, created_by_user: bob).update!(folder: folder)

      get api_v1_folders_path, headers: headers
      counts = JSON.parse(response.body).find { |f| f["id"] == folder.id }
      # Alice sees Bob's published plan and her own brainstorm — not Bob's brainstorm.
      expect(counts["plans_count"]).to eq(2)

      get api_v1_folders_path, headers: bob_headers
      counts = JSON.parse(response.body).find { |f| f["id"] == folder.id }
      expect(counts["plans_count"]).to eq(2)
    end
  end

  describe "POST /api/v1/folders" do
    it "creates a root folder" do
      post api_v1_folders_path, params: { name: "Infra" }.to_json,
        headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["name"]).to eq("Infra")
      expect(json["parent_id"]).to be_nil
      expect(CoPlan::Folder.find(json["id"]).created_by_user).to eq(alice)
    end

    it "creates a nested folder" do
      root = create(:folder, name: "Infra", created_by_user: bob)
      post api_v1_folders_path, params: { name: "Q3", parent_id: root.id }.to_json,
        headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["path"]).to eq("Infra/Q3")
    end

    it "rejects an unknown parent_id" do
      post api_v1_folders_path, params: { name: "Q3", parent_id: "nope" }.to_json,
        headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include("Unknown parent_id")
    end

    it "rejects invalid names" do
      post api_v1_folders_path, params: { name: "a/b" }.to_json,
        headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects duplicate sibling names" do
      create(:folder, name: "Infra")
      post api_v1_folders_path, params: { name: "Infra" }.to_json,
        headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH /api/v1/folders/:id" do
    let(:folder) { create(:folder, name: "Old Name", created_by_user: alice) }

    it "lets the creator rename" do
      patch api_v1_folder_path(folder), params: { name: "New Name" }.to_json,
        headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:success)
      expect(folder.reload.name).to eq("New Name")
    end

    it "lets an admin rename" do
      patch api_v1_folder_path(folder), params: { name: "Admin Name" }.to_json,
        headers: admin_headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:success)
      expect(folder.reload.name).to eq("Admin Name")
    end

    it "forbids other users from renaming" do
      patch api_v1_folder_path(folder), params: { name: "Bob Name" }.to_json,
        headers: bob_headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
      expect(folder.reload.name).to eq("Old Name")
    end

    it "can re-parent a folder" do
      new_parent = create(:folder, name: "Parent")
      patch api_v1_folder_path(folder), params: { parent_id: new_parent.id }.to_json,
        headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:success)
      expect(folder.reload.parent).to eq(new_parent)
    end

    it "rejects a cycle" do
      child = create(:folder, name: "Child", parent: folder, created_by_user: alice)
      patch api_v1_folder_path(folder), params: { parent_id: child.id }.to_json,
        headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s for a missing folder" do
      patch api_v1_folder_path("missing"), params: { name: "X" }.to_json,
        headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/folders/:id" do
    let(:folder) { create(:folder, created_by_user: alice) }

    it "deletes an empty folder as creator" do
      delete api_v1_folder_path(folder), headers: headers
      expect(response).to have_http_status(:no_content)
      expect(CoPlan::Folder.exists?(folder.id)).to be false
    end

    it "forbids non-creator non-admins" do
      delete api_v1_folder_path(folder), headers: bob_headers
      expect(response).to have_http_status(:forbidden)
      expect(CoPlan::Folder.exists?(folder.id)).to be true
    end

    it "refuses to delete a folder containing plans" do
      create(:plan, :considering, created_by_user: alice).update!(folder: folder)
      delete api_v1_folder_path(folder), headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include("contains plans")
      expect(CoPlan::Folder.exists?(folder.id)).to be true
    end

    it "refuses to delete a folder with subfolders" do
      create(:folder, parent: folder)
      delete api_v1_folder_path(folder), headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(CoPlan::Folder.exists?(folder.id)).to be true
    end
  end
end
