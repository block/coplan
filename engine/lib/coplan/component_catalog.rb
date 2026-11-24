module Coplan
  # Browser-ready ES modules. Registered source is intentionally discoverable
  # in the host's authoring guide. Keep secrets and server code out of it.
  class ComponentCatalog
    ROOT_GUIDE = "You write regular browser JavaScript here. root is the <main> element inside this component’s frame. Use root.style to change its appearance and root.append(element) to add a child.".freeze
    DOM_REFERENCE_URL = "https://developer.mozilla.org/en-US/docs/Web/API/Document_Object_Model/Introduction".freeze
    BASE_EXAMPLE = <<~JS.chomp.freeze
      root.style.backgroundColor = "var(--coplan-surface-muted)";
      root.textContent = "Hello!";
    JS

    attr_reader :libraries, :types

    def initialize
      @libraries = {}
      @types = {}
      @guides = {}
      dir = File.join(__dir__, "components")
      library("diagram@1", source: File.read(File.join(dir, "diagram.js")), example: 'const { Diagram } = await import("diagram")')
      type("diagram", source: File.read(File.join(dir, "diagram_type.js")), uses: [ "diagram@1" ],
        bindings: [ "diagram" ],
        guide: "This starter draws a vertical flow. Its two authoring methods are diagram.node(id, label) and diagram.edge(from, to, label). Nodes appear in declaration order. The edge label is optional.",
        example: <<~JS.chomp)
        diagram.node("checkout", "Checkout");
        diagram.node("payment", "Payment");
        diagram.node("receipt", "Receipt");

        diagram.edge("checkout", "payment", "submit");
        diagram.edge("payment", "receipt", "approved");
      JS
    end

    NAME = /\A[a-z][a-z0-9-]*\z/
    VERSIONED = /\A[a-z][a-z0-9-]*@[a-z0-9][a-z0-9.\-]*\z/

    def library(name, source:, example:)
      raise ArgumentError, "Expected a versioned library name" unless VERSIONED.match?(name)
      libraries[name] = entry(source, example)
    end

    def type(name, source:, bindings:, example:, uses: [], text_comments: true, guide: nil)
      raise ArgumentError, "Invalid component type" unless NAME.match?(name)
      raise ArgumentError, "Invalid type bindings" unless bindings.uniq == bindings && bindings.all? { |key| key.match?(/\A[a-zA-Z_$][\w$]*\z/) && key != "root" }
      raise ArgumentError, "Invalid type dependencies" unless uses.all? { |key| VERSIONED.match?(key) }
      raise ArgumentError, "Expected a boolean for text_comments" unless [ true, false ].include?(text_comments)
      @guides[name] = guide
      types[name] = entry(source, example).merge("bindings" => bindings, "uses" => uses, "text_comments" => text_comments)
    end

    # The empty key represents a component with no type attribute in Markdown.
    # Authoring help and starter code follow the host's currently installed types.
    def authoring_types
      base = {
        "label" => "Base", "bindings" => [], "uses" => [], "example" => BASE_EXAMPLE,
        "guide" => 'Set the background to a theme color as shown below, or try a CSS color such as "lavender". Use root.textContent for plain text.'
      }
      types.each_with_object({ "" => base }) do |(name, type), choices|
        choices[name] = type.slice("bindings", "uses").merge("label" => name == "base" ? "Base (host type)" : name.tr("-", " ").capitalize, "guide" => @guides[name],
          "example" => type["example"].presence || BASE_EXAMPLE)
      end
    end

    # Store only entries used by this revision. A missing entry stays missing
    # when that revision is reopened after a later host configuration change.
    def snapshot(regions)
      selected = types.slice(*regions.filter_map { |region| region.attributes["type"] })
      keys = regions.flat_map { |region| region.attributes.fetch("uses", "").split } + selected.values.flat_map { |type| type.fetch("uses") }
      { "types" => selected, "libraries" => libraries.slice(*keys) }
    end

    def self.resolve(attributes, snapshot)
      name = attributes["type"]
      wrapper = snapshot.fetch("types")[name]
      return { error: "Unknown component type: #{name}" } if name && !wrapper

      keys = (attributes.fetch("uses", "").split + Array(wrapper&.fetch("uses"))).uniq
      modules = {}
      keys.each do |key|
        entry = snapshot.fetch("libraries")[key]
        return { error: "Unknown component library: #{key}" } unless entry
        specifier = key.split("@").first
        return { error: "Conflicting versions of #{specifier}" } if modules.key?(specifier)
        modules[specifier] = entry.fetch("source")
      end
      { libraries: modules, wrapper: wrapper&.slice("source", "bindings") }
    end

    private

    def entry(source, example)
      { "source" => source, "sha256" => Digest::SHA256.hexdigest(source), "example" => example }
    end
  end
end
