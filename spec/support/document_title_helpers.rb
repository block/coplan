module DocumentTitleHelpers
  # Exact-source imports for tests of historical provenance. They intentionally
  # bypass current-write normalization, just as an immutable history import does.
  def create_historical_plan(title:, content:, user:, actor_type: "human", **attributes)
    plan = CoPlan::Plan.create!(title: title, created_by_user: user)
    append_historical_content(plan: plan, new_content: content, actor_type: actor_type,
      actor_id: user.id, **attributes)
    plan
  end

  def append_historical_content(plan:, new_content:, actor_type:, actor_id:, base_revision: nil, **attributes)
    return { no_op: true, version: nil } if plan.current_content == new_content
    CoPlan::Plan.transaction do
      previous = plan.current_content.to_s
      operations = CoPlan::Plans::DiffToOperations.call(old_content: previous, new_content: new_content)
      applied = CoPlan::Plans::ApplyOperations.call(content: previous, operations: operations)
      version = CoPlan::PlanVersion.create!(plan: plan, content_markdown: new_content,
        actor_type: actor_type, actor_id: actor_id, revision: plan.current_revision + 1,
        base_revision: base_revision || plan.current_revision, operations_json: applied[:applied], **attributes)
      plan.update!(current_plan_version: version, current_revision: version.revision)
      { no_op: false, version: version, plan: plan }
    end
  end

  def select_document_paragraph
    page.execute_script <<~JS
      const paragraph = document.querySelector('.inline-editor .ProseMirror > p')
      paragraph.closest('[contenteditable]').focus()
      const range = document.createRange()
      range.selectNodeContents(paragraph)
      const selection = window.getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
      document.dispatchEvent(new Event('selectionchange'))
    JS
  end

  def select_document_body
    page.execute_script <<~JS
      const editor = document.querySelector('.document-editor__body .ProseMirror')
      editor.focus()
      const range = document.createRange()
      range.selectNodeContents(editor)
      range.setStartAfter(editor.querySelector(':scope > h1:first-child'))
      const selection = window.getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
      document.dispatchEvent(new Event('selectionchange'))
    JS
  end

  def select_document_title
    page.execute_script <<~JS
      const title = document.querySelector('.inline-editor .ProseMirror > h1:first-child')
      title.closest('[contenteditable]').focus()
      const range = document.createRange()
      range.selectNodeContents(title)
      const selection = window.getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
      document.dispatchEvent(new Event('selectionchange'))
    JS
  end

  def retitle_plan(plan, title)
    CoPlan::Plans::ReplaceContent.call(plan: plan,
      new_content: CoPlan::Plans::DocumentTitle.call(plan.current_content, fallback: title, override: true),
      base_revision: plan.current_revision, actor_type: "local_agent", actor_id: plan.created_by_user_id)
    plan.reload
  end
end
RSpec.configure { |config| config.include DocumentTitleHelpers }
