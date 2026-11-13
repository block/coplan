require "rails_helper"

RSpec.describe "Browser synchronization", type: :system do
  let(:author) { create(:coplan_user, email: "browser-sync@example.com") }
  let(:plan) { create(:plan, created_by_user: author) }

  before do
    visit sign_in_path
    expect(page.evaluate_script("typeof CapybaraLockstep")).to eq("object")
    fill_in "Email address", with: author.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end

  it "waits for a real fetch and its callback before the next browser read" do
    visit plan_page_path(plan)
    allow_any_instance_of(CoPlan::PlansController).to receive(:editor_state).and_wrap_original do |action|
      sleep 0.25 # Deliberately slow the actual response, beyond a WebDriver round-trip.
      action.call
    end
    page.execute_script(<<~JS, editor_state_plan_path(plan))
      window.syncFetchFinished = false
      fetch(arguments[0]).then(response => response.json()).then(() => { window.syncFetchFinished = true })
    JS

    # A single read, without an assertion retry, must see the finished callback.
    expect(page.evaluate_script("window.syncFetchFinished")).to be(true)
  end

  it "waits for a delayed real cable stream and the resulting comment highlights" do
    thread = create(:comment_thread, :with_anchor, plan: plan, created_by_user: author)
    create(:comment, comment_thread: thread, author_id: author.id)
    visit plan_page_path(plan)
    expect(page).to have_css("mark.anchor-highlight", exact_text: "Some content here")
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all, minimum: 2, wait: 10)
    page.execute_script(<<~JS)
      document.addEventListener("turbo:before-stream-render", event => {
        if (!event.target.getAttribute("target")?.startsWith("comment_thread_")) return
        const render = event.detail.render
        event.detail.render = async stream => {
          await new Promise(resolve => setTimeout(resolve, 250))
          await render(stream)
          window.syncStreamRendered = true
        }
        window.syncStreamReceived = true
      })
    JS

    # The server initiates this update independently of a browser command.
    # Observe its arrival, then explicitly join the shared synchronization layer.
    Capybara::Lockstep.with_mode(:manual) do
      CoPlan::Broadcaster.replace_to(plan, target: ActionView::RecordIdentifier.dom_id(thread),
        partial: "coplan/comment_threads/thread_popover", locals: { thread: thread, plan: plan })
      Selenium::WebDriver::Wait.new(timeout: 5).until { page.evaluate_script("window.syncStreamReceived") }
    end
    Capybara::Lockstep.synchronize

    expect(page.evaluate_script("window.syncStreamRendered")).to be(true)
    expect(all("mark.anchor-highlight").map(&:text)).to eq([ "Some content here" ])
  end

  [ "cancelled", "failed" ].each do |outcome|
    it "releases synchronization after a #{outcome} Turbo renderer" do
      visit plan_page_path(plan)
      Capybara::Lockstep.with_mode(:manual) do
        page.execute_script(<<~JS, outcome)
          const outcome = arguments[0]
          document.addEventListener("turbo:before-stream-render", event => {
            if (event.target.getAttribute("target") !== "sync-probe") return
            if (outcome === "cancelled") event.preventDefault()
            else event.detail.render = async () => { throw new Error("Intentional render failure") }
            window.syncProbeReceived = true
          })
          Turbo.renderStreamMessage('<turbo-stream action="append" target="sync-probe"><template>Probe</template></turbo-stream>')
        JS
        Selenium::WebDriver::Wait.new(timeout: 5).until { page.evaluate_script("window.syncProbeReceived") }
      end
      # Observe the idle callback itself, so the gem's timeout logging cannot
      # make a leaked work count pass this regression.
      using_wait_time(5) do
        page.evaluate_async_script("CapybaraLockstep.synchronize(arguments[0])")
      end
      expect(page).to have_css("#plan-content-body")
    end
  end
end
