require "rails_helper"

# Expanding an image. The image is a real attachment served through Active
# Storage, the way agents embed screenshots and mockups in plans.
RSpec.describe "Expanding an image", type: :system do
  let(:author) { create(:coplan_user, email: "author@example.com") }

  let(:plan) do
    p = CoPlan::Plan.create!(title: "Mockup Plan", created_by_user: author)
    screenshot = attach(p, "console.png", width: 1600, height: 900)
    icon = attach(p, "icon.png", width: 16, height: 16)
    content = <<~MARKDOWN
      # Mockups

      ## Console view

      ![Console mockup](#{blob_path(screenshot)})

      A status icon ![icon](#{blob_path(icon)}) is too small to expand.

      [![Linked mockup](#{blob_path(screenshot)})](https://example.com/full)

      | Step | Mockup |
      |---|---|
      | Warn | ![Table mockup](#{blob_path(screenshot)}) |
    MARKDOWN
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: content, actor_type: "human", actor_id: author.id
    )
    p.update!(current_plan_version: version, current_revision: 1)
    p
  end

  # A solid-color PNG of the given size, built in memory so the spec needs
  # no binary fixture.
  def png(width, height)
    chunk = ->(type, data) { [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N") }
    row = "\x00".b + ([ 37, 99, 235 ].pack("C3") * width)
    "\x89PNG\r\n\x1A\n".b +
      chunk.call("IHDR", [ width, height, 8, 2, 0, 0, 0 ].pack("NNCCCCC")) +
      chunk.call("IDAT", Zlib::Deflate.deflate(row * height)) +
      chunk.call("IEND", "")
  end

  def attach(plan, filename, width:, height:)
    plan.attachments.attach(io: StringIO.new(png(width, height)), filename:, content_type: "image/png")
    plan.attachments.blobs.find_by!(filename:)
  end

  def blob_path(blob)
    Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
  end

  def sign_in(user)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
    expect(page).to have_button("Menu")
  end

  def zoom_percent
    find(".expander__readout").text.to_i
  end

  let(:screenshot_frame) { find(".image-frame.is-expandable", match: :first) }

  before do
    sign_in(author)
    visit plan_page_path(plan)
    expect(page).to have_css(".image-frame.is-expandable", count: 3, wait: 10)
  end

  it "shows the expand arrows only while the image is hovered" do
    button = screenshot_frame.find(".image-frame__expand", visible: :all)
    expect(button["aria-label"]).to eq("Expand image")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('.image-frame__expand')).opacity")).to eq("0")

    screenshot_frame.hover
    expect(screenshot_frame).to have_css(".image-frame__expand", visible: :all, wait: 5) { |el| el.style("opacity")["opacity"] == "1" }
  end

  it "keeps the image on its own line, with a frame that hugs it" do
    layout = page.evaluate_script(<<~JS)
      (() => {
        const img = document.querySelector("img[alt='Console mockup']");
        const frame = img.closest(".image-frame");
        return { display: getComputedStyle(frame).display,
                 gap: Math.abs(frame.getBoundingClientRect().width - img.getBoundingClientRect().width) };
      })()
    JS
    expect(layout["display"]).to eq("block")
    expect(layout["gap"]).to be <= 1
  end

  describe "an icon-sized image" do
    before do
      # Wait for the icon itself to load, so the size check has run.
      expect(page).to have_css("img[alt='icon']") { |img| img.evaluate_script("this.complete && this.naturalWidth === 16") }
    end

    it "offers no expander" do
      expect(page).to have_css(".image-frame:not(.is-expandable) img[alt='icon']")
    end

    it "does not expand on a double-click" do
      find("img[alt='icon']").double_click

      expect(page).to have_no_css("dialog.expander")
    end
  end

  it "expands a linked image from its corner button without following the link" do
    frame = find("img[alt='Linked mockup']").ancestor(".image-frame")
    frame.hover
    frame.find(".image-frame__expand").click

    expect(page).to have_css(".expander--image .expander__title", text: "Linked mockup")
    expect(page).to have_current_path(plan_page_path(plan))
  end

  describe "inside an expanded table" do
    before do
      find("td", text: "Warn").double_click
      expect(page).to have_css(".expander--grid img[alt='Table mockup']")
    end

    it "shows the image without a second expand control" do
      expect(page).to have_no_css(".expander--grid .image-frame__expand", visible: :all)
    end

    it "keeps the table open when the image is double-clicked" do
      find(".expander--grid img[alt='Table mockup']").double_click

      expect(page).to have_css(".expander--grid")
      expect(page).to have_no_css(".expander--image")
    end
  end

  describe "expanded" do
    before do
      screenshot_frame.hover
      screenshot_frame.find(".image-frame__expand").click
      expect(page).to have_css(".expander--image .expander__canvas > img")
    end

    it "titles itself with the image's alt text" do
      expect(page).to have_css(".expander__title", text: "Console mockup")
    end

    it "fits the whole image to the window" do
      fit = page.evaluate_script(<<~JS)
        (() => {
          const view = document.querySelector('.expander__canvas').getBoundingClientRect();
          const img = document.querySelector('.expander__canvas > img').getBoundingClientRect();
          return {
            contained: img.left >= view.left && img.top >= view.top && img.right <= view.right + 1 && img.bottom <= view.bottom + 1,
            fills: img.width >= view.width - 60 || img.height >= view.height - 60
          };
        })()
      JS
      expect(fit).to eq("contained" => true, "fills" => true)
    end

    it "uses the diagram zoom toolbar and keys" do
      fitted = zoom_percent
      find("button[aria-label='Zoom in']").click
      expect(zoom_percent).to be > fitted

      find("button[aria-label='Actual size']").click
      expect(zoom_percent).to eq(100)

      find(".expander__canvas").send_keys("0")
      expect(zoom_percent).to eq(fitted)
    end

    it "pans on drag without dismissing the surface" do
      click_button "Actual size"
      before_drag = page.evaluate_script('document.querySelector(".expander__canvas > img").style.transform')

      page.driver.browser.action
          .move_to(find(".expander__canvas").native, 0, 0)
          .click_and_hold
          .move_by(60, 40)
          .release
          .perform

      expect(page).to have_css(".expander--image")
      expect(page.evaluate_script('document.querySelector(".expander__canvas > img").style.transform')).not_to eq(before_drag)
    end

    it "closes on Escape" do
      find(".expander__canvas").send_keys(:escape)

      expect(page).to have_no_css(".expander--image")
      expect(page).to have_css(".image-frame img[alt='Console mockup']")
    end
  end

  it "expands on a double-click" do
    find("img[alt='Console mockup']").double_click

    expect(page).to have_css(".expander--image .expander__title", text: "Console mockup")
  end

  it "expands the image, not its table, when double-clicked inside a table cell" do
    find("img[alt='Table mockup']").double_click

    expect(page).to have_css(".expander--image .expander__title", text: "Table mockup")
    expect(page).to have_no_css(".expander--grid")
  end
end
