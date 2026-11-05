This diagram was drawn with the `draw-diagram` agent skill. Its source sits in the document, in the fenced block under the image; CoPlan shows the image that was rendered from it. Expand **Source · draw-diagram** to read the source. **Skill: draw-diagram** names the skill an agent uses to change it.

```draw-diagram {image="{{rendered_diagram_url}}" alt="A rendered diagram keeps its source" width=760 lang=javascript}
{{rendered_diagram_source}}
```

## Changing the diagram

An agent asked to change this diagram does not redraw it from the picture. It gets the `draw-diagram` skill, reads the source from the plan, including the notes in its comments, edits it, and renders it again. It uploads the new image as an attachment and, in one edit, puts the edited source in the fence and the new image URL in its `image` attribute.

CoPlan knows nothing about how to render the diagram: that's the skill's job. The source is a program, so an agent that didn't write it renders it the way the skill says for diagrams written by someone else.

If someone edits the source without rendering it again, the image is marked as out of date until a new one replaces it.

Mermaid stays the first choice for diagrams a person may want to edit directly. CoPlan draws Mermaid itself, so it needs no image.
