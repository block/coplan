module DocumentSupportHelpers
  def expand_plan_section(id)
    disclosure = find("##{id} > details.document-support__disclosure")
    disclosure.find("summary").click unless disclosure.matches_css?("[open]", wait: 0)
    expect(disclosure).to match_css("[open]")
  end
end

RSpec.configure do |config|
  config.include DocumentSupportHelpers, type: :system
end
