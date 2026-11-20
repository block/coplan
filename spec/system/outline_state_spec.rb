require "rails_helper"

# Unit tests run the real controller methods in the browser's JavaScript runtime.
# Rendering and storage are stubbed so these cases exercise only state rules.
RSpec.describe "Outline expansion state rules", type: :system do
  before { visit sign_in_path }

  def state_after(actions)
    page.evaluate_async_script(<<~JS, actions)
      const actions = arguments[0], done = arguments[arguments.length - 1];
      import("controllers/coplan/content_nav_controller").then(({default: Controller}) => {
        const controller = Object.create(Controller.prototype);
        controller._expanded = new Map([["context", false], ["architecture", false], ["detail", false]]);
        controller._parentById = new Map([["detail", "context"], ["leaf", "detail"]]);
        controller._autoExpanded = new Set();
        let stored = {};
        controller.storedOutlineState = () => ({...stored});
        controller.storeOutlineState = value => { stored = value };
        controller.renderExpanded = () => {};
        controller.renderBadges = () => {};
        for (const [action, id] of actions) {
          if (action === "click") controller.toggleLinkedEntry(id);
          else controller.revealEntry(id, {includeSelf: true});
        }
        done({expanded: Object.fromEntries(controller._expanded), automatic: [...controller._autoExpanded], stored});
      }).catch(error => done({error: error.message}));
    JS
  end

  it "treats a second label click as a remembered close" do
    result = state_after([ [ "click", "context" ], [ "click", "context" ] ])
    expect(result.fetch("expanded").fetch("context")).to be false
    expect(result.fetch("stored")).to eq("context" => false)
    expect(result.fetch("automatic")).to be_empty
  end

  it "keeps two clicked branches open" do
    result = state_after([ [ "click", "context" ], [ "click", "architecture" ] ])
    expect(result.fetch("expanded")).to include("context" => true, "architecture" => true)
    expect(result.fetch("stored")).to include("context" => true, "architecture" => true)
  end

  it "closes branches opened only by automatic navigation on leaving" do
    result = state_after([ [ "auto", "context" ], [ "auto", "architecture" ] ])
    expect(result.fetch("expanded")).to include("context" => false, "architecture" => true)
    expect(result.fetch("stored")).to be_empty
  end

  it "preserves clicked branches while automatic navigation moves elsewhere" do
    result = state_after([ [ "click", "context" ], [ "auto", "architecture" ], [ "auto", "elsewhere" ] ])
    expect(result.fetch("expanded")).to include("context" => true, "architecture" => false)
  end

  it "makes the ancestor path manual when clicking inside an automatic branch" do
    result = state_after([ [ "auto", "context" ], [ "click", "detail" ], [ "auto", "architecture" ] ])
    expect(result.fetch("expanded")).to include("context" => true, "detail" => true)
    expect(result.fetch("stored")).to include("context" => true, "detail" => true)
    expect(result.fetch("automatic")).not_to include("context", "detail")
  end
end
