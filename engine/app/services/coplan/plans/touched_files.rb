module CoPlan
  module Plans
    module TouchedFiles
      module_function

      def normalize(value)
        return value unless value.is_a?(Array)

        value.map do |entry|
          entry = entry.to_unsafe_h if entry.respond_to?(:to_unsafe_h)
          next entry unless entry.respond_to?(:to_h)

          entry = entry.to_h.stringify_keys
          {
            "repo" => entry["repo"].to_s.strip,
            "ref" => entry["ref"].presence || "HEAD",
            "path" => entry["path"].to_s.strip.sub(%r{\A\./}, "")
          }
        end.uniq
      end
    end
  end
end
