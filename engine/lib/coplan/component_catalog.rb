module Coplan
  # Browser-ready ES modules. Registered source is intentionally discoverable
  # in the host's authoring guide. Keep secrets and server code out of it.
  class ComponentCatalog
    attr_reader :libraries, :types

    def initialize
      @libraries = {}
      @types = {}
      dir = File.join(__dir__, "components")
      library("diagram@1", source: File.read(File.join(dir, "diagram.js")), example: 'const { Diagram } = await import("diagram")')
      type("diagram", source: File.read(File.join(dir, "diagram_type.js")), uses: [ "diagram@1" ],
        bindings: [ "diagram" ], example: 'diagram.node("api", "Checkout API")')
    end

    NAME = /\A[a-z][a-z0-9-]*\z/
    VERSIONED = /\A[a-z][a-z0-9-]*@[a-z0-9][a-z0-9.\-]*\z/

    def library(name, source:, example:)
      raise ArgumentError, "Expected a versioned library name" unless VERSIONED.match?(name)
      libraries[name] = entry(source, example)
    end

    def type(name, source:, bindings:, example:, uses: [], text_comments: true)
      raise ArgumentError, "Invalid component type" unless NAME.match?(name)
      raise ArgumentError, "Invalid type bindings" unless bindings.uniq == bindings && bindings.all? { |key| key.match?(/\A[a-zA-Z_$][\w$]*\z/) && key != "root" }
      raise ArgumentError, "Invalid type dependencies" unless uses.all? { |key| VERSIONED.match?(key) }
      raise ArgumentError, "Expected a boolean for text_comments" unless [ true, false ].include?(text_comments)
      types[name] = entry(source, example).merge("bindings" => bindings, "uses" => uses, "text_comments" => text_comments)
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
