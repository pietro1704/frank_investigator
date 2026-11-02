module Investigations
  # A versioned contract stored inside discovery; old reports need no migration.
  class TopicPlan
    BASE_KEYS = %w[scope news_queries evidence_queries].freeze
    REQUIREMENT_KEYS = %w[subquestions territories reference_period ambiguities editorial_counts].freeze
    SIDES = %w[left center right].freeze
    MAX_NEWS = 12

    def self.call(raw)
      raise TopicDiscovery::InvalidResponse unless raw.is_a?(Hash)
      keys = raw.keys.sort
      raise TopicDiscovery::InvalidResponse unless [ BASE_KEYS.sort, (BASE_KEYS + [ "requirements" ]).sort ].include?(keys)
      text!(raw["scope"], 2000)
      list!(raw["news_queries"], raw.key?("requirements") ? 8 : 2, 300, min: 1)
      list!(raw["evidence_queries"], 2, 300, min: 1)
      result = raw.deep_dup
      result["version"] = raw.key?("requirements") ? 2 : 1
      result["requirements"] ||= { "subquestions" => [], "territories" => [], "reference_period" => "",
        "ambiguities" => [], "editorial_counts" => SIDES.index_with { 0 } }
      requirements = result.fetch("requirements")
      raise TopicDiscovery::InvalidResponse unless requirements.is_a?(Hash) && requirements.keys.sort == REQUIREMENT_KEYS.sort
      %w[subquestions territories].each { |key| list!(requirements[key], 6, 1000) }
      list!(requirements["ambiguities"], 12, 1000)
      text!(requirements["reference_period"], 300, min: 0)
      counts = requirements["editorial_counts"]
      raise TopicDiscovery::InvalidResponse unless counts.is_a?(Hash) && counts.keys.sort == SIDES.sort &&
        counts.values.all? { |value| value.is_a?(Integer) && value.between?(0, MAX_NEWS) } && counts.values.sum <= MAX_NEWS
      result
    end

    def self.text!(value, max, min: 1)
      raise TopicDiscovery::InvalidResponse unless value.is_a?(String) && value.strip.length.between?(min, max)
    end

    def self.list!(value, max, length, min: 0)
      raise TopicDiscovery::InvalidResponse unless value.is_a?(Array) && value.size.between?(min, max)
      value.each { |item| text!(item, length) }
    end
    private_class_method :text!, :list!
  end
end
