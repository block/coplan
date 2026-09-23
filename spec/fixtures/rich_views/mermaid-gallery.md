# Mermaid stress gallery

## Flowchart: shapes, nested groups and cross-links

```mermaid
flowchart LR
  subgraph Client[Client applications]
    Web([Web application]) --> Gateway{Route request?}
    Phone([Mobile application]) --> Gateway
  end
  subgraph Core[Processing boundary]
    Gateway --> Validate[[Validate command]]
    Validate --> Decision{Can apply?}
    Decision -->|yes| Apply[Apply mutation]
    Decision -->|no| Reject>Explain rejection]
    Apply --> Journal[(Command journal)]
    Apply --> Snapshot[/Build snapshot/]
    Snapshot --> Published((Published))
    Journal --> Replay[[Replay history]]
    Replay -.-> Validate
  end
  subgraph External[External systems]
    Published --> Queue{{Delivery queue}}
    Queue --> Worker[Background worker]
    Worker --> Remote[(Remote storage)]
    Worker --> Retry{Try again?}
    Retry -.-> Queue
    Retry --> Stop(((Stopped)))
  end
  Reject -.-> Phone
  Published --> Web
  classDef durable fill:#284768,stroke:#83baff,color:#ffffff
  class Journal,Remote durable
```

## Expanded shapes: documents and storage

```mermaid
flowchart TB
  Request@{ shape: doc, label: "Incoming request" }
  Batch@{ shape: docs, label: "Batch of documents" }
  Check@{ shape: hex, label: "Prepare transaction" }
  Store@{ shape: cyl, label: "Persistent store" }
  Human@{ shape: manual-input, label: "Operator input" }
  Done@{ shape: stadium, label: "Complete" }
  Request --> Check
  Batch --> Check
  Human --> Check
  Check --> Store --> Done
```

## Sequence: concurrency, retries and failure paths

```mermaid
sequenceDiagram
  autonumber
  actor Reader
  participant UI as Editor
  participant API as Command API
  participant Lease as Lease manager
  participant DB as Version store
  participant Events as Event bus
  Reader->>UI: Submit change
  UI->>+API: Apply(baseRevision, operations)
  API->>+Lease: Acquire writer lease
  Lease-->>-API: Lease token
  API->>DB: Read current revision
  alt Revision matches
    loop Each operation
      API->>API: Validate and transform
    end
    par Persist version
      API->>DB: Write immutable version
      DB-->>API: Revision + 1
    and Prepare notifications
      API->>Events: Build recipient set
    end
    API-->>UI: Updated document
  else A human edited meanwhile
    API-->>UI: Conflict with human diff
    UI-->>Reader: Review the intervening change
  end
  API->>Lease: Release lease
  deactivate API
  opt New version was committed
    Events-->>UI: Refresh anchors
  end
```

## State: nested lifecycle and recovery

```mermaid
stateDiagram-v2
  [*] --> Idle
  Idle --> Editing: open document
  state Editing {
    [*] --> Clean
    Clean --> Dirty: type
    Dirty --> Saving: submit
    Saving --> Clean: saved
    Saving --> Conflict: stale revision
    Conflict --> Dirty: review and retry
  }
  Editing --> Offline: connection lost
  state Offline {
    [*] --> Cached
    Cached --> Queued: edit locally
    Queued --> Reconnecting: retry
  }
  Offline --> Editing: connection restored
  Editing --> Archived: archive
  Archived --> [*]
```

## Class: contracts, inheritance and multiplicity

```mermaid
classDiagram
  class Document {
    +UUID id
    +int revision
    +apply(Operation[] changes) Version
  }
  class Version {
    +int revision
    +String markdown
    +DateTime createdAt
  }
  class Operation {
    <<interface>>
    +validate() bool
    +transform(Version base) Operation
  }
  class ReplaceText {
    +String before
    +String after
  }
  class InsertSection {
    +String heading
    +String markdown
  }
  class Discussion {
    +String status
    +resolve()
  }
  class Comment {
    +String body
    +UUID authorId
  }
  Document "1" *-- "1..*" Version
  Document "1" o-- "0..*" Discussion
  Discussion "1" *-- "1..*" Comment
  Operation <|.. ReplaceText
  Operation <|.. InsertSection
  Operation ..> Version : transforms against
```

## Entity relationships: composite domain

```mermaid
erDiagram
  ORGANIZATION ||--o{ USER : employs
  ORGANIZATION ||--o{ DOCUMENT : owns
  USER ||--o{ DOCUMENT : authors
  DOCUMENT ||--|{ VERSION : contains
  DOCUMENT ||--o{ DISCUSSION : receives
  DISCUSSION ||--|{ COMMENT : contains
  USER ||--o{ COMMENT : writes
  VERSION ||--o{ DISCUSSION : anchors
  DOCUMENT {
    string id PK
    string organization_id FK
    int current_revision
    string title
  }
  VERSION {
    string id PK
    string document_id FK
    int revision
    text markdown
  }
  COMMENT {
    string id PK
    string discussion_id FK
    string author_id FK
    text body
  }
```

## Mindmap: a broad review surface

```mermaid
mindmap
  root((Document review))
    Content
      Prose
        Long paragraphs
        Inline code
      Tables
        Wide inventories
        Pinned headers
        Wrapped cells
      Diagrams
        Flowcharts
        Sequence diagrams
        State machines
    Collaboration
      Comments
        Exact anchors
        Replies
        Resolution
      Agents
        Leases
        Version history
        Conflict handling
    Navigation
      Keyboard
        Arrows
        Home and End
      Touch
        Pan
        Pinch to zoom
```

## Gantt: dependencies and milestones

```mermaid
gantt
  title Release dependencies
  dateFormat YYYY-MM-DD
  excludes weekends
  section Contracts
  API review :done, api, 2026-09-01, 4d
  Schema design :done, schema, after api, 3d
  section Implementation
  Storage adapter :active, storage, after schema, 7d
  Rendering pipeline :render, after schema, 8d
  Collaboration :collab, after storage, 5d
  section Validation
  Integration tests :tests, after render collab, 4d
  Accessibility review :a11y, after render, 3d
  Release :milestone, after tests a11y, 0d
```
