require "rails_helper"

RSpec.describe "llms.txt", type: :request do
  it "serves markdown to anonymous visitors" do
    get llms_txt_path
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/markdown")
  end
end
