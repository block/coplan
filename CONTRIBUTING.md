# Contributing to CoPlan

Thanks for helping improve CoPlan. Keep pull requests focused and make it easy for reviewers to see the behavior that changed.

## Before opening a pull request

- Put product behavior in the Rails engine (`engine/`). Keep the host app for deployment configuration and host-specific integrations. Follow the conventions in [AGENTS.md](AGENTS.md).
- Add **real browser specs** for new or changed UI behavior in `spec/system/`. These are RSpec system specs using Capybara and Selenium with headless Chrome, so the page's JavaScript runs. Drive the feature through the UI as a user would and assert the visible result and, where relevant, the persisted change. Cover meaningful success, failure, and edge cases. A request spec, mocked JavaScript call, or assertion that an element merely exists does not replace a browser spec for an interactive feature.
- Add model, service, or request specs where they help cover domain behavior, authorization, and API cases. Keep specs focused on behavior rather than implementation details. For a feature without a browser UI, use the appropriate non-browser specs and explain why a browser spec does not apply.
- Run the relevant browser specs with `bundle exec rspec spec/system/<feature>_spec.rb`, then run the full suite with `bundle exec rspec`. If you cannot run it, say why and identify exactly what you did run.
- For every feature, test the affected UI in both **light and dark themes**. Check the complete interaction, including loading, success, error, and empty states that apply. For a feature without a UI, explain in the PR why theme testing does not apply.
- Include **a video or images** in every feature PR so reviewers can see the result. Show both themes for UI features; a short video or labeled screenshots are both fine. For features without a UI, include images of the relevant API or command output, or a short video demonstrating it. Include before-and-after evidence for visual fixes when useful.

## Pull request description

Use the [pull request template](.github/PULL_REQUEST_TEMPLATE.md). Explain what changed and why, link the relevant issue or plan, describe the specs and manual checks you ran, and attach the visual evidence. Mention any limitations or follow-up work that reviewers need to know about.
